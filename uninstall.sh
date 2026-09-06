#!/usr/bin/env bash
# Hysteria2 一键安装脚本（真正零瑕疵终极版）

set -e

# ====== 1. 检查 root 权限 ======
if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 权限运行此脚本！"
  exit 1
fi

# ====== 2. CPU 架构检测与转换 ======
RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7|armhf) ARCH="armv7" ;;
    i386|i686) ARCH="386" ;;
    riscv64) ARCH="riscv64" ;;
    *) echo "错误：不支持的 CPU 架构: $RAW_ARCH"; exit 1 ;;
esac
echo "检测到 CPU 架构: $RAW_ARCH -> 匹配 Hysteria 架构: $ARCH"

# ====== 3. 基础依赖安装 (补全 cron 保证 acme 续签) ======
echo "正在检查并安装基础依赖..."
if command -v apt >/dev/null 2>&1; then
  apt update && apt install -y curl wget tar openssl socat ufw cron
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl wget tar openssl socat firewalld crontabs
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl wget tar openssl socat firewalld crontabs
fi

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
ACME_BIN="$HOME/.acme.sh/acme.sh"
mkdir -p "$CONFIG_DIR"

echo "==============================="
echo "     Hysteria2 安装向导"
echo "==============================="

# ====== 4. 基础参数输入 ======
read -p "请输入监听端口 [默认 443]：" PORT
PORT=${PORT:-443}

while [ -z "$PASSWORD" ]; do
  read -p "请输入 Hysteria2 认证密码：" PASSWORD
done

# ====== 5. TLS 证书模式选择 ======
echo ""
echo "--- 请选择 TLS 证书配置模式 ---"
echo " 1) 自签证书 (Self-Signed)"
echo " 2) acme.sh 脚本申请 - Cloudflare DNS-01 API 模式 (推荐/免开80端口)"
echo " 3) acme.sh 脚本申请 - HTTP-01 模式 (需开放80端口)"
read -p "请输入选项 [1-3]：" CERT_MODE

case "$CERT_MODE" in
    1)
        CERT_TYPE="self_signed"
        read -p "请输入自签证书的伪装 SNI 域名 [默认 bing.com]：" SNI_DOMAIN
        SNI_DOMAIN=${SNI_DOMAIN:-bing.com}
        ;;
    2)
        CERT_TYPE="acme_cf"
        while [ -z "$DOMAIN" ]; do read -p "请输入域名：" DOMAIN; done
        while [ -z "$EMAIL" ]; do read -p "请输入邮箱：" EMAIL; done
        while [ -z "$CF_API_TOKEN" ]; do read -p "请输入 Cloudflare API Token：" CF_API_TOKEN; done
        ;;
    3)
        CERT_TYPE="acme_http"
        while [ -z "$DOMAIN" ]; do read -p "请输入域名：" DOMAIN; done
        while [ -z "$EMAIL" ]; do read -p "请输入邮箱：" EMAIL; done
        ;;
    *)
        echo "无效选项，脚本退出"
        exit 1
        ;;
esac

# ====== 6. 伪装模式选择与格式修复 ======
echo ""
echo "--- 请选择未授权访问时的服务端 HTTP 伪装模式 ---"
echo " 1) 反向代理模式 (Proxy - 自动转发至外部网站，如 https://www.bing.com)"
echo " 2) 静态网站模式 (File - 返回本地静态网页文件)"
echo " 3) 状态码模式 (StatusCode - 返回特定 HTTP 状态码，如 404)"
read -p "请输入选项 [1-3，默认 1]：" MASQ_CHOICE
MASQ_CHOICE=${MASQ_CHOICE:-1}

case "$MASQ_CHOICE" in
    1)
        MASQ_TYPE="proxy"
        read -p "请输入反代目标网址 [默认 https://www.bing.com]：" MASQ_URL
        MASQ_URL=${MASQ_URL:-https://www.bing.com}
        if [[ ! "$MASQ_URL" =~ ^https?:// ]]; then
            MASQ_URL="https://$MASQ_URL"
        fi
        ;;
    2)
        MASQ_TYPE="file"
        read -p "请输入本地静态文件目录 [默认 /var/www/html]：" MASQ_DIR
        MASQ_DIR=${MASQ_DIR:-/var/www/html}
        mkdir -p "$MASQ_DIR"
        if [ ! -f "$MASQ_DIR/index.html" ]; then
            echo "<html><body><h1>403 Forbidden</h1></body></html>" > "$MASQ_DIR/index.html"
        fi
        chmod -R 755 "$MASQ_DIR"
        ;;
    3)
        MASQ_TYPE="statusCode"
        read -p "请输入返回的状态码 [默认 404]：" MASQ_CODE
        MASQ_CODE=${MASQ_CODE:-404}
        ;;
    *)
        MASQ_TYPE="proxy"
        MASQ_URL="https://www.bing.com"
        ;;
esac

# ====== 7. IP 地址检测 (加 || true 规避单栈服务器退出问题) ======
IPV4=$(curl -s4 --max-time 3 https://api.ipify.org || true)
IPV6=$(curl -s6 --max-time 3 https://api64.ipify.org || true)
[ -z "$IPV4" ] && IPV4="未检测到 IPv4"
[ -z "$IPV6" ] && IPV6="未检测到 IPv6"

# ====== 8. 证书生成与申请 ======
if [ "$CERT_TYPE" = "self_signed" ]; then
    echo "正在生成自签证书..."
    openssl req -x509 -nodes -newkey rsa:2048 -pkeyopt rsa_keygen_bits:2048 \
      -keyout "$CONFIG_DIR/server.key" \
      -out "$CONFIG_DIR/server.crt" \
      -days 3650 -subj "/CN=$SNI_DOMAIN"
else
    if [ ! -f "$ACME_BIN" ]; then
      echo "正在安装 acme.sh..."
      curl https://get.acme.sh | sh -s email="$EMAIL"
    fi
    
    if [ "$CERT_TYPE" = "acme_cf" ]; then
        echo "正在通过 Cloudflare DNS-01 申请证书..."
        export CF_Token="$CF_API_TOKEN"
        "$ACME_BIN" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
    elif [ "$CERT_TYPE" = "acme_http" ]; then
        echo "正在通过 HTTP-01 申请证书..."
        "$ACME_BIN" --issue --standalone -d "$DOMAIN" --keylength ec-256
    fi

    "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
      --key-file "$CONFIG_DIR/server.key" \
      --fullchain-file "$CONFIG_DIR/server.crt" \
      --reloadcmd "systemctl restart hysteria"
fi

# ====== 9. 下载官方二进制 ======
echo "正在获取适用于 linux-${ARCH} 的 Hysteria2 最新二进制文件..."
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
  | grep "browser_download_url" \
  | grep "linux-${ARCH}" \
  | head -n 1 \
  | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
  echo "错误：未能根据架构 linux-${ARCH} 找到匹配的 GitHub Release 下载链接"
  exit 1
fi

echo "下载地址: $DOWNLOAD_URL"
wget -O /usr/local/bin/hysteria "$DOWNLOAD_URL"
chmod +x /usr/local/bin/hysteria

# ====== 10. 动态生成配置文件 ======
cat > "$CONFIG_FILE" <<EOF
listen: :$PORT

tls:
  cert: $CONFIG_DIR/server.crt
  key: $CONFIG_DIR/server.key

auth:
  type: password
  password: "$PASSWORD"
EOF

# 追加伪装块
case "$MASQ_TYPE" in
    proxy)
cat >> "$CONFIG_FILE" <<EOF

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: true
EOF
        ;;
    file)
cat >> "$CONFIG_FILE" <<EOF

masquerade:
  type: file
  file:
    dir: $MASQ_DIR
EOF
        ;;
    statusCode)
cat >> "$CONFIG_FILE" <<EOF

masquerade:
  type: statusCode
  statusCode: $MASQ_CODE
EOF
        ;;
esac

# ====== 11. 配置 systemd 并启动 ======
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=/usr/local/bin/hysteria server -c $CONFIG_FILE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria
systemctl restart hysteria

# ====== 12. 防火墙端口放行 ======
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
  ufw allow $PORT/udp
  [ "$CERT_TYPE" = "acme_http" ] && ufw allow 80/tcp
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --add-port=$PORT/udp --permanent || true
  [ "$CERT_TYPE" = "acme_http" ] && (firewall-cmd --add-port=80/tcp --permanent || true)
  firewall-cmd --reload || true
fi

# ====== 13. 输出配置信息 ======
echo "======================================"
echo "       Hysteria2 安装部署完成"
echo "======================================"
echo "端口：$PORT (UDP)"
echo "密码：$PASSWORD"
echo "IPv4：$IPV4"
echo "IPv6：$IPV6"
echo "配置文件：$CONFIG_FILE"
echo "--------------------------------------"
if [ "$MASQ_TYPE" = "proxy" ]; then
  echo "伪装模式：反向代理 ($MASQ_URL)"
elif [ "$MASQ_TYPE" = "file" ]; then
  echo "伪装模式：本地文件 ($MASQ_DIR)"
else
  echo "伪装模式：状态码 ($MASQ_CODE)"
fi
echo "======================================"

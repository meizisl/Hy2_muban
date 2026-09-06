#!/usr/bin/env bash
# Hysteria2 多证书模式一键安装脚本

set -e

# ====== 检查 root 权限 ======
if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 权限运行此脚本！"
  exit 1
fi

# ====== 完善的 CPU 架构检测与映射 ======
RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    armv7l|armv7|armhf)
        ARCH="armv7"
        ;;
    i386|i686)
        ARCH="386"
        ;;
    riscv64)
        ARCH="riscv64"
        ;;
    *)
        echo "错误：不支持或无法识别的 CPU 架构: $RAW_ARCH"
        exit 1
        ;;
esac
echo "检测到 CPU 架构: $RAW_ARCH -> 匹配 Hysteria 架构: $ARCH"

# ====== 依赖安装 ======
echo "正在检查并安装基础依赖..."
if command -v apt >/dev/null 2>&1; then
  apt update && apt install -y curl wget tar openssl socat ufw jq
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl wget tar openssl socat firewalld jq
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl wget tar openssl socat firewalld jq
else
  echo "警告：未识别的包管理器，请确保已安装 curl, wget, openssl, socat, jq"
fi

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
mkdir -p "$CONFIG_DIR"

echo "==============================="
echo "     Hysteria2 安装向导"
echo "==============================="

# ====== 参数交互输入 ======
read -p "请输入监听端口 [默认 443]：" PORT
PORT=${PORT:-443}

while [ -z "$PASSWORD" ]; do
  read -p "请输入 Hysteria2 认证密码：" PASSWORD
done

echo ""
echo "请选择 TLS 证书配置模式："
echo " 1) 自签证书 (Self-Signed / 适合配合 SNI 伪装或自用测试)"
echo " 2) acme.sh 脚本申请 - Cloudflare DNS-01 API 模式 (支持泛域名/无需开放 80 端口)"
echo " 3) acme.sh 脚本申请 - HTTP-01 模式 (常规单域名/需占用 80 端口)"
read -p "请输入选项 [1-3]：" CERT_MODE

case "$CERT_MODE" in
    1)
        CERT_TYPE="self_signed"
        read -p "请输入自签证书的主机名/域名 [默认 bing.com]：" SNI_DOMAIN
        SNI_DOMAIN=${SNI_DOMAIN:-bing.com}
        ;;
    2)
        CERT_TYPE="acme_cf"
        while [ -z "$DOMAIN" ]; do
          read -p "请输入解析到本机的域名 (例如 node.example.com)：" DOMAIN
        done
        while [ -z "$EMAIL" ]; do
          read -p "请输入用于申请证书的邮箱：" EMAIL
        done
        while [ -z "$CF_API_TOKEN" ]; do
          read -p "请输入 Cloudflare API Token：" CF_API_TOKEN
        done
        ;;
    3)
        CERT_TYPE="acme_http"
        while [ -z "$DOMAIN" ]; do
          read -p "请输入已正确解析到本机的域名：" DOMAIN
        done
        while [ -z "$EMAIL" ]; do
          read -p "请输入用于申请证书的邮箱：" EMAIL
        done
        ;;
    *)
        echo "无效选项，脚本退出"
        exit 1
        ;;
esac

# ====== IP 地址检测 ======
IPV4=$(curl -s4 --max-time 3 https://api.ipify.org || echo "未检测到 IPv4")
IPV6=$(curl -s6 --max-time 3 https://api64.ipify.org || echo "未检测到 IPv6")

# ====== 证书生成/申请逻辑 ======
if [ "$CERT_TYPE" = "self_signed" ]; then
    echo "正在生成 CA 自签证书..."
    openssl req -x509 -nodes -newkey rsa:2048 -pkeyopt rsa_keygen_bits:2048 \
      -keyout "$CONFIG_DIR/server.key" \
      -out "$CONFIG_DIR/server.crt" \
      -days 3650 \
      -subj "/CN=$SNI_DOMAIN"
    
elif [ "$CERT_TYPE" = "acme_cf" ] || [ "$CERT_TYPE" = "acme_http" ]; then
    if [ ! -d ~/.acme.sh ]; then
      echo "正在安装 acme.sh..."
      curl https://get.acme.sh | sh -s email="$EMAIL"
    fi
    
    if [ "$CERT_TYPE" = "acme_cf" ]; then
        echo "正在通过 Cloudflare DNS-01 模式申请证书..."
        export CF_Token="$CF_API_TOKEN"
        ~/.acme.sh/acme.sh --issue \
          --dns dns_cf \
          -d "$DOMAIN" \
          --keylength ec-256
    elif [ "$CERT_TYPE" = "acme_http" ]; then
        echo "正在通过 HTTP-01 模式申请证书 (需要放行 80 端口)..."
        ~/.acme.sh/acme.sh --issue \
          --standalone \
          -d "$DOMAIN" \
          --keylength ec-256
    fi

    # 安装证书并设置自动重载命令
    ~/.acme.sh/acme.sh --install-cert \
      -d "$DOMAIN" \
      --ecc \
      --key-file "$CONFIG_DIR/server.key" \
      --fullchain-file "$CONFIG_DIR/server.crt" \
      --reloadcmd "systemctl restart hysteria"
fi

# ====== 准确下载 Hysteria2 硬件适配文件 ======
echo "正在获取适用于 linux-${ARCH} 的 Hysteria2 最新二进制文件..."
LATEST_RELEASE=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest)
DOWNLOAD_URL=$(echo "$LATEST_RELEASE" | jq -r ".assets[] | select(.name | contains(\"linux-${ARCH}\")) | .browser_download_url" | head -n 1)

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
  echo "错误：未能根据架构 linux-${ARCH} 找到匹配的 GitHub Release 下载链接"
  exit 1
fi

echo "下载地址: $DOWNLOAD_URL"
wget -O /usr/local/bin/hysteria "$DOWNLOAD_URL"
chmod +x /usr/local/bin/hysteria

# ====== 生成 Hysteria2 配置文件 ======
cat > "$CONFIG_FILE" <<EOF
listen: :$PORT

tls:
  cert: $CONFIG_DIR/server.crt
  key: $CONFIG_DIR/server.key

auth:
  type: password
  password: "$PASSWORD"
EOF

# ====== 配置 systemd 服务 ======
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

# ====== 防火墙自动放行 ======
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
  ufw allow $PORT/udp
  [ "$CERT_TYPE" = "acme_http" ] && ufw allow 80/tcp
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --add-port=$PORT/udp --permanent
  [ "$CERT_TYPE" = "acme_http" ] && firewall-cmd --add-port=80/tcp --permanent
  firewall-cmd --reload
fi

# ====== 输出客户端信息 ======
echo "======================================"
echo "       Hysteria2 安装配置完成"
echo "======================================"
echo "端口：$PORT (UDP)"
echo "密码：$PASSWORD"
echo "IPv4：$IPV4"
echo "IPv6：$IPV6"
echo "证书存储：$CONFIG_DIR"
echo "======================================"
echo "客户端参考参数："
if [ "$CERT_TYPE" = "self_signed" ]; then
  echo "server: $IPV4:$PORT"
  echo "tls:"
  echo "  sni: $SNI_DOMAIN"
  echo "  insecure: true (自签证书需开启跳过证书校验)"
else
  echo "server: $DOMAIN:$PORT"
  echo "tls:"
  echo "  sni: $DOMAIN"
  echo "  insecure: false"
fi
echo "======================================"

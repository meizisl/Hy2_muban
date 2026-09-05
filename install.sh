#!/usr/bin/env bash
# Hysteria2 必要参数一键安装脚本（ACME DNS / Cloudflare）
# 包含所有必要功能：端口、域名、密码、ACME、DNS、证书更新、systemd、IPv4/IPv6、防火墙

set -e

# ====== CPU 架构检测 ======
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    armv7l|armv7)
        ARCH="armv7"
        ;;
    riscv64)
        ARCH="riscv64"
        ;;
    *)
        echo "不支持的 CPU 架构: $ARCH"
        exit 1
        ;;
esac

echo "CPU 架构: $ARCH"

# ====== 系统检测 ======
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法检测系统类型"
    exit 1
fi

echo "系统类型: $OS"

# ====== 包管理器选择 ======
if command -v apt >/dev/null 2>&1; then
    PKG="apt"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
elif command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v pacman >/dev/null 2>&1; then
    PKG="pacman"
else
    echo "无法识别包管理器"
    exit 1
fi

echo "包管理器: $PKG"

# ====== IPv4 / IPv6 检测 ======
IPV4=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
IPV6=$(curl -s ipv6.ip.sb || echo "")

echo "IPv4: $IPV4"
echo "IPv6: $IPV6"


echo "==============================="
echo "     Hysteria2 安装向导"
echo "==============================="

# ====== 用户输入必要参数 ======

read -p "请输入监听端口 [默认 443]：" PORT
PORT=${PORT:-443}

read -p "请输入你的域名 (example.com)：" DOMAIN

read -p "请输入你的邮箱 (用于 ACME)：" EMAIL

read -p "请输入 Cloudflare API Token：" CF_API_TOKEN

read -p "请输入 Hysteria2 密码：" PASSWORD

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

# ====== 检查 root ======
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

# ====== 安装依赖 ======
if command -v apt >/dev/null 2>&1; then
  apt update
  apt install -y curl wget tar openssl socat ufw
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl wget tar openssl socat firewalld
else
  echo "不支持的系统，仅支持 Debian/Ubuntu/CentOS"
  exit 1
fi

mkdir -p "$CONFIG_DIR"

# ====== IPv4 / IPv6 自动检测 ======
IPV4=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
IPV6=$(curl -s ipv6.ip.sb || echo "")

echo "检测到 IPv4: $IPV4"
echo "检测到 IPv6: $IPV6"

# ====== 安装 acme.sh ======
if [ ! -d ~/.acme.sh ]; then
  curl https://get.acme.sh | sh
fi

# ====== 设置 Cloudflare API Token ======
export CF_Token="$CF_API_TOKEN"

# ====== 申请证书（DNS-01） ======
~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  -d "*.$DOMAIN" \
  --keylength ec-256 \
  --accountemail "$EMAIL"

# ====== 安装证书到指定目录 ======
~/.acme.sh/acme.sh --install-cert \
  -d "$DOMAIN" \
  --ecc \
  --key-file "$CONFIG_DIR/server.key" \
  --fullchain-file "$CONFIG_DIR/server.crt"

# ====== 下载最新 Hysteria2 ======
LATEST=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
  | grep browser_download_url \
  | grep linux-amd64 \
  | cut -d '"' -f 4)

wget -O hysteria.tar.gz "$LATEST"
tar -xzf hysteria.tar.gz
mv hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ====== 写入配置文件（必要参数） ======
cat > "$CONFIG_FILE" <<EOF
listen: :$PORT

tls:
  cert: $CONFIG_DIR/server.crt
  key: $CONFIG_DIR/server.key

auth:
  type: password
  password: "$PASSWORD"

acme:
  domains:
    - "*.$DOMAIN"
  email: "$EMAIL"
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: "$CF_API_TOKEN"
EOF

# ====== systemd 服务（必要） ======
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c $CONFIG_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria
systemctl restart hysteria

# ====== 防火墙自动放行（必要） ======
if command -v ufw >/dev/null 2>&1; then
  ufw allow $PORT/udp
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --add-port=$PORT/udp --permanent
  firewall-cmd --reload
fi

echo "======================================"
echo "       Hysteria2 安装完成"
echo "======================================"
echo "域名：$DOMAIN"
echo "端口：$PORT"
echo "密码：$PASSWORD"
echo "IPv4：$IPV4"
echo "IPv6：$IPV6"
echo "证书路径：$CONFIG_DIR"
echo "配置文件：$CONFIG_FILE"
echo "======================================"
echo "客户端请设置："
echo "server: $DOMAIN:$PORT"
echo "auth: $PASSWORD"
echo "tls:"
echo "  sni: $DOMAIN"
echo "======================================"

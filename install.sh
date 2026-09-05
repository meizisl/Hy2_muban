#!/usr/bin/env bash
# Hysteria2 一键安装脚本（全参数可自定义）
# 支持 ACME DNS / Cloudflare / 全参数用户输入

set -e

echo "==============================="
echo "     Hysteria2 安装向导"
echo "==============================="

# ====== 用户输入参数 ======

read -p "请输入监听端口 [默认 443]：" PORT
PORT=${PORT:-443}

read -p "是否启用 ACME 自动证书？(y/n) [默认 y]：" ENABLE_ACME
ENABLE_ACME=${ENABLE_ACME:-y}

read -p "请输入你的域名 (example.com)，若不启用 ACME 可留空：" DOMAIN

read -p "请输入你的邮箱 (用于 ACME)，若不启用 ACME 可留空：" EMAIL

read -p "请输入 Hysteria2 密码：" PASSWORD

read -p "选择 ACME DNS 服务商 [默认 cloudflare]：" DNS_PROVIDER
DNS_PROVIDER=${DNS_PROVIDER:-cloudflare}

read -p "请输入 DNS Provider API Token (Cloudflare 为 CF_Token)，若不启用 ACME 可留空：" DNS_API_TOKEN

read -p "是否启用 QUIC 高级参数？(y/n) [默认 y]：" ENABLE_QUIC
ENABLE_QUIC=${ENABLE_QUIC:-y}

read -p "是否启用 systemd？(y/n) [默认 y]：" ENABLE_SYSTEMD
ENABLE_SYSTEMD=${ENABLE_SYSTEMD:-y}

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
  apt install -y curl wget tar openssl socat
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl wget tar openssl socat
else
  echo "不支持的系统，仅支持 Debian/Ubuntu/CentOS"
  exit 1
fi

mkdir -p "$CONFIG_DIR"

# ====== ACME 自动证书 ======
if [ "$ENABLE_ACME" = "y" ]; then
  echo "正在安装 acme.sh ..."
  if [ ! -d ~/.acme.sh ]; then
    curl https://get.acme.sh | sh
  fi

  echo "正在申请证书（DNS-01）..."

  # 设置 DNS API Token（Cloudflare）
  export CF_Token="$DNS_API_TOKEN"

  ~/.acme.sh/acme.sh --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    -d "*.$DOMAIN" \
    --keylength ec-256 \
    --accountemail "$EMAIL"

  ~/.acme.sh/acme.sh --install-cert \
    -d "$DOMAIN" \
    --ecc \
    --key-file "$CONFIG_DIR/server.key" \
    --fullchain-file "$CONFIG_DIR/server.crt"

else
  echo "未启用 ACME，使用自签证书"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CONFIG_DIR/server.key" \
    -out "$CONFIG_DIR/server.crt" \
    -days 3650 \
    -subj "/CN=Hysteria2"
fi

# ====== 下载最新 Hysteria2 ======
LATEST=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
  | grep browser_download_url \
  | grep linux-amd64 \
  | cut -d '"' -f 4)

wget -O hysteria.tar.gz "$LATEST"
tar -xzf hysteria.tar.gz
mv hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# ====== 写入配置文件 ======
echo "正在生成配置文件..."

cat > "$CONFIG_FILE" <<EOF
listen: :$PORT

tls:
  cert: $CONFIG_DIR/server.crt
  key: $CONFIG_DIR/server.key

auth:
  type: password
  password: "$PASSWORD"
EOF

# ====== 写入 ACME 配置 ======
if [ "$ENABLE_ACME" = "y" ]; then
cat >> "$CONFIG_FILE" <<EOF

acme:
  domains:
    - "*.$DOMAIN"
  email: "$EMAIL"
  type: dns
  dns:
    name: $DNS_PROVIDER
    config:
      cloudflare_api_token: "$DNS_API_TOKEN"
EOF
fi

# ====== 写入 QUIC 高级参数 ======
if [ "$ENABLE_QUIC" = "y" ]; then
cat >> "$CONFIG_FILE" <<EOF

quic:
  initStreamReceiveWindow: 8388608
  initStreamSendWindow: 8388608
  maxStreamReceiveWindow: 8388608
  maxStreamSendWindow: 8388608
EOF
fi

# ====== systemd 服务 ======
if [ "$ENABLE_SYSTEMD" = "y" ]; then
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
fi

echo "======================================"
echo "       Hysteria2 安装完成"
echo "======================================"
echo "端口：$PORT"
echo "密码：$PASSWORD"
echo "配置文件：$CONFIG_FILE"
echo "ACME：$ENABLE_ACME"
echo "DNS Provider：$DNS_PROVIDER"
echo "======================================"

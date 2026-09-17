#!/usr/bin/env bash

# ============================================================
# Hysteria 2 一键安装脚本 (完整修复版)
# ============================================================

set -Eeuo pipefail

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_NAME="hysteria.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
HYSTERIA_BIN="/usr/local/bin/hysteria"
ACME_HOME="${HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
CERT_FILE="${CONFIG_DIR}/server.crt"
KEY_FILE="${CONFIG_DIR}/server.key"

# root 检查
if [ "${EUID}" -ne 0 ]; then
    echo "错误：请使用 root 权限运行。"
    exit 1
fi

trap 'echo ""; echo "错误：脚本执行失败，行号：${LINENO}"; exit 1' ERR

# CPU 架构检测
RAW_ARCH="$(uname -m)"
case "${RAW_ARCH}" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7|armhf) ARCH="armv7" ;;
    i386|i686) ARCH="386" ;;
    riscv64) ARCH="riscv64" ;;
    *) echo "错误：不支持的 CPU 架构：${RAW_ARCH}"; exit 1 ;;
esac

# 安装依赖
install_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && apt-get install -y curl wget tar openssl socat jq ca-certificates cron
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        PM=$(command -v dnf || command -v yum)
        $PM install -y curl wget tar openssl socat jq ca-certificates cronie
    else
        echo "错误：不支持的包管理器。"
        exit 1
    fi
}
install_deps

# 启动 cron
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron.service 2>/dev/null || systemctl enable --now crond.service 2>/dev/null || true
fi

mkdir -p "${CONFIG_DIR}"
chmod 755 "${CONFIG_DIR}"

echo ""
echo "========================================"
echo "Hysteria 2 安装向导"
echo "========================================"

read -r -p "请输入 Hysteria 监听端口 [默认 443]： " PORT
PORT="${PORT:-443}"

PASSWORD=""
while [ -z "${PASSWORD}" ]; do
    read -r -p "请输入 Hysteria 2 认证密码： " PASSWORD
done

echo ""
echo "TLS 证书模式："
echo "1) 自签证书"
echo "2) Cloudflare DNS-01"
echo "3) HTTP-01"
read -r -p "请选择 [1-3]： " CERT_MODE

case "${CERT_MODE}" in
    1)
        CERT_TYPE="self_signed"
        read -r -p "请输入证书 SNI 域名 [默认 bing.com]： " SNI_DOMAIN
        SNI_DOMAIN="${SNI_DOMAIN:-bing.com}"
        DOMAIN="${SNI_DOMAIN}"
        ;;
    2)
        CERT_TYPE="acme_cf"
        read -r -p "请输入解析到本 VPS 的域名： " DOMAIN
        read -r -p "请输入证书邮箱： " EMAIL
        read -r -p "请输入 Cloudflare API Token： " CF_API_TOKEN
        ;;
    3)
        CERT_TYPE="acme_http"
        read -r -p "请输入解析到本 VPS 的域名： " DOMAIN
        read -r -p "请输入证书邮箱： " EMAIL
        ;;
    *)
        echo "错误：无效选择。"
        exit 1
        ;;
esac

echo ""
echo "Masquerade 伪装模式："
echo "1) Proxy 反向代理"
echo "2) File 静态文件"
echo "3) StatusCode 状态码"
read -r -p "请选择 [默认 1]： " MASQ_CHOICE
MASQ_CHOICE="${MASQ_CHOICE:-1}"

case "${MASQ_CHOICE}" in
    1)
        MASQ_TYPE="proxy"
        read -r -p "请输入反代网址 [默认 https://www.bing.com]： " MASQ_URL
        MASQ_URL="${MASQ_URL:-https://www.bing.com}"
        [[ ! "${MASQ_URL}" =~ ^https?:// ]] && MASQ_URL="https://${MASQ_URL}"
        ;;
    2)
        MASQ_TYPE="file"
        read -r -p "请输入网站目录 [默认 /var/www/html]： " MASQ_DIR
        MASQ_DIR="${MASQ_DIR:-/var/www/html}"
        mkdir -p "${MASQ_DIR}"
        if [ ! -f "${MASQ_DIR}/index.html" ]; then
            echo "<html><body><h1>Welcome</h1></body></html>" > "${MASQ_DIR}/index.html"
        fi
        chmod -R 755 "${MASQ_DIR}"
        ;;
    3)
        MASQ_TYPE="statusCode"
        read -r -p "请输入 HTTP 状态码 [默认 404]： " MASQ_CODE
        MASQ_CODE="${MASQ_CODE:-404}"
        ;;
    *)
        MASQ_TYPE="proxy"
        MASQ_URL="https://www.bing.com"
        ;;
esac

# 安装 Hysteria
if [ ! -x "${HYSTERIA_BIN}" ]; then
    echo "正在使用官方脚本安装 Hysteria 2..."
    HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)
fi

# 生成 TLS 证书
if [ "${CERT_TYPE}" = "self_signed" ]; then
    echo "生成自签证书..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
        -days 3650 -subj "/CN=${SNI_DOMAIN}"
    chmod 600 "${KEY_FILE}"
elif [ "${CERT_TYPE}" = "acme_cf" ] || [ "${CERT_TYPE}" = "acme_http" ]; then
    if [ ! -x "${ACME_BIN}" ]; then
        curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"
    fi
    "${ACME_BIN}" --set-default-ca --server letsencrypt

    if [ "${CERT_TYPE}" = "acme_cf" ]; then
        export CF_Token="${CF_API_TOKEN}"
        "${ACME_BIN}" --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256
    else
        "${ACME_BIN}" --issue --standalone -d "${DOMAIN}" --keylength ec-256
    fi

    "${ACME_BIN}" --install-cert -d "${DOMAIN}" --ecc \
        --key-file "${KEY_FILE}" \
        --fullchain-file "${CERT_FILE}" \
        --reloadcmd "systemctl restart ${SERVICE_NAME}"
    chmod 600 "${KEY_FILE}"
fi

# ============================================================
# 正确生成 Hysteria 2 配置文件 (修复核心 YAML 语法)
# ============================================================
echo "正在写入配置文件 ${CONFIG_FILE}..."

cat > "${CONFIG_FILE}" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: "${PASSWORD}"
EOF

# 写入伪装配置
case "${MASQ_TYPE}" in
    proxy)
        cat >> "${CONFIG_FILE}" <<EOF

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true
EOF
        ;;
    file)
        cat >> "${CONFIG_FILE}" <<EOF

masquerade:
  type: file
  file:
    dir: ${MASQ_DIR}
EOF
        ;;
    statusCode)
        cat >> "${CONFIG_FILE}" <<EOF

masquerade:
  type: statusCode
  statusCode: ${MASQ_CODE}
EOF
        ;;
esac

chmod 600 "${CONFIG_FILE}"

# 统一配置 Systemd 服务
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Hysteria 2 Server Service
After=network.target network-online.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${HYSTERIA_BIN} server -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

# 校验并启动
echo "检查配置正确性..."
if "${HYSTERIA_BIN}" check -c "${CONFIG_FILE}"; then
    echo "配置校验成功，正在启动服务..."
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo "========================================"
        echo "Hysteria 2 部署成功并已正常启动！"
        echo "配置文件已准确保存至：${CONFIG_FILE}"
        echo "========================================"
    else
        echo "启动失败，请检查日志：journalctl -u ${SERVICE_NAME} -e"
        exit 1
    fi
else
    echo "配置检查失败，请检查上面输出的信息！"
    exit 1
fi

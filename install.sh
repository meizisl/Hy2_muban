#!/usr/bin/env bash

# ============================================================
# Hysteria 2 一键安装脚本
# 修正版
#
# 功能：
#   1. 安装 Hysteria 2
#   2. systemd 管理
#   3. 自签证书
#   4. acme.sh + Cloudflare DNS-01
#   5. acme.sh + HTTP-01
#   6. proxy / file / statusCode masquerade
#   7. 自动证书续期
#   8. 证书续期后自动重启 Hysteria
#
# 不负责：
#   - Vultr 网页 Firewall
#   - NAT / DNAT
#   - iptables / nftables 全端口转发
#   - SSH 端口修改
# ============================================================

set -Eeuo pipefail

# ============================================================
# 基础变量
# ============================================================

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"

SERVICE_NAME="hysteria-server.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

HYSTERIA_BIN="/usr/local/bin/hysteria"

ACME_HOME="${HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

CERT_FILE="${CONFIG_DIR}/server.crt"
KEY_FILE="${CONFIG_DIR}/server.key"

# ============================================================
# root 检查
# ============================================================

if [ "${EUID}" -ne 0 ]; then
    echo "错误：请使用 root 权限运行。"
    exit 1
fi

# ============================================================
# 错误处理
# ============================================================

trap 'echo ""; echo "错误：脚本执行失败，行号：${LINENO}"; exit 1' ERR

# ============================================================
# CPU 架构
# ============================================================

RAW_ARCH="$(uname -m)"

case "${RAW_ARCH}" in
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
        echo "错误：不支持的 CPU 架构：${RAW_ARCH}"
        exit 1
        ;;
esac

echo "检测到 CPU 架构：${RAW_ARCH} -> ${ARCH}"

# ============================================================
# 检测发行版
# ============================================================

if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "无法检测 Linux 发行版。"
    exit 1
fi

echo "系统：${PRETTY_NAME:-未知}"

# ============================================================
# 安装依赖
# ============================================================

echo ""
echo "========================================"
echo "安装基础依赖"
echo "========================================"

install_debian() {
    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        curl \
        wget \
        tar \
        openssl \
        socat \
        jq \
        ca-certificates \
        cron
}

install_rhel() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y \
            curl \
            wget \
            tar \
            openssl \
            socat \
            jq \
            ca-certificates \
            cronie
    elif command -v yum >/dev/null 2>&1; then
        yum install -y \
            curl \
            wget \
            tar \
            openssl \
            socat \
            jq \
            ca-certificates \
            cronie
    else
        echo "错误：没有找到 apt/dnf/yum。"
        exit 1
    fi
}

if command -v apt-get >/dev/null 2>&1; then
    install_debian
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    install_rhel
else
    echo "错误：不支持的包管理器。"
    exit 1
fi

# ============================================================
# 启动 cron
# ============================================================

if command -v systemctl >/dev/null 2>&1; then

    if systemctl list-unit-files | grep -q '^cron.service'; then
        systemctl enable --now cron.service || true
    fi

    if systemctl list-unit-files | grep -q '^crond.service'; then
        systemctl enable --now crond.service || true
    fi

fi

# ============================================================
# 创建目录
# ============================================================

mkdir -p "${CONFIG_DIR}"

chmod 755 "${CONFIG_DIR}"

# ============================================================
# 输入参数
# ============================================================

echo ""
echo "========================================"
echo "Hysteria 2 安装向导"
echo "========================================"

read -r -p "请输入 Hysteria 监听端口 [默认 443]： " PORT
PORT="${PORT:-443}"

if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
    echo "错误：端口必须是数字。"
    exit 1
fi

if [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
    echo "错误：端口范围必须是 1-65535。"
    exit 1
fi

# ============================================================
# 密码
# ============================================================

PASSWORD=""

while [ -z "${PASSWORD}" ]; do
    read -r -s -p "请输入 Hysteria 2 认证密码： " PASSWORD
    echo
done

# ============================================================
# TLS 模式
# ============================================================

echo ""
echo "TLS 证书模式："
echo "1) 自签证书"
echo "2) Cloudflare DNS-01"
echo "3) HTTP-01"

read -r -p "请选择 [1-3]： " CERT_MODE

case "${CERT_MODE}" in

    1)
        CERT_TYPE="self_signed"

        read -r -p \
            "请输入证书 SNI 域名 [默认 bing.com]： " \
            SNI_DOMAIN

        SNI_DOMAIN="${SNI_DOMAIN:-bing.com}"

        DOMAIN="${SNI_DOMAIN}"
        ;;

    2)
        CERT_TYPE="acme_cf"

        while [ -z "${DOMAIN:-}" ]; do
            read -r -p \
                "请输入解析到本 VPS 的域名： " \
                DOMAIN
        done

        while [ -z "${EMAIL:-}" ]; do
            read -r -p \
                "请输入证书邮箱： " \
                EMAIL
        done

        while [ -z "${CF_API_TOKEN:-}" ]; do
            read -r -s -p \
                "请输入 Cloudflare API Token： " \
                CF_API_TOKEN
            echo
        done
        ;;

    3)
        CERT_TYPE="acme_http"

        while [ -z "${DOMAIN:-}" ]; do
            read -r -p \
                "请输入解析到本 VPS 的域名： " \
                DOMAIN
        done

        while [ -z "${EMAIL:-}" ]; do
            read -r -p \
                "请输入证书邮箱： " \
                EMAIL
        done
        ;;

    *)
        echo "错误：无效选择。"
        exit 1
        ;;

esac

# ============================================================
# Masquerade
# ============================================================

echo ""
echo "========================================"
echo "Masquerade 伪装模式"
echo "========================================"

echo "1) Proxy 反向代理"
echo "2) File 静态文件"
echo "3) StatusCode 状态码"

read -r -p "请选择 [默认 1]： " MASQ_CHOICE

MASQ_CHOICE="${MASQ_CHOICE:-1}"

case "${MASQ_CHOICE}" in

    1)

        MASQ_TYPE="proxy"

        read -r -p \
            "请输入反代网址 [默认 https://www.bing.com]： " \
            MASQ_URL

        MASQ_URL="${MASQ_URL:-https://www.bing.com}"

        if [[ ! "${MASQ_URL}" =~ ^https?:// ]]; then
            MASQ_URL="https://${MASQ_URL}"
        fi

        ;;

    2)

        MASQ_TYPE="file"

        read -r -p \
            "请输入网站目录 [默认 /var/www/html]： " \
            MASQ_DIR

        MASQ_DIR="${MASQ_DIR:-/var/www/html}"

        mkdir -p "${MASQ_DIR}"

        if [ ! -f "${MASQ_DIR}/index.html" ]; then
            cat > "${MASQ_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Welcome</title>
</head>
<body>
<h1>Welcome</h1>
</body>
</html>
EOF
        fi

        chmod -R 755 "${MASQ_DIR}"

        ;;

    3)

        MASQ_TYPE="statusCode"

        read -r -p \
            "请输入 HTTP 状态码 [默认 404]： " \
            MASQ_CODE

        MASQ_CODE="${MASQ_CODE:-404}"

        if ! [[ "${MASQ_CODE}" =~ ^[0-9]{3}$ ]]; then
            echo "错误：状态码必须是三位数字。"
            exit 1
        fi

        ;;

    *)

        echo "无效选择，使用 Proxy。"

        MASQ_TYPE="proxy"
        MASQ_URL="https://www.bing.com"

        ;;

esac

# ============================================================
# IP 检测
# ============================================================

echo ""
echo "正在检测公网 IP..."

IPV4="$(curl -4 -fsS --max-time 5 https://api.ipify.org || true)"
IPV6="$(curl -6 -fsS --max-time 5 https://api64.ipify.org || true)"

IPV4="${IPV4:-未检测到}"
IPV6="${IPV6:-未检测到}"

# ============================================================
# 安装 Hysteria
# ============================================================

echo ""
echo "========================================"
echo "安装 Hysteria 2"
echo "========================================"

if [ -x "${HYSTERIA_BIN}" ]; then

    echo "检测到已有 Hysteria："
    "${HYSTERIA_BIN}" version || true

else

    echo "使用官方安装脚本安装 Hysteria 2..."

    HYSTERIA_USER=root \
        bash <(curl -fsSL https://get.hy2.sh/)

fi

# ============================================================
# 检查 Hysteria
# ============================================================

if [ ! -x "${HYSTERIA_BIN}" ]; then

    echo "错误：Hysteria 安装失败。"
    echo "没有找到：${HYSTERIA_BIN}"

    exit 1

fi

echo "Hysteria 安装成功："

"${HYSTERIA_BIN}" version || true

# ============================================================
# systemd 服务
# ============================================================

echo ""
echo "========================================"
echo "配置 systemd"
echo "========================================"

# 如果官方安装程序创建了服务，则优先使用它。
# 如果不存在，则自己创建。

if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${HYSTERIA_BIN} server -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

fi

systemctl daemon-reload

# ============================================================
# 证书
# ============================================================

echo ""
echo "========================================"
echo "配置 TLS 证书"
echo "========================================"

if [ "${CERT_TYPE}" = "self_signed" ]; then

    echo "生成自签证书..."

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -days 3650 \
        -subj "/CN=${SNI_DOMAIN}"

    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"

fi

# ============================================================
# ACME
# ============================================================

if [ "${CERT_TYPE}" = "acme_cf" ] || \
   [ "${CERT_TYPE}" = "acme_http" ]; then

    if [ ! -x "${ACME_BIN}" ]; then

        echo "安装 acme.sh..."

        curl -fsSL https://get.acme.sh \
            | sh -s email="${EMAIL}"

    fi

    if [ ! -x "${ACME_BIN}" ]; then
        echo "错误：acme.sh 安装失败。"
        exit 1
    fi

    # --------------------------------------------------------
    # Cloudflare DNS-01
    # --------------------------------------------------------

    if [ "${CERT_TYPE}" = "acme_cf" ]; then

        echo "使用 Cloudflare DNS-01 申请证书..."

        export CF_Token="${CF_API_TOKEN}"

        "${ACME_BIN}" \
            --set-default-ca \
            --server letsencrypt

        "${ACME_BIN}" \
            --issue \
            --dns dns_cf \
            -d "${DOMAIN}" \
            --keylength ec-256

    fi

    # --------------------------------------------------------
    # HTTP-01
    # --------------------------------------------------------

    if [ "${CERT_TYPE}" = "acme_http" ]; then

        echo "使用 HTTP-01 申请证书..."

        "${ACME_BIN}" \
            --set-default-ca \
            --server letsencrypt

        "${ACME_BIN}" \
            --issue \
            --standalone \
            -d "${DOMAIN}" \
            --keylength ec-256

    fi

    # --------------------------------------------------------
    # 安装证书
    # --------------------------------------------------------

    echo "安装证书到 Hysteria..."

    "${ACME_BIN}" \
        --install-cert \
        -d "${DOMAIN}" \
        --ecc \
        --key-file "${KEY_FILE}" \
        --fullchain-file "${CERT_FILE}" \
        --reloadcmd "systemctl restart ${SERVICE_NAME}"

    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"

fi

# ============================================================
# 生成 Hysteria 配置
# ============================================================

echo ""
echo "========================================"
echo "生成 Hysteria 配置"
echo "========================================"

cat > "${CONFIG_FILE}" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: "${PASSWORD}"

EOF

# ============================================================
# Masquerade 配置
# ============================================================

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

        # Hysteria 2 当前官方配置支持 string/file/proxy。
        # 为避免使用旧版 statusCode 配置导致启动失败，
        # 使用 string + statusCode 实现固定 HTTP 响应。

        cat >> "${CONFIG_FILE}" <<EOF
masquerade:
  type: string
  string:
    content: ""
    statusCode: ${MASQ_CODE}
EOF

        ;;

esac

chmod 600 "${CONFIG_FILE}"

# ============================================================
# 检查配置
# ============================================================

echo ""
echo "========================================"
echo "检查 Hysteria 配置"
echo "========================================"

if ! "${HYSTERIA_BIN}" check \
    -c "${CONFIG_FILE}"; then

    echo ""
    echo "========================================"
    echo "Hysteria 配置检查失败"
    echo "========================================"

    cat "${CONFIG_FILE}"

    exit 1

fi

echo "配置检查通过。"

# ============================================================
# 启动服务
# ============================================================

echo ""
echo "========================================"
echo "启动 Hysteria"
echo "========================================"

systemctl daemon-reload

systemctl enable "${SERVICE_NAME}"

systemctl restart "${SERVICE_NAME}"

sleep 2

# ============================================================
# 检查服务
# ============================================================

if systemctl is-active --quiet "${SERVICE_NAME}"; then

    echo ""
    echo "Hysteria 2 启动成功。"

else

    echo ""
    echo "Hysteria 2 启动失败。"
    echo ""
    echo "最近日志："

    journalctl \
        --no-pager \
        -n 50 \
        -u "${SERVICE_NAME}"

    exit 1

fi

# ============================================================
# 监听检查
# ============================================================

echo ""
echo "========================================"
echo "端口监听状态"
echo "========================================"

ss -lunpt | grep ":${PORT}" || true

# ============================================================
# 防火墙说明
# ============================================================

echo ""
echo "========================================"
echo "防火墙"
echo "========================================"

echo "本脚本不会强制开启 UFW。"
echo "如果你已经关闭 UFW，不需要在这里重复处理。"
echo ""
echo "Vultr 网页 Firewall 需要你在控制台单独配置。"
echo ""
echo "如果 Hysteria 使用 UDP ${PORT}，"
echo "Vultr Firewall 至少需要允许 UDP ${PORT}。"

# ============================================================
# 输出信息
# ============================================================

echo ""
echo "========================================"
echo "Hysteria 2 安装完成"
echo "========================================"

echo "服务：${SERVICE_NAME}"
echo "配置：${CONFIG_FILE}"
echo "证书：${CERT_FILE}"
echo "私钥：${KEY_FILE}"
echo "端口：${PORT}/UDP"
echo "IPv4：${IPV4}"
echo "IPv6：${IPV6}"

if [ "${CERT_TYPE}" = "self_signed" ]; then
    echo "TLS：自签证书"
    echo "SNI：${SNI_DOMAIN}"
    echo "客户端需要 insecure=true"
else
    echo "TLS：ACME"
    echo "域名：${DOMAIN}"
    echo "客户端 SNI：${DOMAIN}"
fi

echo ""
echo "服务状态："

systemctl --no-pager status "${SERVICE_NAME}" || true

echo ""
echo "常用命令："
echo ""
echo "查看状态："
echo "systemctl status ${SERVICE_NAME}"
echo ""
echo "查看日志："
echo "journalctl -u ${SERVICE_NAME} -f"
echo ""
echo "重启："
echo "systemctl restart ${SERVICE_NAME}"
echo ""
echo "查看端口："
echo "ss -lunpt | grep :${PORT}"

echo ""
echo "========================================"
echo "完成"
echo "========================================"

#!/bin/bash

# 开启严格模式，遇到报错立即停止
set -e

# 检查是否为 root 权限
if [ "${EUID}" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本。"
    exit 1
fi

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
HYSTERIA_BIN="/usr/local/bin/hysteria"
SERVICE_NAME="hysteria.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

# ============================================================
# 安装基础依赖
# ============================================================
install_deps() {
    echo "正在检查并安装基础依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y && apt-get install -y curl wget tar openssl jq ca-certificates
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        PM=$(command -v dnf || command -v yum)
        $PM install -y curl wget tar openssl jq ca-certificates
    fi
}
install_deps

# ============================================================
# 第一步：收集用户自定义参数
# ============================================================
echo ""
echo "========================================"
echo "Hysteria 2 参数配置"
echo "========================================"

# 1. 监听端口
read -r -p "请输入 Hysteria 监听端口 [默认 443]： " INPUT_PORT
INPUT_PORT="${INPUT_PORT:-443}"

# 2. 密码
INPUT_PASSWORD=""
while [ -z "${INPUT_PASSWORD}" ]; do
    read -r -p "请输入 Hysteria 2 认证密码： " INPUT_PASSWORD
done

# 3. 证书模式
echo ""
echo "TLS 证书模式："
echo "1) Hysteria 原生 HTTP-01 (自动 80 端口申请证书，默认)"
echo "2) Hysteria 原生 Cloudflare DNS-01"
echo "3) 自签证书"
read -r -p "请选择 [默认 1]： " CERT_MODE
CERT_MODE="${CERT_MODE:-1}"

INPUT_DOMAIN=""
INPUT_EMAIL=""
INPUT_CF_TOKEN=""
INPUT_SNI=""

case "${CERT_MODE}" in
    1)
        CERT_TYPE="acme_http"
        while [ -z "${INPUT_DOMAIN}" ]; do
            read -r -p "请输入解析到本 VPS 的域名： " INPUT_DOMAIN
        done
        read -r -p "请输入邮箱 [默认 admin@${INPUT_DOMAIN}]： " INPUT_EMAIL
        INPUT_EMAIL="${INPUT_EMAIL:-admin@${INPUT_DOMAIN}}"
        ;;
    2)
        CERT_TYPE="acme_cf"
        while [ -z "${INPUT_DOMAIN}" ]; do
            read -r -p "请输入解析到本 VPS 的域名： " INPUT_DOMAIN
        done
        read -r -p "请输入邮箱 [默认 admin@${INPUT_DOMAIN}]： " INPUT_EMAIL
        INPUT_EMAIL="${INPUT_EMAIL:-admin@${INPUT_DOMAIN}}"
        while [ -z "${INPUT_CF_TOKEN}" ]; do
            read -r -p "请输入 Cloudflare API Token： " INPUT_CF_TOKEN
        done
        ;;
    3)
        CERT_TYPE="self_signed"
        read -r -p "请输入自签 SNI 域名 [默认 bing.com]： " INPUT_SNI
        INPUT_SNI="${INPUT_SNI:-bing.com}"
        ;;
    *)
        echo "错误：无效选择。"
        exit 1
        ;;
esac

# 4. 伪装模式
echo ""
echo "Masquerade 伪装模式："
echo "1) Proxy 反向代理"
echo "2) File 静态文件"
echo "3) StatusCode 状态码"
read -r -p "请选择 [默认 1]： " MASQ_CHOICE
MASQ_CHOICE="${MASQ_CHOICE:-1}"

INPUT_MASQ_URL=""
INPUT_MASQ_DIR=""
INPUT_MASQ_CODE=""

case "${MASQ_CHOICE}" in
    1)
        MASQ_TYPE="proxy"
        read -r -p "请输入反代网址 [默认 https://www.bing.com]： " INPUT_MASQ_URL
        INPUT_MASQ_URL="${INPUT_MASQ_URL:-https://www.bing.com}"
        [[ ! "${INPUT_MASQ_URL}" =~ ^https?:// ]] && INPUT_MASQ_URL="https://${INPUT_MASQ_URL}"
        ;;
    2)
        MASQ_TYPE="file"
        read -r -p "请输入静态网站目录 [默认 /var/www/html]： " INPUT_MASQ_DIR
        INPUT_MASQ_DIR="${INPUT_MASQ_DIR:-/var/www/html}"
        mkdir -p "${INPUT_MASQ_DIR}"
        [ ! -f "${INPUT_MASQ_DIR}/index.html" ] && echo "<html><body><h1>Welcome</h1></body></html>" > "${INPUT_MASQ_DIR}/index.html"
        ;;
    3)
        MASQ_TYPE="statusCode"
        read -r -p "请输入 HTTP 状态码 [默认 404]： " INPUT_MASQ_CODE
        INPUT_MASQ_CODE="${INPUT_MASQ_CODE:-404}"
        ;;
    *)
        MASQ_TYPE="proxy"
        INPUT_MASQ_URL="https://www.bing.com"
        ;;
esac

# ============================================================
# 第二步：安装 Hysteria 2 主程序
# ============================================================
echo ""
echo "========================================"
echo "安装 Hysteria 2 主程序"
echo "========================================"

if [ ! -x "${HYSTERIA_BIN}" ]; then
    HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)
fi

mkdir -p "${CONFIG_DIR}"
chmod 755 "${CONFIG_DIR}"

# ============================================================
# 第三步：强制重写配置文件（清空官方默认模板）
# ============================================================
echo ""
echo "正在写入自定义配置至 ${CONFIG_FILE}..."

# 删除旧配置或官方安装自带的默认文件
rm -f "${CONFIG_FILE}"

# 1. 基础配置（监听端口与密码）
cat <<EOF> "${CONFIG_FILE}"
listen: :${INPUT_PORT}

auth:
  type: password
  password: "${INPUT_PASSWORD}"
EOF

# 2. 证书/ACME 配置
if [ "${CERT_TYPE}" = "acme_http" ]; then
    cat <<EOF>> "${CONFIG_FILE}"

acme:
  domains:
    - ${INPUT_DOMAIN}
  email: ${INPUT_EMAIL}
EOF

elif [ "${CERT_TYPE}" = "acme_cf" ]; then
    cat <<EOF>> "${CONFIG_FILE}"

acme:
  domains:
    - ${INPUT_DOMAIN}
  email: ${INPUT_EMAIL}
  dns:
    name: cloudflare
    config:
      CF_DNS_API_TOKEN: "${INPUT_CF_TOKEN}"
EOF

elif [ "${CERT_TYPE}" = "self_signed" ]; then
    CERT_FILE="${CONFIG_DIR}/server.crt"
    KEY_FILE="${CONFIG_DIR}/server.key"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
        -days 3650 -subj "/CN=${INPUT_SNI}" >/dev/null 2>&1
    chmod 600 "${KEY_FILE}"
    
    cat <<EOF>> "${CONFIG_FILE}"

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}
EOF
fi

# 3. 伪装配置
case "${MASQ_TYPE}" in
    proxy)
        cat <<EOF>> "${CONFIG_FILE}"

masquerade:
  type: proxy
  proxy:
    url: ${INPUT_MASQ_URL}
    rewriteHost: true
EOF
        ;;
    file)
        cat <<EOF>> "${CONFIG_FILE}"

masquerade:
  type: file
  file:
    dir: ${INPUT_MASQ_DIR}
EOF
        ;;
    statusCode)
        cat <<EOF>> "${CONFIG_FILE}"

masquerade:
  type: statusCode
  statusCode: ${INPUT_MASQ_CODE}
EOF
        ;;
esac

chmod 600 "${CONFIG_FILE}"

# ============================================================
# 第四步：配置 Systemd 服务并启动
# ============================================================
cat <<EOF> "${SERVICE_FILE}"
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

echo ""
echo "检查配置文件语法..."
if "${HYSTERIA_BIN}" check -c "${CONFIG_FILE}"; then
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    echo "========================================"
    echo "【安装成功】以下是为您精准生成的 ${CONFIG_FILE} 内容："
    echo "========================================"
    cat "${CONFIG_FILE}"
    echo "========================================"
else
    echo "配置文件语法检查失败！生成的配置内容如下："
    cat "${CONFIG_FILE}"
    exit 1
fi

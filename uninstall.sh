#!/usr/bin/env bash
set -e

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

echo "正在卸载 Hysteria2..."

# 停止服务
systemctl stop hysteria || true
systemctl disable hysteria || true

# 删除 systemd
rm -f /etc/systemd/system/hysteria.service
systemctl daemon-reload

# 删除程序
rm -f /usr/local/bin/hysteria

# 读取域名（如果存在）
if [ -f "$CONFIG_FILE" ]; then
    DOMAIN=$(grep -E "domains:" -A 1 "$CONFIG_FILE" | tail -n 1 | sed 's/- "//;s/"//')
fi

# 删除配置
rm -rf /etc/hysteria

# 是否删除 ACME 证书
if [ -n "$DOMAIN" ]; then
    echo "检测到 ACME 域名：$DOMAIN"
    echo "是否删除 ACME 证书？(y/n)"
    read DEL_DOMAIN

    if [ "$DEL_DOMAIN" = "y" ]; then
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" --ecc || true
        echo "ACME 证书已删除"
    else
        echo "保留 ACME 证书"
    fi
fi

# 清理防火墙
if command -v ufw >/dev/null 2>&1; then
    ufw delete allow 443/udp || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --remove-port=443/udp --permanent || true
    firewall-cmd --reload || true
fi

echo "Hysteria2 已成功卸载"

#!/usr/bin/env bash
# Hysteria2 一键卸载清理脚本

set -e

# ====== 1. 检查 root 权限 ======
if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 权限运行此脚本！"
  exit 1
fi

echo "======================================"
echo "     Hysteria2 一键卸载与清理"
echo "======================================"
read -p "确定要彻底卸载 Hysteria2 及其配置文件吗？(y/N): " CONFIRM
CONFIRM=${CONFIRM:-n}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消卸载。"
  exit 0
fi

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
ACME_BIN="$HOME/.acme.sh/acme.sh"

# ====== 2. 读取当前配置（用于清理防火墙端口） ======
PORT=""
if [ -f "$CONFIG_FILE" ]; then
  PORT=$(grep -E '^\s*listen:' "$CONFIG_FILE" | awk '{print $2}' | tr -d ':"' || true)
fi

# ====== 3. 停止并删除 systemd 服务 ======
echo "正在停止并移除 Hysteria2 服务..."
if systemctl is-active --quiet hysteria 2>/dev/null; then
  systemctl stop hysteria
fi

if systemctl is-enabled --quiet hysteria 2>/dev/null; then
  systemctl disable hysteria
fi

if [ -f /etc/systemd/system/hysteria.service ]; then
  rm -f /etc/systemd/system/hysteria.service
  systemctl daemon-reload
  systemctl reset-failed
fi

# ====== 4. 删除二进制文件与配置目录 ======
echo "正在清理相关文件和目录..."
rm -f /usr/local/bin/hysteria
rm -rf "$CONFIG_DIR"

# ====== 5. 清理 acme.sh 相关的证书任务（可选） ======
if [ -f "$ACME_BIN" ]; then
  read -p "是否同步清理 acme.sh 申请的域名证书与自动续签？(y/N): " REMOVE_ACME
  REMOVE_ACME=${REMOVE_ACME:-n}
  
  if [[ "$REMOVE_ACME" =~ ^[Yy]$ ]]; then
    read -p "请输入当时绑定的域名: " DOMAIN
    if [ -n "$DOMAIN" ]; then
      "$ACME_BIN" --remove -d "$DOMAIN" --ecc || true
      rm -rf "$HOME/.acme.sh/${DOMAIN}_ecc" || true
      echo "已移除域名 $DOMAIN 的证书管理规则。"
    fi
  fi
fi

# ====== 6. 还原防火墙规则 ======
if [ -n "$PORT" ]; then
  echo "正在清理防火墙规则 (端口: $PORT/udp)..."
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw delete allow $PORT/udp || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --remove-port=$PORT/udp --permanent || true
    firewall-cmd --reload || true
  fi
fi

echo "======================================"
echo "       Hysteria2 已成功彻底卸载！"
echo "======================================"

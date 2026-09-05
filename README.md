#准备工作
ip已经解析到cloudflare
使用acme dns提前创建token

# Hysteria2 

一键安装脚本：

```````
bash <(curl -fsSL https://raw.githubusercontent.com/meizisl/Hy2_muban/main/install.sh)

```````
卸载：
````````
bash <(curl -fsSL https://raw.githubusercontent.com/meizisl/Hy2_muban/main/uninstall.sh)
````````
  | 名称 | 命令 | 
  | ----------- | ------ |
  | 安装        | bash <(curl -fsSL https://get.hy2.sh/) |
  | 生成自签证书 | openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=bing.com" -days 36500 && sudo chown hysteria /etc/hysteria/server.key && sudo chown hysteria /etc/hysteria/server.crt |
  | 启动        | systemctl start hysteria-server.service |
  | 重启        | systemctl restart hysteria-server.service |
  | 查看状态    | systemctl status hysteria-server.service |
  | 停止        | systemctl stop hysteria-server.service |
  | 开机自启    | systemctl enable hysteria-server.service |
  | 查看日志    | journalctl -u hysteria-server.service |
  | 运行日志    | journalctl --no-pager -e -u hysteria-server.service |
  | 查询ech     | /etc/hysteria/ech.pem  |
  | 删除hy      |  bash <(curl -fsSL https://get.hy2.sh/) --remove  |
  | 安装iptables  |  apt install iptables |
  |  查找指定证书位置  | find / -name "`*替换域名*`" 2>/dev/null  #保留*号  |
  | 端口跳跃    |  iptables -t nat -A PREROUTING -p udp --dport 20000:20050 -j DNAT --to-destination :12000  |






















# 项目说明
本项目旨在使用docker尽量便捷地在本地/局域网部署Outline+Keycloak，主要的工作已集成至deploy_outline.sh脚本中，执行脚本并按照脚本提示即可完成安装工作，除去下载镜像的时间，整个部署流程不会超过十分钟。  
**当前版本使用的镜像(2025-12-05)**
1. outlinewiki/outline:1.1.0
2. quay.io/keycloak/keycloak:26.4.7
3. redis:7-alpine
4. postgres:16-alpine

可根据需要自行修改docker-compose.yml中使用的版本
# 使用方法
## 依赖项
1. docker
如果还未安装，可按照下方指令安装
```
sudo apt install apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install docker-ce
sudo systemctl enable docker
sudo systemctl start docker
sudo groupadd docker
sudo usermod -aG docker $USER
```

2. docker-compose
本项目要求docker-compose版本>=2.1.0，如果未安装，可按照下方指令安装最新版
```
curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o docker-compose
sudo mv docker-compose /usr/local/bin/
sudo chmod +x /usr/local/bin/docker-compose
```
如果已经安装，可按照下方指令升级
```
# 1. 移除旧版本（根据安装情况选择）
sudo apt remove docker-compose
# 或
sudo rm /usr/local/bin/docker-compose
# 2. 安装最新版
curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o docker-compose
sudo mv docker-compose /usr/local/bin/
sudo chmod +x /usr/local/bin/docker-compose
# 3. 验证版本
docker-compose -v
``` 
3. docker镜像源配置，参考https://github.com/dongyubin/DockerHub
```
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://docker.1panel.live",
    "https://docker.1ms.run",
    "https://dytt.online",
    "https://docker-0.unsee.tech",
    "https://lispy.org",
    "https://docker.xiaogenban1993.com",
    "https://666860.xyz",
    "https://hub.rat.dev",
    "https://docker.m.daocloud.io",
    "https://demo.52013120.xyz",
    "https://proxy.vvvv.ee",
    "https://registry.cyou"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```
## 部署
```
cd $HOME
mkdir outline && cd outline
git clone https://github.com/yqmy0814/outline_deploy
cd outline_deploy
bash deploy_outline.sh
```
按照脚本提示进行后续操作即可
<div align="center">
    <img src="image/后续步骤.png" width = 100% >
</div>

## 设置Outline管理员
Outline默认第一个登录的用户为管理员，这个用户可以用Outline的用户设置给其他用户设置权限，但如果第一个登录的用户被删除，可执行如下命令配置(假定用户邮箱为test@local.com)
```
cd $HOME/outline/outline_deploy
docker-compose exec postgres psql -U outline -d outline
UPDATE users SET role = 'admin' WHERE email = 'test@local.com';
\q
docker-compose restart outline-app
```
## 应对IP频繁发生变更的情况
如果设备在局域网内的IP也会存在频繁变更的情况，可以通过mDNS服务（使用Avahi）广播域名IP实现固定域名访问。  
1. 安装Avahi
```
sudo apt update
sudo apt install avahi-daemon avahi-utils libnss-mdns -y
```  
2. 查看/修改主机名
```
# 查看当前主机名(Static hostname字段)
hostnamectl
# 如有需要，设置新名称（如"outline-server"）
sudo hostnamectl set-hostname outline-server
```
3. 设置Avahi
```
sudo gedit /etc/avahi/avahi-daemon.conf
```
将use-ipv6修改为no，解除allow-interfaces的注释并修改为局域网使用的网卡名
```
# 启动Avahi
sudo systemctl enable --now avahi-daemon
# 验证IP地址是否正确
avahi-resolve-host-name $(hostname).local
```
4. 创建广播服务
```
sudo gedit ~/outline/ip_monitor.sh
```
输入以下内容，**TARGET_INTERFACE修改为局域网使用的网卡名**，保存
```
#!/bin/bash

# 配置参数
OUTLINE_PORT=7730    # Outline服务端口
ANNOUNCE_PORT=8000   # IP公告服务端口
ANNOUNCE_INTERVAL=30 # IP检测间隔（秒）
HOST_NAME=$(hostname).local
TARGET_INTERFACE="eno1" # 指定要读取的网卡名

get_current_ip() {
  ip addr show "${TARGET_INTERFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n1
}

# 启动IP公告服务
start_announce_server() {
  echo "启动IP公告服务，端口：$ANNOUNCE_PORT..."
  python3 -c "
from http.server import BaseHTTPRequestHandler, HTTPServer
class AnnounceHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'Outline: http://$HOST_NAME:$OUTLINE_PORT')
    
    # 禁用日志输出
    def log_message(self, format, *args):
        return

server = HTTPServer(('0.0.0.0', $ANNOUNCE_PORT), AnnounceHandler)
server.serve_forever()
" &
  ANNOUNCE_PID=$!
  echo "IP公告服务已启动（PID：$ANNOUNCE_PID）"
}

# 检查当前IP是否变化
check_ip_change() {
  CURRENT_IP=$(get_current_ip)
  if [ "$CURRENT_IP" != "$LAST_IP" ]; then
    echo "IP变更：$LAST_IP → $CURRENT_IP"
    LAST_IP=$CURRENT_IP
    
    # 重启公告服务，确保客户端获取最新IP
    kill $ANNOUNCE_PID >/dev/null 2>&1
    start_announce_server
  fi
}

# 初始化
LAST_IP=$(get_current_ip)
# 校验网卡是否存在&是否获取到IP
if [ -z "$LAST_IP" ]; then
  echo "错误：未获取到${TARGET_INTERFACE}网卡的IPv4地址！"
  echo "请检查网卡名是否正确（执行ip a查看），或网卡是否已分配IP"
  exit 1
fi
start_announce_server

# 主循环：定期检测IP变化
echo "开始监控${TARGET_INTERFACE}网卡IP变动..."
while true; do
  check_ip_change
  sleep $ANNOUNCE_INTERVAL
done
```
配置开机自启
```
sudo chmod +x ~/outline/ip_monitor.sh
sudo gedit ~/.config/autostart/ip_monitor.desktop
```
输入以下内容，保存
```
[Desktop Entry]
Type=Application
Version=1.0
Name=mDNS Broadcast
Comment=Broadcast IP
Exec=$HOME/outline/ip_monitor.sh
X-GNOME-Autostart-enabled=true
Hidden=false
Terminal=false
StartupNotify=false
X-GNOME-Autostart-Delay=20
```
5. 修改Outline配置
```
gedit ~/outline/outline_deploy/.env
```
将HOST_IP修改为$(hostname).local  
浏览器访问Keycloak，将outline realm的outline client的  
Valid redirect URIs修改为http://主机名.local:7730/auth/oidc.callback  
Web origins修改为http://主机名.local:7730  
(参考脚本步骤3：配置Keycloak)
6. 重启服务
```
cd $HOME/outline/outline_deploy
docker-compose down
docker-compose up -d
```
7. 访问Outline
现在访问http://主机名.local:7730 就可以正常打开outline了，即使局域网IP发生变更也可以正常使用。
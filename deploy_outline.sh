#!/bin/bash
set -e

# ===================== 第一步：创建data目录及子目录并配置权限 =====================
# 定义需要创建的目录列表
DATA_SUBDIRS=(
    "data/postgres"
    "data/outline"
    "data/keycloak"
    "data/redis"
)

# 创建data主目录及所有子目录
echo "===== 开始创建data目录及子目录 ====="
for dir in "${DATA_SUBDIRS[@]}"; do
    mkdir -p "${dir}"
    echo "✅ 目录创建成功：$(pwd)/${dir}"
done

# 配置目录权限
echo -e "\n===== 配置data目录及子目录权限 ====="
chmod -R 755 ./data
chmod -R 777 ./data/outline

echo "✅ 权限配置完成"

echo -e "\n===== 第一步（目录创建+权限配置）执行完成 ====="

# ===================== 第二步：创建.env文件 =====================
echo -e "\n===== 开始创建.env配置文件 ====="

# 定义默认值
DEFAULT_SUBNET_PREFIX="192.168.232.0"
DEFAULT_KEYCLOAK_PORT="7780"
DEFAULT_OUTLINE_PORT="7730"

# 1. 询问Docker网段前缀
echo -e "网络设置，使用默认值直接按回车即可，否则输入值后按回车"
read -p "请输入docker间通讯使用的网段,不要和已有的网络冲突（格式示例：192.168.232.0，默认：${DEFAULT_SUBNET_PREFIX}）：" INPUT_SUBNET_PREFIX
SUBNET_PREFIX=${INPUT_SUBNET_PREFIX:-${DEFAULT_SUBNET_PREFIX}}

NETWORK_BASE=${SUBNET_PREFIX%.*}
# 动态生成宿主机IP默认值：网段前缀的.1
HOST_IP_DEFAULT="${NETWORK_BASE}.1"

# 3. 询问宿主机IP（默认值为动态生成的.1）
read -p "请输入主机IP，本地部署使用默认值即可，否则输入本机的局域网IP，（默认：${HOST_IP_DEFAULT}）：" INPUT_HOST_IP
HOST_IP=${INPUT_HOST_IP:-${HOST_IP_DEFAULT}}

# 询问端口
read -p "请输入Keycloak映射到主机的端口（默认：${DEFAULT_KEYCLOAK_PORT}）：" INPUT_KEYCLOAK_PORT
KEYCLOAK_PORT=${INPUT_KEYCLOAK_PORT:-${DEFAULT_KEYCLOAK_PORT}}

read -p "请输入Outline映射到主机的端口（默认：${DEFAULT_OUTLINE_PORT}）：" INPUT_OUTLINE_PORT
OUTLINE_PORT=${INPUT_OUTLINE_PORT:-${DEFAULT_OUTLINE_PORT}}

# 基于NETWORK_BASE生成容器子网和各服务固定IP
SUBNET="${SUBNET_PREFIX}/24"
POSTGRES_IP="${NETWORK_BASE}.13"
REDIS_IP="${NETWORK_BASE}.14"
KEYCLOAK_IP="${NETWORK_BASE}.12"
OUTLINE_IP="${NETWORK_BASE}.15"

# 自动生成Outline密钥
OUTLINE_SECRET_KEY=$(openssl rand -hex 32)
OUTLINE_UTILS_SECRET=$(openssl rand -hex 32)
echo "✅ 自动生成Outline密钥完成"

# 写入.env文件
cat > .env << EOF
# ===================== 各服务本地访问配置 =====================
# 容器子网
SUBNET=${SUBNET}
# 各服务固定 IP
POSTGRES_IP=${POSTGRES_IP}
REDIS_IP=${REDIS_IP}
KEYCLOAK_IP=${KEYCLOAK_IP}
OUTLINE_IP=${OUTLINE_IP}

# ===================== 宿主机访问配置 =====================
# 宿主机IP
HOST_IP=${HOST_IP}
# 各服务映射到宿主机的端口
KEYCLOAK_PORT=${KEYCLOAK_PORT}
OUTLINE_PORT=${OUTLINE_PORT}

# 数据库密码
POSTGRES_PASSWORD=outline2025

# ===================== Keycloak配置 =====================
KEYCLOAK_ADMIN=admin
# 建议在网页端自行修改管理员密码
KEYCLOAK_ADMIN_PASSWORD=keycloak2025
KEYCLOAK_REALM=outline
KEYCLOAK_CLIENT_ID=outline
# 此处根据指引从已经部署的keycloak获取
OIDC_CLIENT_SECRET=（请在keycloak部署后填写）

# ===================== Outline配置 =====================
# Outline密钥
OUTLINE_SECRET_KEY=${OUTLINE_SECRET_KEY}
OUTLINE_UTILS_SECRET=${OUTLINE_UTILS_SECRET}
EOF

echo "✅ .env文件创建成功，路径：$(pwd)/.env"
echo "⚠️  注意：.env文件中OIDC_CLIENT_SECRET需在Keycloak部署完成后手动填写"
echo -e "\n===== 第二步（.env文件创建）执行完成 ====="

# ===================== 第三步：生成init-keycloak.sh和docker-compose.yml =====================
echo -e "\n===== 开始创建init-keycloak.sh文件 ====="

# 创建config/postgres目录
mkdir -p config/postgres
echo "✅ 目录创建成功：$(pwd)/config/postgres"

# 写入init-keycloak.sh文件
cat > config/postgres/init-keycloak.sh << EOF
#!/bin/sh
psql -U "\$POSTGRES_USER" -d "\$POSTGRES_DB" << SQL
CREATE DATABASE keycloak;
CREATE USER keycloak WITH ENCRYPTED PASSWORD 'outline2025';
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
ALTER ROLE keycloak SUPERUSER;
SQL
EOF

# 配置init-keycloak.sh执行权限
chmod +x config/postgres/init-keycloak.sh
echo "✅ init-keycloak.sh文件创建成功，路径：$(pwd)/config/postgres/init-keycloak.sh"
echo "✅ init-keycloak.sh执行权限已配置"

echo -e "\n===== 开始创建docker-compose.yml文件 ====="

# 写入docker-compose.yml文件
cat > docker-compose.yml << EOF
networks:
  outline_network:
    driver: bridge
    ipam:
      config:
        - subnet: \${SUBNET}

services:
  # 1. PostgreSQL
  postgres:
    image: postgres:16-alpine
    container_name: outline-db
    networks:
      outline_network:
        ipv4_address: \${POSTGRES_IP}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./config/postgres:/docker-entrypoint-initdb.d
    environment:
      POSTGRES_DB: outline
      POSTGRES_USER: outline
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U outline"]
      interval: 5s
      timeout: 3s
      retries: 3

  # 2. Redis
  redis:
    image: redis:7-alpine
    container_name: outline-redis
    networks:
      outline_network:
        ipv4_address: \${REDIS_IP}
    volumes:
      - ./data/redis:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 3

  # 3. Keycloak
  keycloak:
    image: quay.io/keycloak/keycloak:26.4.7
    container_name: outline-keycloak
    ports:
      - "\${KEYCLOAK_PORT}:8080"
    extra_hosts:
      - "postgres:\${POSTGRES_IP}"
    volumes:
    - ./data/keycloak:/opt/keycloak/data
    networks:
      outline_network:
        ipv4_address: \${KEYCLOAK_IP}
    command: start-dev
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: \${POSTGRES_PASSWORD}
      KEYCLOAK_ADMIN: \${KEYCLOAK_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: \${KEYCLOAK_ADMIN_PASSWORD}
      KC_HOSTNAME_STRICT: "false"
      KC_HOSTNAME_STRICT_HTTPS: "false"
      KC_HTTP_ENABLED: "true"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped

  # 4. Outline
  outline:
    image: outlinewiki/outline:1.1.0
    container_name: outline-app
    networks:
      outline_network:
        ipv4_address: \${OUTLINE_IP}
    ports:
      - "\${OUTLINE_PORT}:3000"
    extra_hosts:
      - "postgres:\${POSTGRES_IP}"
      - "redis:\${REDIS_IP}"
      - "keycloak:\${KEYCLOAK_IP}"
    volumes:
      - ./data/outline:/var/lib/outline/data
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      keycloak:
        condition: service_started
    environment:
      NODE_ENV: production
      PGSSLMODE: disable
      DATABASE_URL: postgres://outline:\${POSTGRES_PASSWORD}@postgres:5432/outline
      DATABASE_URL_TEST: postgres://outline:outline2025@postgres:5432/outline-test
      REDIS_URL: redis://redis:6379
      URL: http://\${HOST_IP}:\${OUTLINE_PORT}
      PORT: 3000
      FORCE_HTTPS: "false"
      FILE_STORAGE: local
      FILE_STORAGE_LOCAL_PATH: /var/outline/uploads
      FILE_STORAGE_UPLOAD_MAX_SIZE: 5368709120
      # OIDC对接Keycloak
      OIDC_CLIENT_ID: \${KEYCLOAK_CLIENT_ID}
      OIDC_CLIENT_SECRET: \${OIDC_CLIENT_SECRET}
      OIDC_AUTH_URI: http://\${HOST_IP}:\${KEYCLOAK_PORT}/realms/\${KEYCLOAK_REALM}/protocol/openid-connect/auth
      OIDC_TOKEN_URI: http://\${HOST_IP}:\${KEYCLOAK_PORT}/realms/\${KEYCLOAK_REALM}/protocol/openid-connect/token
      OIDC_USERINFO_URI: http://\${HOST_IP}:\${KEYCLOAK_PORT}/realms/\${KEYCLOAK_REALM}/protocol/openid-connect/userinfo
      OIDC_DISPLAY_NAME: Keycloak
      OIDC_SCOPES: "openid email profile"
      OIDC_LOGOUT_URI: http://\${HOST_IP}:\${KEYCLOAK_PORT}/realms/outline/protocol/openid-connect/logout?client_id=outline
      SECRET_KEY: \${OUTLINE_SECRET_KEY}
      UTILS_SECRET: \${OUTLINE_UTILS_SECRET}
      DEFAULT_LANGUAGE: zh_CN
    restart: unless-stopped
EOF

echo "✅ docker-compose.yml文件创建成功，路径：$(pwd)/docker-compose.yml"
echo -e "\n===== 第三步（init-keycloak.sh+docker-compose.yml创建）执行完成 ====="

# ===================== 第四步：检查docker-compose版本 =====================
echo -e "\n===== 开始检查Docker Compose版本 ====="

# 获取版本号（兼容v1和v2格式）
if command -v docker-compose &> /dev/null; then
    VERSION_OUTPUT=$(docker-compose version 2>&1)
    
    # 提取版本号（支持两种格式）
    if [[ $VERSION_OUTPUT =~ version\ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        CURRENT_VERSION="${BASH_REMATCH[1]}"
    elif [[ $VERSION_OUTPUT =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        CURRENT_VERSION="${BASH_REMATCH[1]}"
    else
        echo "⚠️  无法解析版本号，跳过检查"
        exit 0
    fi
    
    echo "当前Docker Compose版本：${CURRENT_VERSION}"
    
    # 与最低要求版本2.1.0比较
    REQUIRED_VERSION="2.1.0"
    if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
        echo -e "\n❌ 版本过低！当前：${CURRENT_VERSION}，最低要求：${REQUIRED_VERSION}"
        echo -e "\n🔧 请执行以下命令升级Docker Compose："
        echo "----------------------------------------"
        echo "# 1. 移除旧版本（根据安装情况选择）"
        echo "sudo rm /usr/local/bin/docker-compose"
        echo "# 或"
        echo "sudo apt remove docker-compose"
        echo ""
        echo "# 2. 下载最新版"
        echo "curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o docker-compose"
        echo ""
        echo "# 3. 移动并授权"
        echo "sudo mv docker-compose /usr/local/bin/"
        echo "sudo chmod +x /usr/local/bin/docker-compose"
        echo ""
        echo "# 4. 验证版本"
        echo "docker-compose -v"
        echo "----------------------------------------"
        echo -e "\n⚠️  升级完成后，请重新运行本脚本。"
        exit 1
    else
        echo "✅ 版本符合要求"
    fi
else
    echo "⚠️  未检测到docker-compose命令，请先安装Docker Compose"
    echo -e "\n🔧 安装命令："
    echo "----------------------------------------"
    echo "sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose"
    echo "sudo chmod +x /usr/local/bin/docker-compose"
    echo "----------------------------------------"
    exit 1
fi

# 部署指引部分
echo -e "\n🎉 所有部署文件生成完成！请按照以下步骤完成最终部署：\n"
echo -e "================================================"
# 定义颜色/加粗常量
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
BOLD="\033[1m"
RESET="\033[0m"

# 步骤1：拉取镜像
echo -e "${BOLD}【步骤1/5】拉取Docker镜像${RESET}"
echo -e "${GREEN}${BOLD}执行命令：${RESET}"
echo -e "  docker-compose pull"
echo -e ""

# 步骤2：启动Keycloak
echo -e "${BOLD}【步骤2/5】启动Keycloak服务${RESET}"
echo -e "${GREEN}${BOLD}执行命令：${RESET}"
echo -e "  docker-compose up keycloak -d"
echo -e "${YELLOW}${BOLD}提示：${RESET}等待约30秒，让Keycloak完成部署"
echo -e ""

# 步骤3：配置Keycloak
echo -e "${BOLD}【步骤3/5】配置Keycloak（浏览器访问）${RESET}"
echo -e "${BLUE}${BOLD}访问地址：${RESET}http://${HOST_IP}:${KEYCLOAK_PORT}"
echo -e "${BLUE}${BOLD}初始账号：${RESET}admin / keycloak2025"
echo -e "${YELLOW}${BOLD}登录后建议先修改管理员密码${RESET}："
echo -e "  1. 点击 ${PURPLE}${BOLD}Users → admin → Credentials → Reset password${RESET}"
echo -e "  2. 点击 ${PURPLE}${BOLD}Save → Save password${RESET}(关闭${PURPLE}${BOLD}Temporary${RESET})"
echo -e "\n${BOLD}创建Outline专属Realm：${RESET}"
echo -e "  1. 点击 ${PURPLE}${BOLD}Manage realms → Create realms${RESET}"
echo -e "  2. 填写 ${PURPLE}${BOLD}Realm name${RESET}: outline → 点击Create"
echo -e "\n${BOLD}创建登录用户：${RESET}"
echo -e "  1. 点击 ${PURPLE}${BOLD}Users → Create new user${RESET}"
echo -e "  2. 填写信息："
echo -e "     - ${PURPLE}${BOLD}Username${RESET}：自定义（如test）"
echo -e "     - ${PURPLE}${BOLD}Email${RESET}：自定义（如test@local.com）"
echo -e "     - ${PURPLE}${BOLD}First name/Last name${RESET}：自定义（如test）"
echo -e "     - 开启 ${PURPLE}${BOLD}Email verified${RESET}（勾选开关）"
echo -e "  3. 点击 ${PURPLE}${BOLD}Create${RESET} 完成用户创建"
echo -e "  4. 点击 ${PURPLE}${BOLD}Credentials → Set password${RESET}："
echo -e "     - 设置密码（如12345678）"
echo -e "     - ${PURPLE}${BOLD}Temporary${RESET}：建议开启（登录后强制改密码）"
echo -e "     - 点击 ${PURPLE}${BOLD}Save → Save password${RESET}"
echo -e "\n${BOLD}创建Outline客户端：${RESET}"
echo -e "  1. 点击 ${PURPLE}${BOLD}Clients → Create client${RESET}"
echo -e "  2. 第一页：填写 ${PURPLE}${BOLD}Client ID: outline${RESET} → 点击next"
echo -e "  3. 第二页：开启 ${PURPLE}${BOLD}Client authentication${RESET} → 点击next"
echo -e "  4. 第三页：填写以下配置（复制粘贴）："
echo -e "     - ${PURPLE}${BOLD}Valid redirect URIs${RESET}："
echo -e "       http://${HOST_IP}:${OUTLINE_PORT}/auth/oidc.callback"
echo -e "     - ${PURPLE}${BOLD}Web origins${RESET}："
echo -e "       http://${HOST_IP}:${OUTLINE_PORT}"
echo -e "  5. 点击 ${PURPLE}${BOLD}Save${RESET}"
echo -e "  6. ${RED}${BOLD}重要⚠️${RESET}  点击 ${PURPLE}${BOLD}Credentials${RESET} → 复制 ${PURPLE}${BOLD}Client Secret${RESET}"
echo -e "  7. 将复制的Secret粘贴到${PURPLE}${BOLD}.env${RESET}文件的${PURPLE}${BOLD}OIDC_CLIENT_SECRET${RESET}字段中"
echo -e ""

# 步骤4：重启服务
echo -e "${BOLD}【步骤4/5】重启所有服务${RESET}"
echo -e "${GREEN}${BOLD}执行命令：${RESET}"
echo -e "  docker-compose down"
echo -e "  docker-compose up -d"
echo -e "${YELLOW}${BOLD}提示：${RESET}等待约30秒，让所有服务完成启动"
echo -e ""

# 步骤5：访问Outline
echo -e "${BOLD}【步骤5/5】访问Outline${RESET}"
echo -e "${BLUE}${BOLD}访问地址：${RESET}http://${HOST_IP}:${OUTLINE_PORT}"
echo -e "${BLUE}${BOLD}登录方式：${RESET}使用刚才创建的Keycloak账号（如test/12345678）"
echo -e ""

# 数据迁移
echo -e "${BOLD}注：数据迁移${RESET}"
echo -e "📁 所有数据存储在 ./data 目录，如需迁移，将整个outline_deploy文件夹移动到新设备，按照实际情况修改.env的HOST_IP，并登录Keycloak对应修改Valid redirect URI和Web origins的网址即可恢复使用"
echo -e "================================================"


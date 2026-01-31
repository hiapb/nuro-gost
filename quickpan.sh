#!/bin/bash

# ================= 下载链接配置 (请在此处填入 Gost 面板二进制包链接) =================
URL_AMD="https://github.com/hiapb/nuro-gost/releases/download/gost-pan/gost-panel-amd.tar.gz"
URL_ARM="https://github.com/hiapb/nuro-gost/releases/download/gost-pan/gost-panel-arm.tar.gz"
# ==============================================================================

PANEL_PORT="4795"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# 路径配置 
BINARY_PATH="/usr/local/bin/gost-panel"
SERVICE_FILE="/etc/systemd/system/gost-panel.service"
DATA_FILE="/etc/gost/panel_data.json"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}             Gost 面板 一键部署           ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 检测历史安装信息并保留配置
if [ -f "$DATA_FILE" ] && [ -f "$SERVICE_FILE" ]; then
    echo -e "${CYAN}>>> 检测到历史安装信息...${RESET}"
    
    # 尝试从旧数据提取账号密码
    OLD_USER=$(grep '"username":' "$DATA_FILE" | awk -F'"' '{print $4}')
    OLD_PASS=$(grep '"pass_hash":' "$DATA_FILE" | awk -F'"' '{print $4}')
    OLD_PORT=$(grep "PANEL_PORT=" "$SERVICE_FILE" | sed 's/.*PANEL_PORT=\([0-9]*\).*/\1/')

    if [ -n "$OLD_USER" ] && [ -n "$OLD_PASS" ]; then
        DEFAULT_USER="$OLD_USER"
        DEFAULT_PASS="$OLD_PASS"
        echo -e "    已保留账号: ${GREEN}$DEFAULT_USER${RESET}"
    fi

    if [ -n "$OLD_PORT" ]; then
        PANEL_PORT="$OLD_PORT"
        echo -e "    已保留端口: ${GREEN}$PANEL_PORT${RESET}"
    fi
fi

# 架构检测
ARCH=$(uname -m)
DOWNLOAD_URL=""

if [ "$ARCH" == "x86_64" ]; then
    echo -e ">>> 检测到系统架构: ${CYAN}AMD64 (x86_64)${RESET}"
    DOWNLOAD_URL=$URL_AMD
elif [ "$ARCH" == "aarch64" ]; then
    echo -e ">>> 检测到系统架构: ${CYAN}ARM64 (aarch64)${RESET}"
    DOWNLOAD_URL=$URL_ARM
else
    echo -e "${RED} [错误] 不支持的系统架构: $ARCH${RESET}"
    exit 1
fi

# 检查链接是否已配置
if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED} [错误] 脚本内未配置下载链接 (URL_AMD/URL_ARM)，请编辑脚本填入链接后重试！${RESET}"
    exit 1
fi

echo -n ">>> 正在安装基础依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update >/dev/null 2>&1
    apt-get install -y curl wget libssl-dev >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget openssl-devel >/dev/null 2>&1
fi
echo -e "${GREEN} [完成]${RESET}"

echo -n ">>> 正在下载 Gost 面板..."
rm -f /tmp/gost-panel.tar.gz
curl -L "$DOWNLOAD_URL" -o /tmp/gost-panel.tar.gz >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED} [失败] 下载失败，请检查 Release 链接是否有效${RESET}"
    exit 1
fi

# 停止旧服务
systemctl stop gost-panel >/dev/null 2>&1

# 解压安装
tar -xzvf /tmp/gost-panel.tar.gz -C /usr/local/bin/ >/dev/null 2>&1
chmod +x "$BINARY_PATH"
rm -f /tmp/gost-panel.tar.gz
echo -e "${GREEN} [完成]${RESET}"

# 确保配置目录存在
mkdir -p "$(dirname "$DATA_FILE")"

# IPv6 检测
if ip -6 addr show scope global | grep -q "inet6"; then
    HAS_IPV6="true"
else
    HAS_IPV6="false"
fi

# 创建系统服务
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gost Panel ($ARCH)
After=network.target

[Service]
User=root
Environment="PANEL_USER=$DEFAULT_USER"
Environment="PANEL_PASS=$DEFAULT_PASS"
Environment="PANEL_PORT=$PANEL_PORT"
Environment="ENABLE_IPV6=$HAS_IPV6"
ExecStart=$BINARY_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gost-panel >/dev/null 2>&1
systemctl restart gost-panel >/dev/null 2>&1

IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}✅ Gost 转发面板部署成功!${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "当前用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "当前密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"

#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}开始卸载 Gost 面板 ...${RESET}"

echo -e ">>> 正在停止面板服务..."
systemctl stop gost-panel >/dev/null 2>&1
systemctl disable gost-panel >/dev/null 2>&1
rm -f /etc/systemd/system/gost-panel.service
systemctl daemon-reload
echo -e "${GREEN}[1/7] 面板服务已移除${RESET}"

echo -e ">>> 正在清理流量统计防火墙规则..."
# 清理 INPUT 链引用
iptables -D INPUT -j GOST_IN 2>/dev/null || true
# 清理 OUTPUT 链引用
iptables -D OUTPUT -j GOST_OUT 2>/dev/null || true
# 清空自定义链
iptables -F GOST_IN 2>/dev/null || true
iptables -F GOST_OUT 2>/dev/null || true
# 删除自定义链
iptables -X GOST_IN 2>/dev/null || true
iptables -X GOST_OUT 2>/dev/null || true
echo -e "${GREEN}[2/7] 流量统计规则已清理${RESET}"

echo -e ">>> 正在清理程序文件..."
rm -f /usr/local/bin/gost-panel
rm -rf /opt/gost_panel
echo -e "${GREEN}[3/7] 程序文件已删除${RESET}"

echo -e ">>> 正在清理配置与数据..."
rm -rf /etc/gost
echo -e "${GREEN}[4/7] 配置文件已删除${RESET}"

echo -e ">>> 正在卸载 Rust 环境..."
if command -v rustup &> /dev/null; then
    rustup self uninstall -y >/dev/null 2>&1
fi
rm -rf "$HOME/.cargo"
rm -rf "$HOME/.rustup"
sed -i '/.cargo\/env/d' "$HOME/.bashrc"
echo -e "${GREEN}[5/7] Rust 环境已移除${RESET}"

echo -e ">>> 正在清理系统编译依赖..."
if [ -f /etc/debian_version ]; then
    apt-get remove --purge -y build-essential pkg-config libssl-dev >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum groupremove -y "Development Tools" >/dev/null 2>&1
    yum remove -y openssl-devel >/dev/null 2>&1
fi
echo -e "${GREEN}[6/7] 系统编译依赖已清理${RESET}"

echo -e ">>> 正在清理临时文件..."
rm -rf /tmp/gost_install
echo -e "${GREEN}[7/7] 临时文件已清理${RESET}"

echo -e "\n${GREEN}==========================================${RESET}"
echo -e "${GREEN}      ✅ Gost 面板及环境已彻底卸载     ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

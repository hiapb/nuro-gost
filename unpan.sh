#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

clear
echo -e "${RED}==========================================${RESET}"
echo -e "${RED}        Gost 面板及环境 卸载向导          ${RESET}"
echo -e "${RED}==========================================${RESET}"

read -p "是否同时彻底卸载 Gost 核心程序及所有转发配置? (y/N) [默认N]: " uninstall_core
uninstall_core=${uninstall_core:-n}

systemctl stop gost-panel >/dev/null 2>&1
systemctl disable gost-panel >/dev/null 2>&1
rm -f /etc/systemd/system/gost-panel.service
systemctl daemon-reload

rm -f /usr/local/bin/gost-panel
rm -rf /opt/gost_panel
rm -f /etc/gost/panel_data.json

if [[ "$uninstall_core" =~ ^[Yy]$ ]]; then
    systemctl stop gost >/dev/null 2>&1
    systemctl disable gost >/dev/null 2>&1
    rm -f /etc/systemd/system/gost.service
    rm -f /usr/local/bin/gost
    rm -rf /etc/gost
    systemctl daemon-reload
fi

if command -v rustup &> /dev/null; then
    rustup self uninstall -y >/dev/null 2>&1
fi

rm -rf "$HOME/.cargo"
rm -rf "$HOME/.rustup"

if [ -f "$HOME/.bashrc" ]; then
    sed -i '/.cargo\/env/d' "$HOME/.bashrc"
fi

if [ -f /etc/debian_version ]; then
    apt-get remove --purge -y build-essential pkg-config libssl-dev >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum groupremove -y "Development Tools" >/dev/null 2>&1
    yum remove -y openssl-devel >/dev/null 2>&1
fi

rm -rf /tmp/gost_install

echo -e "\n${GREEN}==========================================${RESET}"
if [[ "$uninstall_core" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}    Gost 面板及核心程序已全部卸载！      ${RESET}"
else
    echo -e "${GREEN}    Gost 面板已卸载 (核心服务保留)！      ${RESET}"
fi
echo -e "${GREEN}==========================================${RESET}"

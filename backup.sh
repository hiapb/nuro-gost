#!/bin/bash
# gost-panel-full-menu.sh
# 菜单版：1 一键备份 / 2 一键恢复(输入路径) / 0 退出
# 备份：打包面板数据+gost配置+systemd服务文件+二进制(如存在)+meta+sha256
# 恢复：停止服务->解包覆盖->systemd reload->enable/start
# 注意：iptables/conntrack 计数器现场无法跨机器迁移；但 panel_data.json 内 traffic_used 会被完整备份/恢复。

set -euo pipefail

# ===== 可改 =====
BACKUP_DIR="/root"
PREFIX="gost_full_backup"
# ==============

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}[X] 请用 root 运行${RESET}"
    exit 1
  fi
}

log() { echo -e "${CYAN}[+] $*${RESET}"; }
ok()  { echo -e "${GREEN}[✓] $*${RESET}"; }
warn(){ echo -e "${YELLOW}[!] $*${RESET}"; }
die() { echo -e "${RED}[X] $*${RESET}"; exit 1; }

svc_stop() {
  local s="$1"
  if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
    systemctl stop "$s" >/dev/null 2>&1 || true
  fi
}

svc_start() {
  local s="$1"
  if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
    systemctl enable "$s" >/dev/null 2>&1 || true
    systemctl start "$s" >/dev/null 2>&1 || true
  fi
}

exists_or_skip_list() {
  for f in "$@"; do
    if [ -e "$f" ]; then
      echo "$f"
    fi
  done
}

do_backup() {
  local ts out tmp meta filelist
  ts="$(date +"%Y%m%d_%H%M%S")"
  out="${BACKUP_DIR}/${PREFIX}_${ts}.tar.gz"
  tmp="$(mktemp -d)"
  meta="${tmp}/meta.json"
  filelist="${tmp}/filelist.txt"

  log "停止服务（防止写入中）"
  svc_stop gost-panel
  svc_stop gost

  log "准备元信息"
  local arch kernel os ip
  arch="$(uname -m)"
  kernel="$(uname -r)"
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo "unknown")"
  ip="$(curl -s4 ifconfig.me 2>/dev/null || true)"
  ip="${ip:-unknown}"

  cat > "$meta" <<EOF
{
  "created_at": "$(date -Iseconds)",
  "arch": "${arch}",
  "kernel": "${kernel}",
  "os": "$(echo "$os" | sed 's/"/\\"/g')",
  "public_ip": "$(echo "$ip" | tr -d '\n' | sed 's/"/\\"/g')",
  "note": "iptables/conntrack counters cannot be migrated; panel traffic_used is preserved."
}
EOF

  log "收集要备份的文件"
  {
    echo "/etc/gost/panel_data.json"
    echo "/etc/gost/config.json"
    echo "/etc/systemd/system/gost.service"
    echo "/etc/systemd/system/gost-panel.service"
    echo "/usr/local/bin/gost"
    echo "/usr/local/bin/gost-panel"
  } > "$filelist"

  local to_pack
  to_pack="$(exists_or_skip_list $(cat "$filelist"))" || true

  if [ -z "${to_pack:-}" ]; then
    rm -rf "$tmp"
    die "没找到任何可备份文件（/etc/gost/ 或 service 文件不存在？）"
  fi

  log "打包：$out"
  # 把 meta.json 放到压缩包根目录
  tar -czf "$out" \
    $to_pack \
    -C "$tmp" meta.json \
    2>/dev/null || true

  log "生成校验（如支持）"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$out" > "${out}.sha256"
    ok "已生成：${out}.sha256"
  else
    warn "系统无 sha256sum，跳过校验文件"
  fi

  log "启动服务"
  svc_start gost
  svc_start gost-panel

  ok "备份完成：$out"
  [ -f "${out}.sha256" ] && ok "校验：$(awk '{print $1}' "${out}.sha256")"

  rm -rf "$tmp"
}

do_restore() {
  local pkg="$1"
  [ -f "$pkg" ] || die "备份包不存在：$pkg"

  log "校验备份包（如有 .sha256）"
  if [ -f "${pkg}.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$pkg")" && sha256sum -c "$(basename "${pkg}.sha256")") || die "sha256 校验失败"
    ok "sha256 校验通过"
  else
    warn "未发现 .sha256 或系统无 sha256sum，跳过校验"
  fi

  log "停止服务"
  svc_stop gost-panel
  svc_stop gost

  log "解包覆盖到 /"
  tar -xzf "$pkg" -C / || die "解包失败"

  log "重载 systemd"
  systemctl daemon-reload

  mkdir -p /etc/gost >/dev/null 2>&1 || true

  log "启用并启动服务"
  svc_start gost
  svc_start gost-panel

  ok "恢复完成"
  warn "说明：iptables/conntrack 计数现场无法迁移；但 panel_data.json(含 traffic_used) 已恢复，迁移后会从新机器计数继续累加。"
}

pause() {
  read -r -p "按回车键返回菜单..." _
}

menu() {
  clear
  echo -e "${GREEN}=====================================${RESET}"
  echo -e "${GREEN}   Gost 面板 完整备份/恢复 菜单版   ${RESET}"
  echo -e "${GREEN}=====================================${RESET}"
  echo ""
  echo "1) 一键备份（生成 tar.gz）"
  echo "2) 一键恢复（输入备份文件路径）"
  echo "0) 退出"
  echo ""
}

main() {
  need_root
  mkdir -p "$BACKUP_DIR" >/dev/null 2>&1 || true

  while true; do
    menu
    read -r -p "请选择 [0-2]: " choice
    case "${choice:-}" in
      1)
        echo ""
        do_backup
        echo ""
        pause
        ;;
      2)
        echo ""
        read -r -p "请输入备份文件路径（.tar.gz）: " path
        path="${path//\"/}"
        path="${path//\'/}"
        [ -n "${path:-}" ] || { warn "路径为空"; pause; continue; }
        do_restore "$path"
        echo ""
        pause
        ;;
      0)
        echo -e "${GREEN}Bye.${RESET}"
        exit 0
        ;;
      *)
        warn "无效选项"
        pause
        ;;
    esac
  done
}

main

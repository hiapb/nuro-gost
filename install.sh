#!/bin/bash
set -e

# =================配置区域=================
PANEL_PORT="4795"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# 核心路径配置
GOST_BIN="/usr/local/bin/gost"
CONFIG_FILE="/etc/gost/config.yaml"

RULES_DB="/etc/gost/rules.conf"

SERVICE_FILE="/etc/systemd/system/gost.service"
PANEL_SERVICE_FILE="/etc/systemd/system/gost-panel.service"
TMP_DIR="/tmp/gost_install"

GOST_DIR="/etc/gost"
BACKUP_DIR="/etc/gost/backups"
DEFAULT_EXPORT_FILE="$BACKUP_DIR/gost-backup.tar.gz"
DEFAULT_IMPORT_FILE="$BACKUP_DIR/gost-backup.tar.gz"

CRON_FILE="/etc/cron.d/gost-rules-export"
EXPORT_HELPER="/usr/local/bin/gost-export-rules.sh"

# 颜色
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

# ================= 基础函数 =================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本。${RESET}"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo -e "${RED}缺少依赖命令：$1，请先安装。${RESET}"
    exit 1
  }
}

is_installed() {
  [ -x "$GOST_BIN" ] && [ -f "$SERVICE_FILE" ]
}

require_installed() {
  if ! is_installed; then
    echo -e "${RED}Gost 未安装，请先选择 1 安装。${RESET}"
    return 1
  fi
  return 0
}

ensure_config_file() {
  mkdir -p "$GOST_DIR"
  if [ ! -f "$RULES_DB" ]; then
    touch "$RULES_DB"
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    regenerate_gost_config
  fi
}

# ================= 增强校验函数 (还原原版功能) =================

validate_name() {
  local name="$1"
  [ -z "$name" ] && return 1
  if [[ ! "$name" =~ ^[0-9a-zA-Z_-]+$ ]]; then
      # Gost YAML 对名称比较敏感，限制为字母数字下划线
      return 1 
  fi
  return 0
}

# 检测本机是否有 IPv6
has_ipv6() { command -v ip >/dev/null 2>&1 || return 1; ip -6 addr show 2>/dev/null | awk '/inet6/ && $2 !~ /^::1/ {ok=1} END{exit ok?0:1}'; }

# 选择监听协议
choose_listen_mode_v4v6() {
  while true; do
    echo "请选择监听协议：" >&2
    echo "1. IPv4【默认】" >&2
    echo "2. IPv6" >&2
    read -p "请选择 [1-2]（默认 1）: " MODE
    MODE="${MODE:-1}"
    case "$MODE" in
      1) echo "v4"; return 0 ;;
      2)
        if has_ipv6; then echo "v6"; return 0
        else echo -e "${RED}本机无可用 IPv6，请改选 IPv4。${RESET}" >&2
        fi ;;
      *) echo -e "${RED}无效选项，请重新选择。${RESET}" >&2 ;;
    esac
  done
}

# 检查系统端口占用
port_in_use_system() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntu 2>/dev/null | awk '{print $4}' | awk -v p=":$port" '$0 ~ (p"$") {found=1} END{exit found?0:1}'
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | awk -v p=":$port" '$0 ~ (p"$") {found=1} END{exit found?0:1}'
    return $?
  fi
  return 1
}

# 检查配置冲突
config_port_conflict() {
  local port="$1"
  local exclude_idx="${2:-}" # 
  
  local i=1
  while IFS='|' read -r status name listen remote; do
      if [ -n "$exclude_idx" ] && [ "$i" -eq "$exclude_idx" ]; then
          ((i++))
          continue
      fi
      
      # 提取当前规则端口
      local current_port="${listen##*:}"
      if [ "$current_port" == "$port" ]; then
          return 0 # 冲突
      fi
      ((i++))
  done < "$RULES_DB"
  return 1 # 无冲突
}

# 智能端口输入提示
prompt_listen_port_checked() {
  local exclude_idx="${1:-}" 
  local current_val="${2:-}"
  local p=""
  
  while true; do
    read -p "请输入监听端口: " p
    # 如果用户没输入且有默认值(修改模式)，则保留原值
    if [ -z "$p" ] && [ -n "$current_val" ]; then echo "$current_val"; return 0; fi
    
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      echo -e "${RED}端口必须是 1-65535 的数字。${RESET}" >&2
      continue
    fi
    
    # 检查配置冲突
    if config_port_conflict "$p" "$exclude_idx"; then
      echo -e "${RED}端口 $p 已被脚本内的其他规则占用，请重新输入。${RESET}" >&2
      continue
    fi
    
    # 检查系统占用
    if port_in_use_system "$p"; then
      # 如果是修改模式，且端口没变，不算系统占用(被自己占用了)
      if [ "$p" != "$current_val" ]; then
          echo -e "${YELLOW}提示：系统检测到端口 $p 正在被其他程序占用。${RESET}" >&2
          read -p "仍然使用该端口吗？[y/N]: " ANS
          case "$ANS" in y|Y) echo "$p"; return 0 ;; *) continue ;; esac
      fi
    fi
    
    echo "$p"; return 0
  done
}

# 远程地址输入提示
prompt_remote_by_mode() {
  local MODE="$1" REMOTE=""
  while true; do
    if [ "$MODE" = "v4" ]; then
      echo -e "${GREEN}远程目标：IPv4/域名:PORT  例：1.2.3.4:443${RESET}" >&2
      read -r -p "请输入远程目标: " REMOTE
      [ -z "$REMOTE" ] && { echo -e "${RED}远程目标不能为空。${RESET}" >&2; continue; }
      echo "$REMOTE"; return 0
    else
      echo -e "${GREEN}远程目标：[IPv6]:PORT  例：[2001:db8::1]:443${RESET}" >&2
      read -r -p "请输入远程目标: " REMOTE
      [ -z "$REMOTE" ] && { echo -e "${RED}远程目标不能为空。${RESET}" >&2; continue; }
      echo "$REMOTE"; return 0
    fi
  done
}

# ================= 服务管理 =================

restart_gost_silent() {
  if ! systemctl restart gost >/dev/null 2>&1; then
    systemctl restart gost || true
  fi
  # 尝试刷新面板（如果安装了）
  if [ -f "$PANEL_SERVICE_FILE" ]; then
      systemctl reload gost-panel >/dev/null 2>&1 || systemctl restart gost-panel >/dev/null 2>&1 || true
  fi
}

restart_gost_verbose() {
  systemctl restart gost
  echo -e "${GREEN}Gost 服务已重启。${RESET}"
  if [ -f "$PANEL_SERVICE_FILE" ]; then
      systemctl restart gost-panel
      echo -e "${GREEN}Gost 面板已重启。${RESET}"
  fi
}

get_gost_version_short() {
  if [ -x "$GOST_BIN" ]; then
      $GOST_BIN -V 2>&1 | awk '{print $2}'
  else
      echo "未知"
  fi
}

get_status_line() {
  if ! is_installed; then
    echo -e "状态：${YELLOW}未安装${RESET}"
    return
  fi
  local status ver
  status="$(systemctl is-active gost 2>/dev/null || true)"
  ver="$(get_gost_version_short)"
  if [ "$status" = "active" ]; then
    echo -e "状态：${GREEN}运行中${RESET}  |  版本：${GREEN}${ver}${RESET}"
  else
    echo -e "状态：${RED}未运行${RESET}  |  版本：${GREEN}${ver}${RESET}"
  fi
}

# ================= 安装逻辑 =================

install_gost_inner() {
  need_cmd curl
  need_cmd tar
  need_cmd systemctl
  
  echo -e "${GREEN}正在安装 Gost V3 ...${RESET}"
  
  # 系统优化
  if [ ! -f "/etc/sysctl.d/99-gost.conf" ]; then
      cat > /etc/sysctl.d/99-gost.conf <<EOF
fs.file-max = 1000000
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
EOF
      sysctl -p /etc/sysctl.d/99-gost.conf >/dev/null 2>&1 || true
  fi

  ARCH=$(uname -m)
  case "$ARCH" in
      x86_64) GOST_ARCH="linux_amd64" ;;
      aarch64|arm64) GOST_ARCH="linux_arm64" ;;
      *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; exit 1 ;;
  esac
  
  TAG=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  [ -z "$TAG" ] && TAG="v3.0.0"
  
  URL="https://github.com/go-gost/gost/releases/download/${TAG}/gost_${TAG#v}_${GOST_ARCH}.tar.gz"
  
  echo -e "${GREEN}下载地址: $URL${RESET}"
  mkdir -p "$TMP_DIR"
  if ! curl -L -o "$TMP_DIR/gost.tar.gz" "$URL"; then
      echo -e "${RED}下载失败${RESET}"
      exit 1
  fi
  
  tar -xzf "$TMP_DIR/gost.tar.gz" -C "$TMP_DIR"
  mv "$TMP_DIR/gost" "$GOST_BIN"
  chmod +x "$GOST_BIN"
  rm -rf "$TMP_DIR"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gost Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$GOST_BIN -C $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
LimitNOFILE=1000000
LimitNPROC=1000000

[Install]
WantedBy=multi-user.target
EOF

  ensure_config_file
  systemctl daemon-reload
  systemctl enable gost >/dev/null 2>&1 || true
  systemctl restart gost
  
  echo -e "${GREEN}安装完成。当前版本：$(get_gost_version_short)${RESET}"
}

install_gost() {
  if is_installed; then
    echo -e "${YELLOW}Gost 已安装。是否更新/重装？[y/N]${RESET}"
    read -r ANS
    case "$ANS" in
      y|Y) install_gost_inner ;;
      *) echo -e "${YELLOW}已取消。${RESET}" ;;
    esac
  else
    install_gost_inner
  fi
}

uninstall_gost() {
  echo -e "${YELLOW}正在卸载 Gost 面板(如果有)...${RESET}"
  if [ -f "$PANEL_SERVICE_FILE" ]; then
      systemctl stop gost-panel >/dev/null 2>&1 || true
      systemctl disable gost-panel >/dev/null 2>&1 || true
      rm -f "$PANEL_SERVICE_FILE" "$PANEL_BIN"
  fi

  echo -e "${YELLOW}正在卸载 Gost 主程序...${RESET}"
  systemctl stop gost >/dev/null 2>&1 || true
  systemctl disable gost >/dev/null 2>&1 || true
  rm -f "$GOST_BIN" "$SERVICE_FILE" "$CONFIG_FILE" "$RULES_DB"
  rm -rf "$GOST_DIR"
  rm -f /etc/sysctl.d/99-gost.conf
  systemctl daemon-reload
  echo -e "${GREEN}Gost 及面板已全部卸载完成。${RESET}"
}

# ================= 核心：配置生成器 =================
# 将 rules.conf (简易格式) 转换为 config.yaml (复杂格式)
regenerate_gost_config() {
    cat > "$CONFIG_FILE" <<EOF
services:
EOF
    
    if [ -f "$RULES_DB" ]; then
        while IFS='|' read -r status name listen remote; do
            if [ "$status" == "1" ]; then
                cat >> "$CONFIG_FILE" <<EOF
  - name: service-${name}-tcp
    addr: $listen
    handler:
      type: tcp
      chain: chain-${name}
    listener:
      type: tcp
  - name: service-${name}-udp
    addr: $listen
    handler:
      type: udp
      chain: chain-${name}
    listener:
      type: udp
EOF
            fi
        done < "$RULES_DB"
    fi

    cat >> "$CONFIG_FILE" <<EOF
chains:
EOF
    if [ -f "$RULES_DB" ]; then
        while IFS='|' read -r status name listen remote; do
            if [ "$status" == "1" ]; then
                cat >> "$CONFIG_FILE" <<EOF
  - name: chain-${name}
    hops:
      - nodes:
        - addr: $remote
EOF
            fi
        done < "$RULES_DB"
    fi
    
    if systemctl is-active gost >/dev/null 2>&1; then
        systemctl reload gost
    fi
}

# ================= 规则管理逻辑 =================

print_rules_pretty() {
  ensure_config_file
  if [ ! -s "$RULES_DB" ]; then
    echo -e "${YELLOW}暂无转发规则。${RESET}"
    return 1
  fi
  
  echo -e "${GREEN}当前转发规则列表：${RESET}"
  local i=1
  while IFS='|' read -r status name listen remote; do
      local st_text
      if [ "$status" == "1" ]; then
          st_text="${GREEN}启用${RESET}"
      else
          st_text="${RED}暂停${RESET}"
      fi
      echo -e "$i. [$st_text] [$name] $listen -> $remote"
      ((i++))
  done < "$RULES_DB"
  return 0
}

add_rule() {
  ensure_config_file
  local MODE NAME PORT LISTEN REMOTE
  
  MODE="$(choose_listen_mode_v4v6)"
  
  while true; do
    read -p "请输入规则备注(仅限字母数字): " NAME
    if validate_name "$NAME"; then break; fi
    echo -e "${RED}名称不合法。${RESET}"
  done
  
  PORT="$(prompt_listen_port_checked "" "")"
  REMOTE="$(prompt_remote_by_mode "$MODE")"
  
  # 组装监听地址
  if [ "$MODE" = "v6" ]; then
      LISTEN="[::]:$PORT"
  else
      LISTEN=":$PORT"
  fi
  
  echo "1|$NAME|$LISTEN|$REMOTE" >> "$RULES_DB"
  
  regenerate_gost_config
  echo -e "${GREEN}规则已添加并应用。${RESET}"
}

delete_rule() {
  if ! print_rules_pretty; then return; fi
  
  mapfile -t RULES < "$RULES_DB"
  local count=${#RULES[@]}
  
  read -p "请输入要删除的规则编号: " IDX
  if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt "$count" ]; then
      echo -e "${RED}编号无效。${RESET}"
      return
  fi
  
  sed -i "${IDX}d" "$RULES_DB"
  
  regenerate_gost_config
  echo -e "${GREEN}规则已删除并应用。${RESET}"
}

clear_rules() {
  > "$RULES_DB"
  regenerate_gost_config
  echo -e "${GREEN}所有规则已清空。${RESET}"
}

toggle_rule() {
  if ! print_rules_pretty; then return; fi
  
  mapfile -t RULES < "$RULES_DB"
  local count=${#RULES[@]}
  
  read -p "请输入要 启用/暂停 的规则编号: " IDX
  if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt "$count" ]; then
      echo -e "${RED}编号无效。${RESET}"
      return
  fi
  
  local line="${RULES[$((IDX-1))]}"
  local status name listen remote
  IFS='|' read -r status name listen remote <<< "$line"
  
  local new_status
  if [ "$status" == "1" ]; then new_status="0"; else new_status="1"; fi
  
  local new_line="$new_status|$name|$listen|$remote"
  sed -i "${IDX}s/.*/$new_line/" "$RULES_DB"
  
  regenerate_gost_config
  if [ "$new_status" == "1" ]; then
      echo -e "${GREEN}规则已启用。${RESET}"
  else
      echo -e "${YELLOW}规则已暂停。${RESET}"
  fi
}

edit_rule() {
  if ! print_rules_pretty; then return; fi
  mapfile -t RULES < "$RULES_DB"
  local count=${#RULES[@]}
  
  read -p "请输入要修改的规则编号: " IDX
  if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt "$count" ]; then
      echo -e "${RED}编号无效。${RESET}"
      return
  fi
  
  # 读取当前数据
  local line="${RULES[$((IDX-1))]}"
  local status name listen remote
  IFS='|' read -r status name listen remote <<< "$line"
  
  # 解析当前端口和模式
  local cur_port="${listen##*:}"
  local mode="v4"
  if [[ "$listen" == \[* ]]; then mode="v6"; fi
  
  echo -e "${GREEN}当前选中：[$name] $listen -> $remote${RESET}"
  echo "要修改哪个字段？"
  echo "1. 备注名称"
  echo "2. 监听端口"
  echo "3. 远程目标"
  echo "0. 返回"
  read -p "请选择 [0-3]: " OPT
  
  case "$OPT" in
    1)
      local NEW_NAME
      while true; do
        read -p "请输入新名称: " NEW_NAME
        if validate_name "$NEW_NAME"; then break; fi
        echo -e "${RED}名称不合法。${RESET}"
      done
      name="$NEW_NAME"
      ;;
    2)
      local NEW_PORT
      # 传入 IDX 以在冲突检测中排除自身
      NEW_PORT="$(prompt_listen_port_checked "$IDX" "$cur_port")"
      if [ "$mode" = "v6" ]; then
          listen="[::]:$NEW_PORT"
      else
          listen=":$NEW_PORT"
      fi
      ;;
    3)
      local NEW_REMOTE
      NEW_REMOTE="$(prompt_remote_by_mode "$mode")"
      remote="$NEW_REMOTE"
      ;;
    0) return ;;
    *) echo -e "${RED}无效选项。${RESET}"; return ;;
  esac
  
  # 更新数据库
  local new_line="$status|$name|$listen|$remote"
  sed -i "${IDX}s|.*|$new_line|" "$RULES_DB"
  
  regenerate_gost_config
  echo -e "${GREEN}修改成功并已应用。${RESET}"
}

# ================= 备份与导入 =================

export_rules() {
  ensure_config_file
  mkdir -p "$BACKUP_DIR"
  read -p "导出文件路径 [默认 ${DEFAULT_EXPORT_FILE}]: " OUT
  OUT="${OUT:-$DEFAULT_EXPORT_FILE}"
  
  echo -e "${GREEN}正在打包规则数据...${RESET}"
  # 备份 rules.conf, config.yaml 和 面板数据
  local FILES_TO_BACKUP="rules.conf config.yaml"
  if [ -f "$PANEL_DATA_FILE" ]; then
      FILES_TO_BACKUP="$FILES_TO_BACKUP panel_data.json"
  fi
  
  tar -czf "$OUT" -C "$GOST_DIR" $FILES_TO_BACKUP
  if [ -s "$OUT" ]; then
    echo -e "${GREEN}导出成功：$OUT${RESET}"
  else
    echo -e "${RED}导出失败。${RESET}"
  fi
}

import_rules() {
  ensure_config_file
  read -p "请输入导入文件路径 [默认 ${DEFAULT_IMPORT_FILE}]: " IN
  IN="${IN:-$DEFAULT_IMPORT_FILE}"
  if [ ! -f "$IN" ]; then echo -e "${RED}文件不存在。${RESET}"; return; fi
  
  echo -e "${YELLOW}警告：这将覆盖现有规则！${RESET}"
  read -p "确认覆盖? [y/N]: " ANS
  case "$ANS" in y|Y) ;; *) return ;; esac
  
  tar -xzf "$IN" -C "$GOST_DIR"
  regenerate_gost_config
  echo -e "${GREEN}导入成功并已重载配置。${RESET}"
}

# ================= 杂项与 Cron =================

has_cron() {
  command -v crontab >/dev/null 2>&1 || command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1
}

install_cron() {
  echo -e "${YELLOW}未检测到 Cron，尝试安装...${RESET}"
  if [ -f /etc/debian_version ]; then
    apt update && apt install -y cron
    systemctl enable cron && systemctl start cron
  elif [ -f /etc/redhat-release ]; then
    yum install -y cronie
    systemctl enable crond && systemctl start crond
  else
    echo -e "${RED}无法自动安装 Cron，请手动安装。${RESET}"
    return 1
  fi
}

ensure_cron_ready() {
  if ! has_cron; then install_cron || return 1; fi
}

write_export_helper() {
  mkdir -p "$BACKUP_DIR"
  cat > "$EXPORT_HELPER" <<EOF
#!/bin/bash
set -e
CONFIG_DIR="/etc/gost"
BACKUP_DIR="/etc/gost/backups"
mkdir -p "\$BACKUP_DIR"
ts="\$(date +%F_%H%M%S)"
OUT="\$BACKUP_DIR/gost-backup.\${ts}.tar.gz"
# 备份核心数据
FILES="rules.conf config.yaml"
if [ -f "\$CONFIG_DIR/panel_data.json" ]; then
    FILES="\$FILES panel_data.json"
fi
tar -czf "\$OUT" -C "\$CONFIG_DIR" \$FILES 2>/dev/null
# 保留最近8份
ls -tp "\$BACKUP_DIR"/gost-backup.*.tar.gz 2>/dev/null | tail -n +8 | xargs -I {} rm -- "{}"
EOF
  chmod +x "$EXPORT_HELPER"
}

schedule_status() {
  if [ -f "$CRON_FILE" ]; then
      echo -e "${GREEN}定时备份：已启用${RESET}"
      cat "$CRON_FILE"
  else
      echo -e "${YELLOW}定时备份：未启用${RESET}"
  fi
}

setup_export_cron() {
  ensure_cron_ready || return
  write_export_helper
  
  echo "1. 每天"
  echo "2. 每周"
  read -p "选择频率 [1-2]: " T
  local D="*"
  if [ "$T" == "2" ]; then
      read -p "周几 (0-6, 0是周日): " D
  fi
  read -p "小时 (0-23): " HH
  read -p "分钟 (0-59): " MM
  
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
$MM $HH * * $D root $EXPORT_HELPER >/dev/null 2>&1
EOF
  echo -e "${GREEN}任务已添加。${RESET}"
}

remove_export_cron() {
  rm -f "$CRON_FILE" "$EXPORT_HELPER"
  echo -e "${GREEN}定时任务已移除。${RESET}"
}

manage_schedule_backup() {
  echo "--------------------"
  echo "1. 查看状态"
  echo "2. 添加任务"
  echo "3. 删除任务"
  echo "0. 返回"
  read -p "选择: " X
  case "$X" in
    1) schedule_status ;;
    2) setup_export_cron ;;
    3) remove_export_cron ;;
    *) return ;;
  esac
}

install_ftp(){
    clear
    echo -e "${GREEN}📂 FTP/SFTP 备份工具...${RESET}"
    echo -e "${YELLOW}默认备份文件：${DEFAULT_EXPORT_FILE}${RESET}"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
}

# ================= 面板管理 =================

update_panel_port() {
    if [ ! -f "$PANEL_SERVICE_FILE" ]; then
        echo -e "${RED}面板未安装。${RESET}"
        return
    fi
    echo -e "${GREEN}修改 Gost 面板端口${RESET}"
    read -p "新端口 (1-65535): " PORT
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "无效数字"; return; fi
    
    # 替换服务文件中的端口变量
    sed -i "s|Environment=\"PANEL_PORT=.*\"|Environment=\"PANEL_PORT=$PORT\"|g" "$PANEL_SERVICE_FILE"
    systemctl daemon-reload
    if systemctl restart gost-panel; then
        local IP
        IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
        echo -e "${GREEN}修改成功！访问地址: http://${IP}:${PORT}${RESET}"
    else
        echo -e "${RED}重启失败。${RESET}"
    fi
}

manage_panel() {
    echo "--------------------"
    echo "Gost 面板管理："
    echo "1. 安装面板"
    echo "2. 卸载面板"
    echo "3. 修改面板端口" 
    echo "0. 返回"
    read -p "请选择 [0-2]: " PAN_OPT
    case "$PAN_OPT" in
        1)
            echo "--------------------"
            echo "选择安装方式："
            echo "1. 快速安装部署"
            echo "2. 自编译部署"
            echo "0. 返回"
            read -p "请选择 [0-2]: " INST_OPT
            case "$INST_OPT" in
                1) bash <(curl -fsSL https://raw.githubusercontent.com/hiapb/nuro-gost/main/quickpan.sh) ;; 
                2) bash <(curl -fsSL https://raw.githubusercontent.com/hiapb/nuro-gost/main/gost-pan.sh) ;;
                *) return ;;
            esac
            ;;
        2)
           bash <(curl -fsSL https://raw.githubusercontent.com/hiapb/nuro-gost/main/unpan.sh)
            ;;
        3) update_panel_port ;;
        *) return ;;
    esac
}

# ================= 主菜单 =================

main_menu() {
  check_root
  while true; do
    echo -e "${GREEN}===== Gost V3 转发管理脚本 =====${RESET}"
    get_status_line
    echo "----------------------------------"
    echo "1.  安装 Gost"
    echo "2.  卸载 Gost"
    echo "3.  重启 Gost"
    echo "--------------------"
    echo "4.  添加转发规则"
    echo "5.  删除单条规则"
    echo "6.  删除全部规则"
    echo "7.  查看当前规则"
    echo "8.  修改某条规则"
    echo "9.  启动/暂停某条规则"
    echo "--------------------"
    echo "10. 查看日志"
    echo "11. 查看配置"
    echo "12. 一键导出规则"
    echo "13. 一键导入规则"
    echo "14. 定时备份管理"
    echo "15. 自动备份到 FTP/SFTP"
    echo "16. Gost 面板管理" 
    echo "0.  退出"
    read -p "请选择 [0-16]: " OPT
    case "$OPT" in
      1) install_gost ;;
      2) uninstall_gost ;;
      0) exit 0 ;;
      3) require_installed && restart_gost_verbose ;;
      4) require_installed && add_rule ;;
      5) require_installed && delete_rule ;;
      6) require_installed && clear_rules ;;
      7) require_installed && print_rules_pretty ;;
      8) require_installed && edit_rule ;;
      9) require_installed && toggle_rule ;;
      10) require_installed && journalctl -u gost --no-pager --since "1 hour ago" ;;
      11) require_installed && cat "$CONFIG_FILE" ;;
      12) require_installed && export_rules ;;
      13) require_installed && import_rules ;;
      14) require_installed && manage_schedule_backup ;;
      15) require_installed && install_ftp ;;
      16) manage_panel ;;  
      *) echo -e "${RED}无效选项。${RESET}" ;;
    esac
    echo -e "${YELLOW}按回车继续...${RESET}"
    read
  done
}

# 开始运行
main_menu

#!/bin/bash

# =================配置区域=================
PANEL_PORT="4795"
DEFAULT_USER="admin"
# 默认密码 (脚本会自动将其转换为 SHA256 哈希存储)
DEFAULT_PASS="123456" 
API_PORT="9090"

# 核心路径配置
GOST_BIN="/usr/local/bin/gost"
CONFIG_FILE="/etc/gost/config.json" 
SERVICE_FILE="/etc/systemd/system/gost.service"
TMP_DIR="/tmp/gost_install"

# 面板路径
WORK_DIR="/opt/gost_panel"
PANEL_BIN="/usr/local/bin/gost-panel"
PANEL_DATA="/etc/gost/panel_data.json"
PANEL_SERVICE="/etc/systemd/system/gost-panel.service"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
# =========================================

# 自定义链名称
CHAIN_IN="GOST_IN"
CHAIN_OUT="GOST_OUT"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo -e "${RED}错误: 缺少必要命令 '$1'${RESET}"
        exit 1
    fi
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    echo -n " "
    while [ -d /proc/$pid ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_step() {
    echo -e -n "${CYAN}>>> $1...${RESET}"
    eval "$2" >/dev/null 2>&1 &
    spinner $!
    echo -e "${GREEN} [完成]${RESET}"
}

prepare_env() {
    echo -e "${CYAN}>>> 正在准备环境...${RESET}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar git build-essential pkg-config libssl-dev iptables conntrack >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum groupinstall -y 'Development Tools' >/dev/null 2>&1
        yum install -y curl wget tar openssl-devel libgcc glibc-static iptables-services conntrack-tools >/dev/null 2>&1
    fi

    if ! command -v cargo &> /dev/null; then
        echo -e -n "${CYAN}>>> 正在安装 Rust 编译器...${RESET}"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1 &
        spinner $!
        source "$HOME/.cargo/env"
        echo -e "${GREEN} [完成]${RESET}"
    else
        echo -e "${GREEN}>>> Rust 已安装${RESET}"
    fi

    echo -e "${CYAN}>>> 正在进行内核能力实弹测试...${RESET}"
    local test_chain="GOST_CHECK_TMP"
    iptables -N $test_chain 2>/dev/null
    
    # 实弹探测：尝试插入复杂 Conntrack 规则
    if iptables -t filter -A $test_chain -p tcp -m conntrack --ctstate ESTABLISHED --ctdir REPLY --ctreplsrcport 65535 -j RETURN 2>/dev/null; then
        echo -e "${GREEN}>>> 核心模块检查通过 (conntrack/ctreplsrcport/ctdir)${RESET}"
        iptables -F $test_chain
        iptables -X $test_chain
    else
        echo -e "${RED}严重警告: 您的系统内核不支持必要的 conntrack 参数！${RESET}"
        echo -e "${YELLOW}可能原因: 内核版本过低或缺少内核模块 (nf_conntrack)。${RESET}"
        echo -e "${YELLOW}后果: 流量统计功能将无法工作 (OUT方向将为0)。${RESET}"
        iptables -X $test_chain 2>/dev/null
        sleep 3
    fi
}

install_gost() {
    need_cmd curl
    need_cmd tar
    need_cmd systemctl

    if [ -f "$GOST_BIN" ]; then
        local v=$($GOST_BIN -V 2>&1 | awk '{print $2}')
        echo -e "${GREEN}>>> 检测到 Gost 已安装 ($v)${RESET}"
    else
        echo -e "${CYAN}>>> 正在安装 Gost V3...${RESET}"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GOST_ARCH="linux_amd64" ;;
            aarch64) GOST_ARCH="linux_arm64" ;;
            *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; exit 1 ;;
        esac
        
        TAG=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -z "$TAG" ] && TAG="v3.0.0"
        
        URL="https://github.com/go-gost/gost/releases/download/${TAG}/gost_${TAG#v}_${GOST_ARCH}.tar.gz"
        
        mkdir -p "$TMP_DIR"
        if ! curl -L -o "$TMP_DIR/gost.tar.gz" "$URL"; then
            echo -e "${RED}下载 Gost 失败${RESET}"
            exit 1
        fi

        tar -xzf "$TMP_DIR/gost.tar.gz" -C "$TMP_DIR"
        mv "$TMP_DIR/gost" "$GOST_BIN"
        chmod +x "$GOST_BIN"
        rm -rf "$TMP_DIR"
    fi

    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"services":[], "chains":[]}' > "$CONFIG_FILE"
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gost Proxy Service (API Mode)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$GOST_BIN -L api://127.0.0.1:$API_PORT -C $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost >/dev/null 2>&1
    systemctl restart gost
    echo -e "${GREEN} [完成] (API端口: $API_PORT)${RESET}"
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本！${RESET}"
    exit 1
fi

clear
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}    Gost 面板 v13.0 (钛金交付版)        ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

prepare_env
install_gost

mkdir -p "$(dirname "$PANEL_DATA")"
run_step "生成面板源代码" "
rm -rf '$WORK_DIR'
mkdir -p '$WORK_DIR/src'
"
cd "$WORK_DIR"

cat > Cargo.toml <<EOF
[package]
name = "gost-panel"
version = "13.0.0"
edition = "2021"

[dependencies]
axum = { version = "0.7", features = ["macros"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tower-cookies = "0.10"
anyhow = "1.0"
uuid = { version = "1", features = ["v4"] }
chrono = { version = "0.4", features = ["serde"] }
sha2 = "0.10"
hex = "0.4"
EOF

# 写入 Rust 源码
cat > src/main.rs << 'EOF'
use axum::{
    extract::{State, Path},
    http::StatusCode,
    response::{Html, IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router, Form,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{fs, process::Command, sync::{Arc, Mutex}, time::Duration, collections::HashMap, cmp, collections::HashSet};
use tower_cookies::{Cookie, Cookies, CookieManagerLayer, cookie::SameSite};
use chrono::prelude::*;
use sha2::{Sha256, Digest};

const GOST_CONFIG: &str = "/etc/gost/config.json";
const DATA_FILE: &str = "/etc/gost/panel_data.json";
const GOST_API_URL: &str = "__GOST_API_URL_BINDING__"; 
const DEFAULT_PASS_RAW: &str = "__DEFAULT_PASS_BINDING__";

const CHAIN_IN: &str = "GOST_IN";
const CHAIN_OUT: &str = "GOST_OUT";

fn hash_pwd(p: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(p.as_bytes());
    hex::encode(hasher.finalize())
}

fn run_ipt(args: &[&str]) -> bool {
    match Command::new("iptables").args(args).status() {
        Ok(s) => s.success(),
        Err(e) => {
            eprintln!("Iptables Error: {} {:?}", e, args);
            false
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct Rule {
    id: String,
    name: String,
    listen: String,
    remote: String,
    enabled: bool,
    #[serde(default)]
    expire_date: u64,
    #[serde(default)]
    traffic_limit: u64,
    #[serde(default)]
    traffic_used: u64,
    #[serde(default)]
    status_msg: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AdminConfig {
    username: String,
    pass_hash: String, 
    #[serde(default)] 
    session_token: String,
    #[serde(default = "default_bg_pc")]
    bg_pc: String,
    #[serde(default = "default_bg_mobile")]
    bg_mobile: String,
}
fn default_bg_pc() -> String { "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".to_string() }
fn default_bg_mobile() -> String { "https://img.inim.im/file/1764296937373_bg_m_2.png".to_string() }

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AppData {
    admin: AdminConfig,
    rules: Vec<Rule>,
}

#[derive(Deserialize)] 
struct UpdateRuleReq { name: String, listen: String, remote: String, expire_date: u64, traffic_limit: u64 }
#[derive(Deserialize)] 
struct AccountUpdate { username: String, password: String }
#[derive(Deserialize)] 
struct BgUpdate { bg_pc: String, bg_mobile: String }

#[derive(Debug, Clone, Copy)]
struct TrafficStats {
    in_bytes: u64,
    out_bytes: u64,
}

struct AppState {
    data: Mutex<AppData>,
    last_traffic_map: Mutex<HashMap<String, TrafficStats>>,
}

#[tokio::main]
async fn main() {
    init_firewall_chains();

    let initial_data = load_or_init_data();
    let state = Arc::new(AppState {
        data: Mutex::new(initial_data),
        last_traffic_map: Mutex::new(HashMap::new()),
    });

    {
        let data = state.data.lock().unwrap();
        flush_firewall_chains(); 
        for rule in &data.rules {
            if !apply_iptables_rule(rule) {
                eprintln!("启动警告: 规则 {} 防火墙配置失败", rule.name);
            }
        }
        if let Err(e) = push_config_to_gost(&data) {
            eprintln!("启动警告: Gost API 同步失败: {}", e);
        }
    }

    let monitor_state = state.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;
            update_traffic_and_check(&monitor_state);
        }
    });

    let app = Router::new()
        .route("/", get(index_page))
        .route("/login", get(login_page).post(login_action))
        .route("/api/rules", get(get_rules).post(add_rule))
        .route("/api/rules/batch", post(batch_add_rules))
        .route("/api/rules/all", delete(delete_all_rules)) 
        .route("/api/rules/:id", put(update_rule).delete(delete_rule))
        .route("/api/rules/:id/toggle", post(toggle_rule))
        .route("/api/rules/:id/reset_traffic", post(reset_traffic))
        .route("/api/admin/account", post(update_account))
        .route("/api/admin/bg", post(update_bg))
        .route("/api/backup", get(download_backup))
        .route("/api/restore", post(restore_backup))
        .route("/logout", post(logout_action))
        .layer(CookieManagerLayer::new())
        .with_state(state);

    let port = std::env::var("PANEL_PORT").unwrap_or_else(|_| "4795".to_string());
    println!("Server running on port {}", port);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn init_firewall_chains() {
    let _ = Command::new("iptables").args(["-N", CHAIN_IN]).status();
    let _ = Command::new("iptables").args(["-N", CHAIN_OUT]).status();
    
    // 插入顺序 2 (不抢占第一条)
    let check_in = Command::new("iptables").args(["-C", "INPUT", "-j", CHAIN_IN]).status();
    if !check_in.map(|s| s.success()).unwrap_or(false) {
        let _ = Command::new("iptables").args(["-I", "INPUT", "2", "-j", CHAIN_IN]).status();
    }
    
    let check_out = Command::new("iptables").args(["-C", "OUTPUT", "-j", CHAIN_OUT]).status();
    if !check_out.map(|s| s.success()).unwrap_or(false) {
        let _ = Command::new("iptables").args(["-I", "OUTPUT", "2", "-j", CHAIN_OUT]).status();
    }
    
    let check_fwd = Command::new("iptables").args(["-C", "FORWARD", "-j", CHAIN_OUT]).status();
    if !check_fwd.map(|s| s.success()).unwrap_or(false) {
        let _ = Command::new("iptables").args(["-I", "FORWARD", "2", "-j", CHAIN_OUT]).status();
    }
}

fn flush_firewall_chains() {
    let _ = Command::new("iptables").args(["-F", CHAIN_IN]).status();
    let _ = Command::new("iptables").args(["-F", CHAIN_OUT]).status();
}

fn get_port(listen: &str) -> String {
    listen.split(':').last().unwrap_or("").trim().to_string()
}

// 动作: RETURN
fn apply_iptables_rule(rule: &Rule) -> bool {
    let port = get_port(&rule.listen);
    if port.is_empty() { return false; }
    remove_iptables_rule(rule);

    let mut success = true;

    if rule.enabled {
        for proto in ["tcp", "udp"] {
            if !run_ipt(&["-A", CHAIN_IN, "-p", proto, "--dport", &port, "-j", "RETURN"]) { success = false; }
            if !run_ipt(&[
                    "-A", CHAIN_OUT, 
                    "-p", proto, 
                    "-m", "conntrack", "--ctstate", "ESTABLISHED",
                    "--ctdir", "REPLY",
                    "--ctreplsrcport", &port, 
                    "-j", "RETURN"
                ]) { success = false; }
        }
    } else {
        if !run_ipt(&["-A", CHAIN_IN, "-p", "tcp", "--dport", &port, "-j", "REJECT", "--reject-with", "tcp-reset"]) { success = false; }
        if !run_ipt(&["-A", CHAIN_IN, "-p", "udp", "--dport", &port, "-j", "REJECT", "--reject-with", "icmp-port-unreachable"]) { success = false; }
    }
    success
}

fn remove_iptables_rule(rule: &Rule) {
    let port = get_port(&rule.listen);
    if port.is_empty() { return; }
    
    for proto in ["tcp", "udp"] {
        loop {
            if !run_ipt(&["-D", CHAIN_IN, "-p", proto, "--dport", &port, "-j", "RETURN"]) { break; }
        }
        loop {
            if !run_ipt(&[
                    "-D", CHAIN_OUT, 
                    "-p", proto, 
                    "-m", "conntrack", "--ctstate", "ESTABLISHED",
                    "--ctdir", "REPLY",
                    "--ctreplsrcport", &port, 
                    "-j", "RETURN"
                ]) { break; }
        }
        if proto == "tcp" {
            loop { if !run_ipt(&["-D", CHAIN_IN, "-p", "tcp", "--dport", &port, "-j", "REJECT", "--reject-with", "tcp-reset"]) { break; } }
        } else {
             loop { if !run_ipt(&["-D", CHAIN_IN, "-p", "udp", "--dport", &port, "-j", "REJECT", "--reject-with", "icmp-port-unreachable"]) { break; } }
        }
    }
}

fn fetch_iptables_counters() -> HashMap<String, TrafficStats> {
    let mut map: HashMap<String, TrafficStats> = HashMap::new();
    let output = match Command::new("iptables-save").arg("-t").arg("filter").arg("-c").output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
        Err(_) => return map,
    };
    for line in output.lines() {
        if !line.contains(CHAIN_IN) && !line.contains(CHAIN_OUT) { continue; }
        if !line.contains("-j RETURN") { continue; }
        
        let is_in = line.contains(&format!("-A {}", CHAIN_IN));
        
        if !line.starts_with('[') { continue; }
        let end_bracket = match line.find(']') { Some(i) => i, None => continue };
        let parts: Vec<&str> = line[1..end_bracket].split(':').collect();
        if parts.len() != 2 { continue; }
        let bytes: u64 = parts[1].parse().unwrap_or(0);
        
        let port_flag = if is_in { "--dport" } else { "--ctreplsrcport" };
        
        if let Some(pos) = line.find(port_flag) {
            let rest = &line[pos + port_flag.len()..];
            let port = rest.split_whitespace().next().unwrap_or("").trim_matches('\'').trim_matches('"');
            if !port.is_empty() {
                let entry = map.entry(port.to_string()).or_insert(TrafficStats { in_bytes: 0, out_bytes: 0 });
                if is_in { entry.in_bytes += bytes; } else { entry.out_bytes += bytes; }
            }
        }
    }
    map
}

fn update_traffic_and_check(state: &Arc<AppState>) {
    let current_counters = fetch_iptables_counters();
    let mut last_map = state.last_traffic_map.lock().unwrap();
    let mut data = state.data.lock().unwrap();
    let now = Utc::now().timestamp_millis() as u64;
    
    let mut data_changed = false;
    let mut config_changed = false;

    for rule in data.rules.iter_mut() {
        if !rule.enabled { continue; }
        let port = get_port(&rule.listen);
        if port.is_empty() { continue; }

        let curr = *current_counters.get(&port).unwrap_or(&TrafficStats{in_bytes:0, out_bytes:0});
        let last = *last_map.get(&port).unwrap_or(&TrafficStats{in_bytes:0, out_bytes:0});

        let delta_in = if curr.in_bytes >= last.in_bytes { curr.in_bytes - last.in_bytes } else { curr.in_bytes };
        let delta_out = if curr.out_bytes >= last.out_bytes { curr.out_bytes - last.out_bytes } else { curr.out_bytes };
        
        let usage_inc = cmp::max(delta_in, delta_out);

        if usage_inc > 0 {
            rule.traffic_used += usage_inc;
            data_changed = true; 
            last_map.insert(port.clone(), curr);
        } else {
            last_map.insert(port.clone(), curr);
        }

        if (rule.expire_date > 0 && now > rule.expire_date) || (rule.traffic_limit > 0 && rule.traffic_used >= rule.traffic_limit) {
            rule.enabled = false;
            rule.status_msg = if now > rule.expire_date { "已过期".to_string() } else { "流量耗尽".to_string() };
            data_changed = true;
            config_changed = true;
            apply_iptables_rule(rule);
        }
    }

    if data_changed { save_json(&data); }
    if config_changed { 
        let _ = push_config_to_gost(&data); 
    }
}

fn load_or_init_data() -> AppData {
    if let Ok(content) = fs::read_to_string(DATA_FILE) {
        if let Ok(mut data) = serde_json::from_str::<AppData>(&content) {
            return data;
        }
    }
    let admin = AdminConfig {
        username: std::env::var("PANEL_USER").unwrap_or("admin".to_string()),
        pass_hash: hash_pwd(&DEFAULT_PASS_RAW),
        session_token: String::new(),
        bg_pc: default_bg_pc(),
        bg_mobile: default_bg_mobile(),
    };
    let data = AppData { admin, rules: Vec::new() };
    save_json(&data);
    data
}

fn save_json(data: &AppData) {
    let json_str = serde_json::to_string_pretty(data).unwrap();
    let _ = fs::write(DATA_FILE, json_str);
}

fn push_config_to_gost(data: &AppData) -> Result<(), String> {
    let mut services = vec![];
    let mut chains = vec![];

    for rule in &data.rules {
        if !rule.enabled { continue; }
        let chain_name = format!("chain-{}", rule.id);
        chains.push(json!({ "name": chain_name, "hops": [ { "nodes": [ { "addr": rule.remote } ] } ] }));
        services.push(json!({ "name": format!("service-{}-tcp", rule.id), "addr": rule.listen, "handler": { "type": "tcp", "chain": chain_name }, "listener": { "type": "tcp" } }));
        services.push(json!({ "name": format!("service-{}-udp", rule.id), "addr": rule.listen, "handler": { "type": "udp", "chain": chain_name }, "listener": { "type": "udp" } }));
    }

    let config_json = json!({ "services": services, "chains": chains });

    if let Ok(json_str) = serde_json::to_string_pretty(&config_json) {
        let _ = fs::write(GOST_CONFIG, json_str);
    }

    let output = Command::new("curl")
        .args(["-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "PUT", GOST_API_URL, "-H", "Content-Type: application/json", "-d", &config_json.to_string()])
        .output()
        .map_err(|e| e.to_string())?;

    if !output.status.success() {
        return Err("Curl execution failed".to_string());
    }
    
    let code_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if code_str.starts_with("2") {
        Ok(())
    } else {
        Err(format!("Gost API returned: {}", code_str))
    }
}

fn check_auth(cookies: &Cookies, state: &AppData) -> bool {
    if let Some(cookie) = cookies.get("auth_session") {
        return !state.admin.session_token.is_empty() && cookie.value() == state.admin.session_token;
    }
    false
}

async fn index_page(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return axum::response::Redirect::to("/login").into_response(); }
    let html = DASHBOARD_HTML.replace("{{USER}}", &data.admin.username).replace("{{BG_PC}}", &data.admin.bg_pc).replace("{{BG_MOBILE}}", &data.admin.bg_mobile);
    Html(html).into_response()
}
async fn login_page(State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    let html = LOGIN_HTML.replace("{{BG_PC}}", &data.admin.bg_pc).replace("{{BG_MOBILE}}", &data.admin.bg_mobile);
    Html(html).into_response()
}
#[derive(Deserialize)] struct LoginParams { username: String, password: String }
async fn login_action(cookies: Cookies, State(state): State<Arc<AppState>>, Form(form): Form<LoginParams>) -> Response {
    let mut data = state.data.lock().unwrap();
    if form.username == data.admin.username && hash_pwd(&form.password) == data.admin.pass_hash {
        let token = uuid::Uuid::new_v4().to_string();
        data.admin.session_token = token.clone();
        save_json(&data);
        
        let mut cookie = Cookie::new("auth_session", token);
        cookie.set_path("/"); 
        cookie.set_http_only(true); 
        cookie.set_same_site(SameSite::Strict); 
        cookie.set_max_age(tower_cookies::cookie::time::Duration::days(7));
        cookies.add(cookie);
        axum::response::Redirect::to("/").into_response()
    } else { StatusCode::UNAUTHORIZED.into_response() }
}
async fn logout_action(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let mut data = state.data.lock().unwrap();
    data.admin.session_token = String::new();
    save_json(&data);
    
    let mut cookie = Cookie::new("auth_session", ""); 
    cookie.set_path("/"); 
    // 修复4: 显式立即过期，兼容旧浏览器
    cookie.set_max_age(tower_cookies::cookie::time::Duration::seconds(0));
    cookies.remove(cookie); 
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn get_rules(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    Json(json!({ "rules": data.rules })).into_response()
}

async fn add_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<UpdateRuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if req.name.trim().is_empty() || req.listen.trim().is_empty() || req.remote.trim().is_empty() { return Json(serde_json::json!({"status":"error", "message": "必填项为空"})).into_response(); }
    let new_port = get_port(&req.listen);
    if new_port.is_empty() { return Json(serde_json::json!({"status":"error", "message": "端口格式错误"})).into_response(); }
    if data.rules.iter().any(|r| get_port(&r.listen) == new_port) { return Json(serde_json::json!({"status":"error", "message": "端口已被占用"})).into_response(); }
    
    let mut rule = Rule { id: uuid::Uuid::new_v4().to_string(), name: req.name, listen: req.listen, remote: req.remote, enabled: true, expire_date: req.expire_date, traffic_limit: req.traffic_limit, traffic_used: 0, status_msg: String::new() };
    
    if !apply_iptables_rule(&rule) {
        rule.status_msg = "防火墙配置失败".to_string();
    }
    
    data.rules.push(rule);
    save_json(&data);
    
    if let Err(e) = push_config_to_gost(&data) {
        return Json(serde_json::json!({"status":"error", "message": format!("配置保存成功，但 API 失败: {}", e)})).into_response();
    }
    Json(serde_json::json!({"status":"ok"})).into_response()
}

async fn batch_add_rules(cookies: Cookies, State(state): State<Arc<AppState>>, Json(reqs): Json<Vec<UpdateRuleReq>>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    let mut count = 0;
    for req in reqs {
        let new_port = get_port(&req.listen);
        if new_port.is_empty() || data.rules.iter().any(|r| get_port(&r.listen) == new_port) { continue; }
        let mut rule = Rule { id: uuid::Uuid::new_v4().to_string(), name: req.name, listen: req.listen, remote: req.remote, enabled: true, expire_date: 0, traffic_limit: 0, traffic_used: 0, status_msg: String::new() };
        
        if !apply_iptables_rule(&rule) {
            rule.status_msg = "防火墙配置失败".to_string();
        }
        
        data.rules.push(rule);
        count+=1;
    }
    if count > 0 { 
        save_json(&data); 
        if let Err(e) = push_config_to_gost(&data) {
             return Json(serde_json::json!({"status":"error", "message": format!("批量添加成功，但 API 失败: {}", e)})).into_response();
        }
    } 
    Json(serde_json::json!({"status":"ok", "message":"操作完成"})).into_response()
}

async fn delete_all_rules(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    flush_firewall_chains();
    data.rules.clear();
    save_json(&data);
    let _ = push_config_to_gost(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

async fn download_backup(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    Response::builder().header("Content-Type","application/json").header("Content-Disposition","attachment; filename=\"backup.json\"").body(axum::body::Body::from(serde_json::to_string_pretty(&data.rules).unwrap())).unwrap()
}
async fn restore_backup(cookies: Cookies, State(state): State<Arc<AppState>>, Json(rules): Json<Vec<Rule>>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    // 修复2: 导入数据预检与熔断
    let mut ports = HashSet::new();
    for r in &rules {
        let p = get_port(&r.listen);
        if p.is_empty() { return Json(serde_json::json!({"status":"error", "message": "备份包含无效端口"})).into_response(); }
        if ports.contains(&p) { return Json(serde_json::json!({"status":"error", "message": "备份包含重复端口"})).into_response(); }
        ports.insert(p);
    }

    flush_firewall_chains();
    data.rules = rules;
    for r in &mut data.rules { 
        if !apply_iptables_rule(r) {
            r.status_msg = "防火墙配置失败".to_string();
        }
    }
    save_json(&data);
    let _ = push_config_to_gost(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn toggle_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(r) = data.rules.iter_mut().find(|x| x.id == id) {
        let old_enabled = r.enabled;
        r.enabled = !r.enabled;
        
        if r.enabled { r.status_msg = String::new(); }
        
        if !apply_iptables_rule(r) {
            // 回滚内存
            r.enabled = old_enabled;
            // 修复1: 强制回滚防火墙现场
            if apply_iptables_rule(r) {
                r.status_msg = "配置失败，已自动回滚旧状态".to_string();
            } else {
                r.status_msg = "致命错误：配置失败且回滚失败，请人工介入".to_string();
            }
        }
        
        save_json(&data);
        if let Err(e) = push_config_to_gost(&data) { return Json(serde_json::json!({"status":"error", "message": e})).into_response(); }
        Json(serde_json::json!({"status":"ok"})).into_response()
    } else { Json(serde_json::json!({"status":"error"})).into_response() }
}

async fn reset_traffic(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    let mut last_map = state.last_traffic_map.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(r) = data.rules.iter_mut().find(|x| x.id == id) {
        let port = get_port(&r.listen);
        r.traffic_used = 0;
        r.status_msg = String::new();
        
        apply_iptables_rule(r); 
        if !port.is_empty() { last_map.remove(&port); } 
        
        save_json(&data);
    }
    Json(serde_json::json!({"status":"ok"})).into_response()
}

async fn delete_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(pos) = data.rules.iter().position(|r| r.id == id) {
        remove_iptables_rule(&data.rules[pos]);
        data.rules.remove(pos);
        save_json(&data);
        let _ = push_config_to_gost(&data);
        Json(serde_json::json!({"status":"ok"})).into_response()
    } else { Json(serde_json::json!({"status":"ok"})).into_response() }
}

async fn update_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<UpdateRuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    let new_port = get_port(&req.listen);
    if data.rules.iter().any(|r| r.id != id && get_port(&r.listen) == new_port) { return Json(serde_json::json!({"status":"error", "message":"端口占用"})).into_response(); }
    
    if let Some(idx) = data.rules.iter().position(|r| r.id == id) {
        // 修复1: 编辑原子化回滚
        let old_rule = data.rules[idx].clone(); // 快照
        
        {
            let r = &mut data.rules[idx];
            r.name = req.name; r.listen = req.listen; r.remote = req.remote; r.expire_date = req.expire_date; r.traffic_limit = req.traffic_limit;
            if r.enabled && r.status_msg == "流量耗尽" && (req.traffic_limit == 0 || req.traffic_limit > r.traffic_used) { r.status_msg = String::new(); }
        }
        
        if !apply_iptables_rule(&data.rules[idx]) {
            // 失败，回滚到快照
            data.rules[idx] = old_rule;
            // 强制恢复现场
            if apply_iptables_rule(&data.rules[idx]) {
                data.rules[idx].status_msg = "更新失败，已自动回滚".to_string();
            } else {
                data.rules[idx].status_msg = "致命错误：更新失败且回滚失败".to_string();
            }
        }
        
        save_json(&data);
        if let Err(e) = push_config_to_gost(&data) { return Json(serde_json::json!({"status":"error", "message": e})).into_response(); }
        Json(serde_json::json!({"status":"ok"})).into_response()
    } else { Json(serde_json::json!({"status":"error"})).into_response() }
}
async fn update_account(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<AccountUpdate>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.admin.username = req.username;
    if !req.password.is_empty() { data.admin.pass_hash = hash_pwd(&req.password); }
    data.admin.session_token = String::new();
    save_json(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn update_bg(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<BgUpdate>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.admin.bg_pc = req.bg_pc; data.admin.bg_mobile = req.bg_mobile; save_json(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

const LOGIN_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><title>Gost Login</title><style>*{margin:0;padding:0;box-sizing:border-box}body{height:100vh;width:100vw;overflow:hidden;display:flex;justify-content:center;align-items:center;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:url('{{BG_PC}}') no-repeat center center/cover;color:#374151}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.overlay{position:absolute;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.05)}.box{position:relative;z-index:2;background:rgba(255,255,255,0.3);backdrop-filter:blur(25px);-webkit-backdrop-filter:blur(25px);padding:2.5rem;border-radius:24px;border:1px solid rgba(255,255,255,0.4);box-shadow:0 8px 32px rgba(0,0,0,0.05);width:90%;max-width:380px;text-align:center}h2{margin-bottom:2rem;color:#374151;font-weight:600;letter-spacing:1px}input{width:100%;padding:14px;margin-bottom:1.2rem;border:1px solid rgba(255,255,255,0.5);border-radius:12px;outline:none;background:rgba(255,255,255,0.5);transition:0.3s;color:#374151}input:focus{background:rgba(255,255,255,0.9);border-color:#3b82f6}button{width:100%;padding:14px;background:rgba(59,130,246,0.85);color:white;border:none;border-radius:12px;cursor:pointer;font-weight:600;font-size:1rem;transition:0.3s;backdrop-filter:blur(5px)}button:hover{background:#2563eb;transform:translateY(-1px)}</style></head><body><div class="overlay"></div><div class="box"><h2>Gost Panel</h2><form onsubmit="doLogin(event)"><input type="text" id="u" placeholder="Username" required><input type="password" id="p" placeholder="Password" required><button type="submit" id="btn">登 录</button></form></div><script>async function doLogin(e){e.preventDefault();const b=document.getElementById('btn');b.innerText='登录中...';b.disabled=true;const res=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${encodeURIComponent(document.getElementById('u').value)}&password=${encodeURIComponent(document.getElementById('p').value)}`});if(res.redirected){location.href=res.url}else if(res.ok){location.href='/'}else{alert('用户名或密码错误');b.innerText='登 录';b.disabled=false}}</script></body></html>
"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"><title>Gost Panel</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>:root{--primary:#3b82f6;--danger:#f87171;--success:#34d399;--text-main:#374151}::-webkit-scrollbar{width:5px;height:5px}::-webkit-scrollbar-thumb{background:rgba(0,0,0,0.1);border-radius:10px}*{box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;padding:0;height:100vh;height:100dvh;overflow:hidden;background:url('{{BG_PC}}') no-repeat center center/cover;display:flex;flex-direction:column;color:var(--text-main)}@media(max-width:768px){body{background-image:url('{{BG_MOBILE}}')}}.navbar{flex:0 0 auto;background:rgba(255,255,255,0.3);backdrop-filter:blur(25px);-webkit-backdrop-filter:blur(25px);border-bottom:1px solid rgba(255,255,255,0.3);padding:0.8rem 2rem;display:flex;justify-content:space-between;align-items:center;z-index:10}.brand{font-weight:700;font-size:1.1rem;color:var(--text-main);display:flex;align-items:center;gap:10px}.container{flex:1;display:flex;flex-direction:column;max-width:1100px;margin:1.5rem auto;width:95%;overflow:hidden}.card-fixed{background:rgba(255,255,255,0.3);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,0.4);border-radius:18px;padding:1.2rem;margin-bottom:1.5rem;box-shadow:0 4px 15px rgba(0,0,0,0.03)}.card-scroll{flex:1;background:rgba(255,255,255,0.25);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,0.4);border-radius:18px;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 4px 15px rgba(0,0,0,0.03)}.table-wrapper{flex:1;overflow-y:auto;padding:0 1.5rem 1.5rem}table{width:100%;border-collapse:separate;border-spacing:0 10px}
thead th{position:sticky;top:0;background:rgba(255,255,255,0.4);backdrop-filter:blur(15px);z-index:5;padding:14px 12px;text-align:left;font-size:0.85rem;text-transform:uppercase;letter-spacing:1px;color:#6b7280;border-top:1px solid rgba(255,255,255,0.3);border-bottom:1px solid rgba(255,255,255,0.3)}
thead th:first-child{border-top-left-radius:15px;border-bottom-left-radius:15px;border-left:1px solid rgba(255,255,255,0.3)}
thead th:last-child{border-top-right-radius:15px;border-bottom-right-radius:15px;border-right:1px solid rgba(255,255,255,0.3)}
tbody tr{background:transparent;transition:0.3s}
@media(min-width:768px){tbody tr:hover td{background:rgba(255,255,255,0.7);transform:translateY(-1px);box-shadow:0 4px 10px rgba(0,0,0,0.02)}}
td{background:rgba(255,255,255,0.4);padding:14px 12px;font-size:0.92rem;font-weight:500;color:var(--text-main);border-top:1px solid rgba(255,255,255,0.3);border-bottom:1px solid rgba(255,255,255,0.3)}
td:first-child{border-left:1px solid rgba(255,255,255,0.3);border-top-left-radius:15px;border-bottom-left-radius:15px}
td:last-child{border-right:1px solid rgba(255,255,255,0.3);border-top-right-radius:15px;border-bottom-right-radius:15px}
.btn{padding:8px 12px;border-radius:10px;border:none;cursor:pointer;color:white;transition:0.2s;display:inline-flex;align-items:center;justify-content:center;gap:6px;font-weight:500}.btn-primary{background:var(--primary);opacity:0.9}.btn-danger{background:var(--danger);opacity:0.9}.btn-gray{background:rgba(0,0,0,0.05);color:var(--text-main)}.grid-input{display:grid;grid-template-columns:1.5fr 1fr 2fr auto auto;gap:12px}
.tools-group{display:flex;gap:5px}input{padding:10px 14px;border:1px solid rgba(0,0,0,0.05);background:rgba(255,255,255,0.5);border-radius:10px;outline:none;transition:0.3s;color:var(--text-main);font-weight:500}input:focus{border-color:var(--primary);background:white}.status-dot{height:7px;width:7px;border-radius:50%;display:inline-block;margin-right:8px}.bg-green{background:var(--success);box-shadow:0 0 8px var(--success)}.bg-gray{background:#9ca3af}.bg-red{background:var(--danger)}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.1);z-index:100;justify-content:center;align-items:center;backdrop-filter:blur(8px)}.modal-box{background:rgba(255,255,255,0.9);width:90%;max-width:420px;padding:2rem;border-radius:20px;box-shadow:0 20px 40px rgba(0,0,0,0.1);animation:pop 0.3s ease}@keyframes pop{from{transform:scale(0.9);opacity:0}to{transform:scale(1);opacity:1}}.tab-header{display:flex;gap:20px;margin-bottom:20px;border-bottom:1px solid rgba(0,0,0,0.05)}.tab-btn{padding:10px 5px;cursor:pointer;font-size:0.9rem;color:#9ca3af}.tab-btn.active{color:var(--primary);border-bottom:2px solid var(--primary);font-weight:600}.tab-content{display:none}.tab-content.active{display:block}label{display:block;margin:12px 0 6px;font-size:0.85rem;color:#6b7280}
.info-row{display:flex;justify-content:space-between;margin-bottom:8px;font-size:0.9rem}.info-val{font-weight:600}
.progress-bar{width:100%;height:10px;background:rgba(0,0,0,0.1);border-radius:5px;overflow:hidden;margin-top:5px}.progress-fill{height:100%;background:var(--primary);width:0%}
.expire-warning{color:var(--danger);font-size:0.8rem;margin-top:2px}
@media(max-width:768px){.grid-input{grid-template-columns:1fr; gap:10px}.navbar{padding:0.8rem 1rem}.nav-text{display:none}thead{display:none}tbody tr{display:flex;flex-direction:column;border-radius:18px!important;margin-bottom:12px;padding:15px;border:1px solid rgba(255,255,255,0.3);background:rgba(255,255,255,0.4)}td{padding:6px 0;display:flex;justify-content:space-between;border-radius:0!important;align-items:center;border:none;background:transparent}td::before{content:attr(data-label);color:#9ca3af;font-size:0.85rem}td[data-label="操作"]{justify-content:flex-end;gap:10px;margin-top:8px;padding-top:10px;border-top:1px solid rgba(0,0,0,0.05)}td[data-label="操作"] .btn{flex:none;width:auto;padding:6px 14px;border-radius:8px;font-size:0.85rem}td[data-label="操作"] .btn-gray{background:transparent;border:1px solid rgba(0,0,0,0.15);color:#555}td[data-label="操作"] .btn-primary{background:var(--primary);color:white}td[data-label="操作"] .btn-danger{background:rgba(239,68,68,0.1);color:var(--danger);border:1px solid rgba(239,68,68,0.2)}.tools-group{width:100%;margin-top:5px}.tools-group .btn{flex:1;justify-content:center;padding:10px 0;font-size:0.85rem}}</style></head><body><div class="navbar"><div class="brand"><i class="fas fa-layer-group"></i> <span class="nav-text">Gost 转发面板</span></div><div class="nav-actions" style="display:flex;gap:15px"><button class="btn btn-gray" onclick="openSettings()"><i class="fas fa-sliders-h"></i> <span class="nav-text">面板设置</span></button><button class="btn btn-danger" onclick="doLogout()"><i class="fas fa-power-off"></i></button></div></div><div class="container"><div class="card card-fixed"><div class="grid-input"><input id="n" placeholder="备注名称"><input id="l" placeholder="监听端口 (如 10000)"><input id="r" placeholder="目标 (例 1.2.3.4:443)"><button class="btn btn-primary" onclick="openAddModal()"><i class="fas fa-plus"></i> 添加</button><div class="tools-group"><button class="btn btn-primary" onclick="openBatch()" style="background:#8b5cf6"><i class="fas fa-paste"></i> 批量</button><button class="btn btn-danger" onclick="delAll()" style="background:#ef4444"><i class="fas fa-trash"></i> 全删</button><button class="btn btn-primary" onclick="downloadBackup()" style="background:#059669"><i class="fas fa-download"></i> 导出</button><button class="btn btn-danger" onclick="openRestore()" style="background:#d97706"><i class="fas fa-upload"></i> 导入</button></div></div></div><div class="card card-scroll"><div style="padding:1.2rem 1.5rem;font-weight:700;font-size:1rem;opacity:0.8">转发规则管理</div><div class="table-wrapper"><table id="ruleTable"><thead><tr><th>状态</th><th>备注</th><th>监听</th><th>目标</th><th>流量 (In/Out)</th><th style="width:180px;text-align:right;padding-right:20px">操作</th></tr></thead><tbody id="list"></tbody></table><div id="emptyView" style="display:none;text-align:center;padding:50px;color:#9ca3af"><i class="fas fa-inbox" style="font-size:2rem;display:block;margin-bottom:10px"></i>暂无规则</div></div></div></div>
<div id="ruleModal" class="modal"><div class="modal-box"><h3 id="modalTitle">添加规则</h3><input type="hidden" id="edit_id"><label>备注</label><input id="mod_n"><label>监听端口</label><input id="mod_l"><label>目标地址</label><input id="mod_r"><label>到期时间 (留空不限制)</label><input type="datetime-local" id="mod_e"><label>流量限制 (留空或0不限制)</label><div style="display:flex;gap:10px"><input id="mod_t_val" type="number" placeholder="数值" style="flex:1"><select id="mod_t_unit" style="padding:10px;border-radius:10px;border:1px solid rgba(0,0,0,0.05);background:rgba(255,255,255,0.5)"><option value="MB">MB</option><option value="GB">GB</option></select></div><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveRule()">保存</button></div></div></div>
<div id="viewModal" class="modal"><div class="modal-box"><h3 style="margin-bottom:20px;border-bottom:1px solid #eee;padding-bottom:10px">规则详情</h3><div class="info-row"><span>备注</span><span class="info-val" id="view_n"></span></div><div class="info-row"><span>监听</span><span class="info-val" id="view_l"></span></div><div class="info-row"><span>目标</span><span class="info-val" id="view_r"></span></div><div style="margin:15px 0;border-top:1px dashed #ddd;padding-top:10px"></div><div id="view_expire_sec"><div class="info-row"><span>到期时间</span><span class="info-val" id="view_e_date"></span></div><div style="text-align:right;font-size:0.8rem;color:#666" id="view_e_remain"></div></div><div style="margin:15px 0;border-top:1px dashed #ddd;padding-top:10px"></div><div id="view_traffic_sec"><div class="info-row"><span>流量使用 (Max)</span><span class="info-val"><span id="view_t_used"></span> / <span id="view_t_limit"></span></span></div><div class="progress-bar"><div class="progress-fill" id="view_t_bar"></div></div><div style="text-align:right;margin-top:5px"><button class="btn btn-gray" style="font-size:0.7rem;padding:4px 8px" onclick="resetTraffic()">重置流量</button></div></div><div style="margin-top:25px;display:flex;justify-content:flex-end;"><button class="btn btn-primary" onclick="closeModal()">关闭</button></div></div></div>
<div id="setModal" class="modal"><div class="modal-box"><div class="tab-header"><div class="tab-btn active" onclick="switchTab(0)">管理账户</div><div class="tab-btn" onclick="switchTab(1)">个性背景</div></div><div class="tab-content active" id="tab0"><label>用户名</label><input id="set_u" value="{{USER}}"><label>重置密码 (留空保持不变)</label><input id="set_p" type="password"><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveAccount()">确认修改</button></div></div><div class="tab-content" id="tab1"><label>PC端壁纸 URL</label><input id="bg_pc" value="{{BG_PC}}"><label>手机端壁纸 URL</label><input id="bg_mob" value="{{BG_MOBILE}}"><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveBg()">应用背景</button></div></div></div></div>
<div id="batchModal" class="modal"><div class="modal-box" style="max-width:600px"><h3>批量添加规则</h3><p style="color:#666;font-size:0.85rem;margin-bottom:10px">格式：备注,监听端口,目标地址<br>一行一条，例如：<br>日本落地,10001,1.1.1.1:443</p><textarea id="batch_input" rows="10" style="width:100%;padding:10px;border:1px solid #ddd;border-radius:10px;font-family:monospace" placeholder="备注,监听端口,目标地址"></textarea><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="saveBatch()">开始导入</button></div></div></div>
<div id="restoreModal" class="modal"><div class="modal-box"><h3>恢复备份</h3><p style="color:#ef4444;font-size:0.9rem;margin-bottom:15px">警告：导入操作将覆盖当前所有规则！</p><textarea id="restore_input" rows="8" style="width:100%;padding:10px;border:1px solid #ddd;border-radius:10px;font-family:monospace;font-size:0.8rem"></textarea><div style="margin-top:25px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-danger" onclick="doRestore()">确认覆盖</button></div></div></div>
<script>
let rules=[];let curId=null;
const $=id=>document.getElementById(id);
const fmtBytes=b=>{if(b===0)return'0 B';const k=1024,dm=2,sizes=['B','KB','MB','GB','TB'],i=Math.floor(Math.log(b)/Math.log(k));return parseFloat((b/Math.pow(k,i)).toFixed(dm))+' '+sizes[i]};
const fmtDate=ts=>{if(!ts)return'永久有效';return new Date(ts).toLocaleString()};
const getRemain=ts=>{
    if(!ts) return '';
    const now=Date.now();
    const diff=ts-now;
    if(diff<0) return '已过期';
    const d = Math.floor(diff / (1000 * 60 * 60 * 24));
    const h = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    return `剩余 ${d}天 ${h}小时`;
};
async function load(){
    const active = document.activeElement;
    const tag = active ? active.tagName : '';
    const isTyping = (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT');
    if(document.querySelector('.modal[style*="flex"]') || isTyping) return;
    
    const r=await fetch('/api/rules');
    if(r.status===401)location.href='/login';
    const d=await r.json();
    rules=d.rules;
    render();
}
function render(){const t=$('list');const ev=$('emptyView');const table=$('ruleTable');t.innerHTML='';if(rules.length===0){ev.style.display='block';table.style.display='none'}else{ev.style.display='none';table.style.display='table';rules.forEach(r=>{const row=document.createElement('tr');if(!r.enabled)row.style.opacity='0.6';
let statusHtml=`<span class="status-dot ${r.enabled?'bg-green':'bg-gray'}"></span>${r.enabled?'在线':'暂停'}`;
if(r.status_msg) statusHtml+=` <span style="font-size:0.8rem;color:#ef4444">(${r.status_msg})</span>`;
const btns=`<button class="btn btn-gray" onclick="openView('${r.id}')"><i class="fas fa-eye"></i></button><button class="btn btn-gray" onclick="tog('${r.id}')"><i class="fas ${r.enabled?'fa-pause':'fa-play'}"></i></button><button class="btn btn-primary" onclick="openEdit('${r.id}')"><i class="fas fa-edit"></i></button><button class="btn btn-danger" onclick="del('${r.id}')"><i class="fas fa-trash-alt"></i></button>`;
const isMob=window.innerWidth<768;
let tfStr = fmtBytes(r.traffic_used);
if(r.traffic_limit > 0) tfStr += ` / ${fmtBytes(r.traffic_limit)}`;
if(isMob){row.innerHTML=`<td data-label="状态">${statusHtml}</td><td data-label="备注"><strong>${r.name}</strong></td><td data-label="监听">${r.listen}</td><td data-label="目标">${r.remote}</td><td data-label="流量">${tfStr}</td><td data-label="操作">${btns.replace(/class="btn/g,'class="btn btn-sm')}</td>`;}
else{row.innerHTML=`<td data-label="状态">${statusHtml}</td><td data-label="备注"><strong>${r.name}</strong></td><td data-label="监听">${r.listen}</td><td data-label="目标">${r.remote}</td><td data-label="流量">${tfStr}</td><td data-label="操作" style="display:flex;gap:6px;justify-content:flex-end;padding-right:15px">${btns}</td>`;}t.appendChild(row)})}}
function openAddModal(){curId=null;$('modalTitle').innerText='添加规则';['n','l','r','e','t_val'].forEach(x=>$('mod_'+x).value='');
const qn=$('n').value.trim();const ql=$('l').value.trim();const qr=$('r').value.trim();if(qn)$('mod_n').value=qn;if(ql)$('mod_l').value=ql;if(qr)$('mod_r').value=qr;
$('ruleModal').style.display='flex'}
function openEdit(id){curId=id;const r=rules.find(x=>x.id===id);$('modalTitle').innerText='编辑规则';$('mod_n').value=r.name;$('mod_l').value=r.listen.replace('0.0.0.0:','');$('mod_r').value=r.remote;
if(r.expire_date){const dt=new Date(r.expire_date);dt.setMinutes(dt.getMinutes()-dt.getTimezoneOffset());$('mod_e').value=dt.toISOString().slice(0,16)}else{$('mod_e').value=''}
if(r.traffic_limit){if(r.traffic_limit>=1073741824){$('mod_t_val').value=(r.traffic_limit/1073741824).toFixed(2);$('mod_t_unit').value='GB'}else{$('mod_t_val').value=(r.traffic_limit/1048576).toFixed(2);$('mod_t_unit').value='MB'}}else{$('mod_t_val').value=''}
$('ruleModal').style.display='flex'}
function openView(id){curId=id;const r=rules.find(x=>x.id===id);$('view_n').innerText=r.name;$('view_l').innerText=r.listen;$('view_r').innerText=r.remote;
if(r.expire_date){$('view_expire_sec').style.display='block';$('view_e_date').innerText=fmtDate(r.expire_date);$('view_e_remain').innerText=getRemain(r.expire_date)}else{$('view_expire_sec').style.display='none'}
$('view_traffic_sec').style.display='block';$('view_t_used').innerText=fmtBytes(r.traffic_used);
if(r.traffic_limit){$('view_t_limit').innerText=fmtBytes(r.traffic_limit);const pct=Math.min(100,(r.traffic_used/r.traffic_limit)*100);$('view_t_bar').style.width=pct+'%';$('view_t_bar').style.background=pct>90?'#ef4444':'#3b82f6'}else{$('view_t_limit').innerText='无限制';$('view_t_bar').style.width='0%'}
$('viewModal').style.display='flex'}
async function saveRule(){
    let [n,l,r,e,tv,tu]=['n','l','r','e','t_val','t_unit'].map(x=>$('mod_'+x).value.trim());
    if(!n||!l||!r) return alert('请填写必填项');
    if(!l.includes(':'))l='0.0.0.0:'+l;
    let ed=0; if(e) ed=new Date(e).getTime();
    let tl=0; if(tv && parseFloat(tv)>0){ tl = parseFloat(tv) * (tu==='GB'?1073741824:1048576); }
    const payload={name:n,listen:l,remote:r,expire_date:ed,traffic_limit:Math.floor(tl)};
    const url = curId ? `/api/rules/${curId}` : '/api/rules';
    const method = curId ? 'PUT' : 'POST';
    const res = await fetch(url,{method,headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
    const d=await res.json();
    if(d.status==='error') alert(d.message); else { closeModal(); load(); $('n').value='';$('l').value='';$('r').value='';}
}
async function resetTraffic(){if(!curId||!confirm('确定重置已用流量统计吗？'))return;await fetch(`/api/rules/${curId}/reset_traffic`,{method:'POST'});closeModal();load()}
async function tog(id){await fetch(`/api/rules/${id}/toggle`,{method:'POST'});load()}
async function del(id){if(confirm('确定删除此规则吗？'))await fetch(`/api/rules/${id}`,{method:'DELETE'});load()}
function openSettings(){$('setModal').style.display='flex';switchTab(0)}
function closeModal(){document.querySelectorAll('.modal').forEach(x=>x.style.display='none')}
function switchTab(idx){document.querySelectorAll('.tab-btn').forEach((b,i)=>b.classList.toggle('active',i===idx));document.querySelectorAll('.tab-content').forEach((c,i)=>c.classList.toggle('active',i===idx))}
async function saveAccount(){await fetch('/api/admin/account',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('set_u').value,password:$('set_p').value})});alert('账户已更新，请重新登录');location.reload()}
async function saveBg(){await fetch('/api/admin/bg',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({bg_pc:$('bg_pc').value,bg_mobile:$('bg_mob').value})});location.reload()}
async function doLogout(){await fetch('/logout',{method:'POST'});location.href='/login'}
function openBatch(){$('batchModal').style.display='flex';$('batch_input').value='';}
async function saveBatch(){const raw=$('batch_input').value;if(!raw.trim())return;const lines=raw.split('\n');const payload=[];for(let line of lines){line=line.trim();if(!line)continue;line=line.replace(/，/g,',');const parts=line.split(',');if(parts.length<3)continue;let [n,l,r]=[parts[0].trim(),parts[1].trim(),parts[2].trim()];if(l&&!l.includes(':'))l='0.0.0.0:'+l;if(n&&l&&r){payload.push({name:n,listen:l,remote:r,expire_date:0,traffic_limit:0});}}if(payload.length===0)return alert('格式错误');const res=await fetch('/api/rules/batch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});alert((await res.json()).message);$('batchModal').style.display='none';load()}
async function delAll(){if(rules.length===0||!confirm('⚠️ 确定清空？'))return;await fetch('/api/rules/all',{method:'DELETE'});load()}
function downloadBackup(){if(rules.length===0)return alert('无数据');window.location.href='/api/backup'}
function openRestore(){$('restoreModal').style.display='flex'}
async function doRestore(){try{const p=JSON.parse($('restore_input').value);if(!Array.isArray(p))throw 1;if(!confirm('确定覆盖？'))return;await fetch('/api/restore',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(p)});location.reload()}catch(e){alert('JSON格式错误')}}
setInterval(load, 3000);
load();window.addEventListener('resize',render);
</script></body></html>
"#;
EOF

echo -e "${CYAN}>>> 正在配置源码 (API端口: $API_PORT)...${RESET}"
sed -i "s|__GOST_API_URL_BINDING__|http://127.0.0.1:$API_PORT/api/config|g" src/main.rs
sed -i "s|__DEFAULT_PASS_BINDING__|$DEFAULT_PASS|g" src/main.rs

echo -e -n "${CYAN}>>> 正在编译面板 (请耐心等待！)...${RESET}"
OS_ARCH=$(uname -m)
if [[ "$OS_ARCH" == "aarch64" ]]; then
    RUST_TRIPLE="aarch64-unknown-linux-gnu"
else
    RUST_TRIPLE="x86_64-unknown-linux-gnu"
fi

mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.$RUST_TRIPLE]
linker = "gcc"
rustflags = ["-C", "link-arg=-fuse-ld=bfd"]
EOF

cargo clean >/dev/null 2>&1
cargo build --release > /tmp/panel_build.log 2>&1

if [ $? -eq 0 ] && [ -f "target/release/gost-panel" ]; then
    echo -e "${GREEN} [完成]${RESET}"
    echo -e -n "${CYAN}>>> 正在部署服务...${RESET}"
    mv target/release/gost-panel "$PANEL_BIN"
else
    echo -e "${RED} [失败]${RESET}"
    echo -e "${RED}================ 错误详情 ================${RESET}"
    cat /tmp/panel_build.log
    echo -e "${RED}===============================================${RESET}"
    exit 1
fi

rm -rf "$WORK_DIR"

cat > "$PANEL_SERVICE" <<EOF
[Unit]
Description=Gost Panel (Gost V3 Backend)
After=network.target

[Service]
User=root
Environment="PANEL_USER=$DEFAULT_USER"
Environment="PANEL_PORT=$PANEL_PORT"
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=$PANEL_BIN
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gost-panel >/dev/null 2>&1
systemctl restart gost-panel >/dev/null 2>&1
echo -e "${GREEN} [完成]${RESET}"

IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}====================================${RESET}"
echo -e "${GREEN}    ✅ Gost 面板 v13.0 (钛金版)        ${RESET}"
echo -e "${GREEN}====================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------"

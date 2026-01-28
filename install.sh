#!/bin/bash

# --- 基础配置 ---
PANEL_PORT="9794"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# --- 路径定义 ---
GOST_BIN="/usr/local/bin/gost"
GOST_CONFIG="/etc/gost/config.json"
WORK_DIR="/opt/gost_panel"
BINARY_PATH="/usr/local/bin/gost-panel"
DATA_FILE="/etc/gost/panel_data.json"

# --- 界面颜色 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- 辅助函数 ---
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

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行！${RESET}"
    exit 1
fi

clear
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}   Gost v3 面板 (流量专注版)   ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 1. 自动清理旧环境
echo -e -n "${CYAN}>>> 清理旧环境...${RESET}"
rm -rf ~/.cargo/config ~/.cargo/config.toml
rm -rf /opt/gost_panel
systemctl stop gost-panel >/dev/null 2>&1
echo -e "${GREEN} [完成]${RESET}"

# 2. 安装系统依赖
echo -e -n "${CYAN}>>> 检查系统依赖...${RESET}"
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y build-essential gcc g++ libssl-dev pkg-config curl wget tar >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum groupinstall -y 'Development Tools' >/dev/null 2>&1
    yum install -y openssl-devel gcc curl wget tar >/dev/null 2>&1
fi
echo -e "${GREEN} [完成]${RESET}"

# 3. 配置 Rust 环境
if ! command -v cargo &> /dev/null; then
    echo -e -n "${CYAN}>>> 安装 Rust...${RESET}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1 &
    spinner $!
    echo -e "${GREEN} [完成]${RESET}"
    source "$HOME/.cargo/env"
fi

# 4. 下载 Gost v3
if ! command -v gost &> /dev/null; then
    echo -e -n "${CYAN}>>> 安装 Gost v3...${RESET}"
    OS_ARCH=$(uname -m)
    if [[ "$OS_ARCH" == "x86_64" ]]; then
        URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_amd64.tar.gz"
    elif [[ "$OS_ARCH" == "aarch64" ]]; then
        URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_arm64.tar.gz"
    fi
    mkdir -p /tmp/gost_tmp
    wget -O /tmp/gost_tmp/gost.tar.gz "$URL" -q
    tar -xvf /tmp/gost_tmp/gost.tar.gz -C /tmp/gost_tmp >/dev/null
    mv /tmp/gost_tmp/gost "$GOST_BIN"
    chmod +x "$GOST_BIN"
    rm -rf /tmp/gost_tmp
    echo -e "${GREEN} [完成]${RESET}"
fi

mkdir -p "$(dirname "$GOST_CONFIG")"

# 5. 生成面板源码
echo -e "${CYAN}>>> 生成面板源代码...${RESET}"
mkdir -p "$WORK_DIR/src"
mkdir -p "$WORK_DIR/.cargo"

# 强制指定 Linker 为 GCC
cat > "$WORK_DIR/.cargo/config.toml" <<EOF
[target.x86_64-unknown-linux-gnu]
linker = "gcc"

[target.aarch64-unknown-linux-gnu]
linker = "gcc"
EOF

cd "$WORK_DIR"

cat > Cargo.toml <<EOF
[package]
name = "gost-panel"
version = "2.1.0"
edition = "2021"

[dependencies]
axum = { version = "0.7", features = ["macros"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tower-cookies = "0.10"
anyhow = "1.0"
uuid = { version = "1", features = ["v4"] }
sysinfo = "0.30"
EOF

# 生成 main.rs
cat > src/main.rs << 'EOF'
use axum::{
    extract::{State, Path},
    http::StatusCode,
    response::{Html, IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router, Form,
};
use serde::{Deserialize, Serialize};
use std::{fs, process::Command, sync::{Arc, Mutex}};
use tower_cookies::{Cookie, Cookies, CookieManagerLayer};
use sysinfo::{RefreshKind, Networks}; // 只引用网络模块

const GOST_CONFIG: &str = "/etc/gost/config.json";
const DATA_FILE: &str = "/etc/gost/panel_data.json";

// --- 数据结构 ---
#[derive(Serialize, Deserialize, Clone, Debug)]
struct Rule {
    id: String,
    name: String,
    listen: String,
    remote: String,
    protocol: String,
    enabled: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AdminConfig {
    username: String,
    pass_hash: String,
    bg_pc: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AppData {
    admin: AdminConfig,
    rules: Vec<Rule>,
}

#[derive(Serialize)]
struct DashboardStats {
    total_rules: usize,
    active_rules: usize,
    tx_speed: u64,
    rx_speed: u64,
}

#[derive(Serialize)]
struct GostConfig {
    services: Vec<GostService>,
    chains: Vec<GostChain>,
}
#[derive(Serialize)]
struct GostService {
    name: String,
    addr: String,
    handler: GostHandler,
    listener: GostListener,
}
#[derive(Serialize)]
struct GostHandler {
    #[serde(rename = "type")]
    r#type: String,
    chain: String,
}
#[derive(Serialize)]
struct GostListener {
    #[serde(rename = "type")]
    r#type: String,
}
#[derive(Serialize)]
struct GostChain {
    name: String,
    hops: Vec<GostHop>,
}
#[derive(Serialize)]
struct GostHop {
    name: String,
    addr: String,
}

struct AppState {
    data: Mutex<AppData>,
    nets: Mutex<Networks>,
}

#[tokio::main]
async fn main() {
    let initial_data = load_or_init_data();
    
    // 仅监控网络，不监控CPU/内存
    let mut nets = Networks::new_with_refreshed_list();
    nets.refresh();

    let state = Arc::new(AppState {
        data: Mutex::new(initial_data),
        nets: Mutex::new(nets),
    });

    let app = Router::new()
        .route("/", get(index_page))
        .route("/login", get(login_page).post(login_action))
        .route("/api/rules", get(get_rules).post(add_rule))
        .route("/api/rules/batch", post(batch_add_rules))
        .route("/api/rules/:id", put(update_rule).delete(delete_rule))
        .route("/api/rules/:id/toggle", post(toggle_rule))
        .route("/api/stats", get(get_stats))
        .route("/logout", post(logout_action))
        .layer(CookieManagerLayer::new())
        .with_state(state);

    let port = std::env::var("PANEL_PORT").unwrap_or_else(|_| "9794".to_string());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn load_or_init_data() -> AppData {
    if let Ok(content) = fs::read_to_string(DATA_FILE) {
        if let Ok(data) = serde_json::from_str::<AppData>(&content) {
            save_gost_config(&data);
            return data;
        }
    }
    let admin = AdminConfig {
        username: std::env::var("PANEL_USER").unwrap_or("admin".to_string()),
        pass_hash: std::env::var("PANEL_PASS").unwrap_or("123456".to_string()),
        bg_pc: "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".to_string(),
    };
    let data = AppData { admin, rules: Vec::new() };
    save_json(&data);
    save_gost_config(&data);
    data
}

fn save_json(data: &AppData) {
    let _ = fs::write(DATA_FILE, serde_json::to_string_pretty(data).unwrap());
}

fn save_gost_config(data: &AppData) {
    let mut services = Vec::new();
    let mut chains = Vec::new();

    for rule in data.rules.iter().filter(|r| r.enabled) {
        let chain_name = format!("chain-{}", rule.id);
        chains.push(GostChain {
            name: chain_name.clone(),
            hops: vec![GostHop {
                name: format!("hop-{}", rule.id),
                addr: rule.remote.clone(),
            }],
        });
        let service_type = if rule.protocol.to_lowercase() == "udp" { "udp" } else { "tcp" };
        services.push(GostService {
            name: format!("svc-{}", rule.id),
            addr: rule.listen.clone(),
            handler: GostHandler { r#type: service_type.to_string(), chain: chain_name },
            listener: GostListener { r#type: service_type.to_string() },
        });
    }

    let gost_conf = GostConfig { services, chains };
    let _ = fs::write(GOST_CONFIG, serde_json::to_string_pretty(&gost_conf).unwrap());
    let _ = Command::new("systemctl").arg("restart").arg("gost").status();
}

fn check_auth(cookies: &Cookies, state: &AppData) -> bool {
    if let Some(cookie) = cookies.get("auth_session") {
        return cookie.value() == state.admin.pass_hash;
    }
    false
}

// --- API ---
async fn get_stats(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    
    let mut nets = state.nets.lock().unwrap();
    nets.refresh();
    
    let mut tx = 0;
    let mut rx = 0;
    for (_, data) in &*nets {
        tx += data.transmitted();
        rx += data.received();
    }

    Json(DashboardStats {
        total_rules: data.rules.len(),
        active_rules: data.rules.iter().filter(|r| r.enabled).count(),
        tx_speed: tx,
        rx_speed: rx,
    }).into_response()
}

async fn index_page(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return axum::response::Redirect::to("/login").into_response(); }
    let html = DASHBOARD_HTML
        .replace("{{USER}}", &data.admin.username)
        .replace("{{BG_PC}}", &data.admin.bg_pc);
    Html(html).into_response()
}

async fn login_page(State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    let html = LOGIN_HTML.replace("{{BG_PC}}", &data.admin.bg_pc);
    Html(html).into_response()
}

#[derive(Deserialize)] struct LoginParams { username: String, password: String }
async fn login_action(cookies: Cookies, State(state): State<Arc<AppState>>, Form(form): Form<LoginParams>) -> Response {
    let data = state.data.lock().unwrap();
    if form.username == data.admin.username && form.password == data.admin.pass_hash {
        let mut cookie = Cookie::new("auth_session", data.admin.pass_hash.clone());
        cookie.set_path("/"); cookie.set_http_only(true); cookies.add(cookie);
        axum::response::Redirect::to("/").into_response()
    } else { StatusCode::UNAUTHORIZED.into_response() }
}
async fn logout_action(cookies: Cookies) -> Response {
    let mut cookie = Cookie::new("auth_session", "");
    cookie.set_path("/"); cookies.remove(cookie);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

// 规则 CRUD
async fn get_rules(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    Json(data.clone()).into_response()
}
#[derive(Deserialize)] struct RuleReq { name: String, listen: String, remote: String, protocol: Option<String> }
async fn add_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<RuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if req.listen.trim().is_empty() || req.remote.trim().is_empty() { return Json(serde_json::json!({"status":"error"})).into_response(); }
    data.rules.push(Rule { id: uuid::Uuid::new_v4().to_string(), name: req.name, listen: req.listen, remote: req.remote, protocol: req.protocol.unwrap_or("tcp".to_string()), enabled: true });
    save_json(&data); save_gost_config(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn batch_add_rules(cookies: Cookies, State(state): State<Arc<AppState>>, Json(reqs): Json<Vec<RuleReq>>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    let mut count = 0;
    for req in reqs {
        if req.listen.trim().is_empty() || req.remote.trim().is_empty() { continue; }
        if data.rules.iter().any(|r| r.listen == req.listen) { continue; }
        data.rules.push(Rule { id: uuid::Uuid::new_v4().to_string(), name: req.name, listen: req.listen, remote: req.remote, protocol: req.protocol.unwrap_or("tcp".to_string()), enabled: true });
        count += 1;
    }
    if count > 0 { save_json(&data); save_gost_config(&data); }
    Json(serde_json::json!({"status":"ok", "count": count})).into_response()
}
async fn update_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<RuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(r) = data.rules.iter_mut().find(|r| r.id == id) { r.name=req.name; r.listen=req.listen; r.remote=req.remote; r.protocol=req.protocol.unwrap_or("tcp".to_string()); save_json(&data); save_gost_config(&data); }
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn delete_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.rules.retain(|r| r.id != id); save_json(&data); save_gost_config(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn toggle_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(r) = data.rules.iter_mut().find(|r| r.id == id) { r.enabled=!r.enabled; save_json(&data); save_gost_config(&data); }
    Json(serde_json::json!({"status":"ok"})).into_response()
}

// --- Frontend ---
const LOGIN_HTML: &str = r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Login</title><style>body{margin:0;height:100vh;display:flex;justify-content:center;align-items:center;background:url('{{BG_PC}}') center/cover;font-family:system-ui}.box{background:rgba(255,255,255,0.8);backdrop-filter:blur(10px);padding:2rem;border-radius:12px;width:300px;box-shadow:0 10px 30px rgba(0,0,0,0.2)}input{width:100%;padding:12px;margin:8px 0;border:1px solid #ccc;border-radius:6px;box-sizing:border-box}button{width:100%;padding:12px;background:#2563eb;color:white;border:none;border-radius:6px;cursor:pointer;font-weight:bold}</style></head><body><div class="box"><h2 style="text-align:center;margin-top:0">Gost Panel</h2><form onsubmit="doLogin(event)"><input id="u" placeholder="Admin"><input id="p" type="password" placeholder="Password"><button>Sign In</button></form></div><script>async function doLogin(e){e.preventDefault();await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${document.getElementById('u').value}&password=${document.getElementById('p').value}`}).then(r=>{if(r.redirected)location.href='/';else alert('Error')})}</script></body></html>"#;

const DASHBOARD_HTML: &str = r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Gost Pro</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
<style>
:root { --sidebar-w: 240px; --primary: #2563eb; --bg: #f3f4f6; }
body { margin: 0; display: flex; height: 100vh; font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); overflow: hidden; }
/* Sidebar */
.sidebar { width: var(--sidebar-w); background: #1f2937; color: white; display: flex; flex-direction: column; flex-shrink: 0; }
.brand { padding: 20px; font-size: 1.2rem; font-weight: bold; border-bottom: 1px solid #374151; display: flex; align-items: center; gap: 10px; }
.menu { flex: 1; padding: 20px 0; }
.menu-item { padding: 12px 24px; cursor: pointer; display: flex; align-items: center; gap: 12px; color: #9ca3af; transition: 0.2s; text-decoration: none; }
.menu-item:hover, .menu-item.active { background: #111827; color: white; border-right: 3px solid var(--primary); }
.user-panel { padding: 20px; border-top: 1px solid #374151; }
/* Main */
.main { flex: 1; display: flex; flex-direction: column; overflow: hidden; position: relative; }
.header { background: white; padding: 15px 30px; border-bottom: 1px solid #e5e7eb; display: flex; justify-content: space-between; align-items: center; }
.content { flex: 1; overflow-y: auto; padding: 30px; }
.section { display: none; animation: fadeIn 0.3s; }
.section.active { display: block; }
@keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
/* Cards */
.card { background: white; border-radius: 10px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 20px; }
.stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 20px; margin-bottom: 30px; }
.stat-box { background: white; padding: 20px; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); display: flex; align-items: center; gap: 15px; }
.stat-icon { width: 50px; height: 50px; border-radius: 10px; background: #eff6ff; color: var(--primary); display: flex; justify-content: center; align-items: center; font-size: 1.5rem; }
/* Tables & Forms */
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 12px; border-bottom: 1px solid #f3f4f6; }
th { color: #6b7280; font-size: 0.85rem; text-transform: uppercase; }
.status-dot { height: 8px; width: 8px; background: #d1d5db; border-radius: 50%; display: inline-block; margin-right: 6px; }
.status-dot.on { background: #10b981; box-shadow: 0 0 5px #10b981; }
input, select { padding: 10px; border: 1px solid #d1d5db; border-radius: 6px; outline: none; }
.btn { padding: 8px 16px; border-radius: 6px; border: none; cursor: pointer; color: white; font-weight: 500; display: inline-flex; align-items: center; gap: 5px; }
.btn-primary { background: var(--primary); }
.btn-danger { background: #ef4444; }
.btn-sm { padding: 5px 10px; font-size: 0.85rem; }
/* Batch Modal */
.modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 99; justify-content: center; align-items: center; }
.modal-box { background: white; padding: 25px; border-radius: 12px; width: 500px; max-width: 90%; }
/* Responsive */
@media(max-width: 768px) { .sidebar { display: none; } }
</style>
</head><body>

<div class="sidebar">
    <div class="brand"><i class="fas fa-network-wired"></i> Gost Pro</div>
    <div class="menu">
        <a class="menu-item active" onclick="nav('dashboard', this)"><i class="fas fa-chart-line"></i> 仪表盘</a>
        <a class="menu-item" onclick="nav('rules', this)"><i class="fas fa-exchange-alt"></i> 转发管理</a>
        <a class="menu-item" onclick="nav('nodes', this)"><i class="fas fa-server"></i> 节点管理</a>
        <a class="menu-item" onclick="nav('settings', this)"><i class="fas fa-cog"></i> 系统设置</a>
    </div>
    <div class="user-panel">
        <button class="btn btn-danger" style="width:100%" onclick="logout()"><i class="fas fa-sign-out-alt"></i> Logout</button>
    </div>
</div>

<div class="main">
    <div class="header">
        <h3 id="page-title" style="margin:0">仪表盘</h3>
        <div style="font-size:0.9rem;color:#6b7280">System: 9794 Port</div>
    </div>
    <div class="content">
        
        <div id="dashboard" class="section active">
            <div class="stats-grid">
                <div class="stat-box">
                    <div class="stat-icon" style="background:#dbeafe;color:#2563eb"><i class="fas fa-list"></i></div>
                    <div><div style="color:#6b7280;font-size:0.9rem">总规则数</div><div id="st_total" style="font-size:1.4rem;font-weight:bold">0</div></div>
                </div>
                <div class="stat-box">
                    <div class="stat-icon" style="background:#dcfce7;color:#10b981"><i class="fas fa-check-circle"></i></div>
                    <div><div style="color:#6b7280;font-size:0.9rem">运行中</div><div id="st_active" style="font-size:1.4rem;font-weight:bold">0</div></div>
                </div>
                <div class="stat-box">
                    <div class="stat-icon" style="color:#10b981;background:#ecfdf5"><i class="fas fa-arrow-down"></i></div>
                    <div><div style="color:#6b7280;font-size:0.9rem">实时下载</div><div id="st_rx" style="font-size:1.4rem;font-weight:bold">0 B/s</div></div>
                </div>
                <div class="stat-box">
                    <div class="stat-icon" style="color:#ef4444;background:#fef2f2"><i class="fas fa-arrow-up"></i></div>
                    <div><div style="color:#6b7280;font-size:0.9rem">实时上传</div><div id="st_tx" style="font-size:1.4rem;font-weight:bold">0 B/s</div></div>
                </div>
            </div>
            <div class="card">
                <h4><i class="fas fa-info-circle"></i> 系统公告</h4>
                <p style="color:#666">欢迎使用 Gost v3 Pro 面板。系统运行正常。</p>
            </div>
        </div>

        <div id="rules" class="section">
            <div class="card">
                <div style="display:flex;gap:10px;margin-bottom:15px">
                    <input id="n" placeholder="备注 (Name)" style="flex:1">
                    <input id="l" placeholder="本地端口 (:10000)" style="width:120px">
                    <input id="r" placeholder="转发目标 (1.1.1.1:80)" style="flex:2">
                    <select id="t" style="width:100px"><option value="tcp">TCP</option><option value="udp">UDP</option></select>
                    <button class="btn btn-primary" onclick="add()"><i class="fas fa-plus"></i> 添加</button>
                    <button class="btn" style="background:#f59e0b" onclick="$('batchModal').style.display='flex'"><i class="fas fa-paste"></i> 批量</button>
                </div>
                <table>
                    <thead><tr><th>状态</th><th>备注</th><th>监听</th><th>协议</th><th>目标</th><th>操作</th></tr></thead>
                    <tbody id="list"></tbody>
                </table>
            </div>
        </div>

        <div id="nodes" class="section">
            <div class="card" style="text-align:center;padding:50px">
                <i class="fas fa-network-wired" style="font-size:3rem;color:#d1d5db;margin-bottom:20px"></i>
                <h3>节点管理</h3>
                <p style="color:#666">分布式节点 Agent 开发中...<br>此处将显示多台服务器的连接状态。</p>
            </div>
        </div>
        
        <div id="settings" class="section">
            <div class="card">
                <h3>系统信息</h3>
                <p>面板版本: v2.1.0 Traffic Edition</p>
                <p>核心引擎: Gost v3</p>
            </div>
        </div>
    </div>
</div>

<div id="batchModal" class="modal">
    <div class="modal-box">
        <h3>批量导入规则</h3>
        <textarea id="batchInput" rows="10" style="width:100%;margin:10px 0;font-family:monospace" placeholder="备注|:端口|目标IP:端口"></textarea>
        <div style="text-align:right">
            <button class="btn" style="background:#9ca3af" onclick="$('batchModal').style.display='none'">取消</button>
            <button class="btn btn-primary" onclick="doBatch()">确认导入</button>
        </div>
    </div>
</div>

<script>
const $=id=>document.getElementById(id);
const fmt=(b)=>{if(b===0)return'0 B';const k=1024,s=['B','K','M','G'];const i=Math.floor(Math.log(b)/Math.log(k));return parseFloat((b/Math.pow(k,i)).toFixed(1))+s[i]};

function nav(id, el) {
    document.querySelectorAll('.section').forEach(d=>d.classList.remove('active'));
    document.querySelectorAll('.menu-item').forEach(m=>m.classList.remove('active'));
    $(id).classList.add('active');
    if(el) el.classList.add('active');
    $('page-title').innerText = el ? el.innerText : '仪表盘';
}

async function loadStats() {
    try {
        const r = await fetch('/api/stats');
        if(r.ok) {
            const d = await r.json();
            $('st_total').innerText = d.total_rules;
            $('st_active').innerText = d.active_rules;
            $('st_tx').innerText = fmt(d.tx_speed) + '/s';
            $('st_rx').innerText = fmt(d.rx_speed) + '/s';
        }
    } catch(e){}
}
// 仅在仪表盘激活时刷新
setInterval(()=>{ if($('dashboard').classList.contains('active')) loadStats(); }, 2000); 

async function loadRules() {
    const r = await fetch('/api/rules');
    if(r.status===401) return location.href='/login';
    const d = await r.json();
    const t = $('list'); t.innerHTML = '';
    d.rules.forEach(x => {
        t.innerHTML += `<tr>
            <td><span class="status-dot ${x.enabled?'on':''}"></span>${x.enabled?'在线':'停用'}</td>
            <td>${x.name}</td><td>${x.listen}</td><td>${x.protocol}</td><td>${x.remote}</td>
            <td>
                <button class="btn btn-sm" style="background:#9ca3af" onclick="tog('${x.id}')"><i class="fas fa-power-off"></i></button>
                <button class="btn btn-sm btn-danger" onclick="del('${x.id}')"><i class="fas fa-trash"></i></button>
            </td>
        </tr>`;
    });
}
if(location.pathname === '/') { loadRules(); loadStats(); }

async function add(){
    const n=$('n').value,l=$('l').value,r=$('r').value,t=$('t').value;
    if(!n||!l||!r) return alert('完善信息');
    await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r,protocol:t})});
    loadRules(); $('n').value='';$('l').value='';$('r').value='';
}
async function doBatch(){
    const txt=$('batchInput').value.trim();
    if(!txt) return;
    const reqs = txt.split('\n').map(x=>x.split('|')).filter(x=>x.length===3).map(x=>({name:x[0],listen:x[1],remote:x[2],protocol:'tcp'}));
    await fetch('/api/rules/batch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(reqs)});
    $('batchModal').style.display='none'; loadRules();
}
async function tog(id){ await fetch(`/api/rules/${id}/toggle`,{method:'POST'}); loadRules(); }
async function del(id){ if(confirm('Del?')) await fetch(`/api/rules/${id}`,{method:'DELETE'}); loadRules(); }
async function logout(){ await fetch('/logout',{method:'POST'}); location.reload(); }
</script></body></html>
EOF

# 6. 编译安装
echo -e "${CYAN}>>> 正在编译 (极速模式)...${RESET}"
/root/.cargo/bin/cargo clean
/root/.cargo/bin/cargo build --release

if [ ! -f "target/release/gost-panel" ]; then
    echo -e "${RED}编译失败，请截图报错！${RESET}"
    exit 1
fi

echo -e "${GREEN} [编译成功]${RESET}"
systemctl stop gost-panel
cp target/release/gost-panel "$BINARY_PATH"

# 7. 配置服务
cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost v3 Core
After=network.target
[Service]
Type=simple
User=root
ExecStart=$GOST_BIN -C $GOST_CONFIG
Restart=always
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/gost-panel.service <<EOF
[Unit]
Description=Gost Pro Panel
After=network.target gost.service
[Service]
User=root
Environment="PANEL_USER=$DEFAULT_USER"
Environment="PANEL_PASS=$DEFAULT_PASS"
Environment="PANEL_PORT=$PANEL_PORT"
ExecStart=$BINARY_PATH
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# 初始化配置
if [ ! -f "$GOST_CONFIG" ]; then
    mkdir -p /etc/gost
    echo '{"services":[],"chains":[]}' > $GOST_CONFIG
fi

systemctl enable gost gost-panel >/dev/null 2>&1
systemctl restart gost gost-panel

# 8. 完成
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}✅ Gost v3 面板 (流量专注版) 部署完成！${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "默认账户 : ${YELLOW}${DEFAULT_USER}${RESET} / ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "------------------------------------------"

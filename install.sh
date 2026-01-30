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

# --- 颜色 ---
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
echo -e "${GREEN}   Gost v3 面板  ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 1. 环境清理与准备
echo -e -n "${CYAN}>>> 清理旧环境...${RESET}"
# 停止服务
systemctl stop gost-panel gost >/dev/null 2>&1
# 删除旧配置防止干扰
rm -rf ~/.cargo/config ~/.cargo/config.toml
rm -rf /opt/gost_panel
echo -e "${GREEN} [完成]${RESET}"

echo -e -n "${CYAN}>>> 安装系统依赖...${RESET}"
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y build-essential gcc g++ libssl-dev pkg-config curl wget tar >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum groupinstall -y 'Development Tools' >/dev/null 2>&1
    yum install -y openssl-devel gcc curl wget tar >/dev/null 2>&1
fi
echo -e "${GREEN} [完成]${RESET}"

# 2. Rust 环境
if ! command -v cargo &> /dev/null; then
    echo -e -n "${CYAN}>>> 安装 Rust...${RESET}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1
    source "$HOME/.cargo/env"
    echo -e "${GREEN} [完成]${RESET}"
fi

# 3. Gost v3 安装
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

# 4. 生成面板源码
echo -e "${CYAN}>>> 生成面板源码...${RESET}"
mkdir -p "$WORK_DIR/src" "$WORK_DIR/.cargo"

# ★关键修复：强制指定 Linker 为 GCC
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
version = "2.0.0"
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

# 生成 main.rs (分段写入，防止截断)
# 第一部分：Rust 逻辑代码
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
use sysinfo::{CpuRefreshKind, MemoryRefreshKind, RefreshKind, System, Networks};

const GOST_CONFIG: &str = "/etc/gost/config.json";
const DATA_FILE: &str = "/etc/gost/panel_data.json";

// --- 数据结构 ---
#[derive(Serialize, Deserialize, Clone, Debug)]
struct Rule { id: String, name: String, listen: String, remote: String, protocol: String, enabled: bool }

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AdminConfig { username: String, pass_hash: String, bg_pc: String, bg_mobile: String }

#[derive(Serialize, Deserialize, Clone, Debug)]
struct AppData { admin: AdminConfig, rules: Vec<Rule> }

#[derive(Serialize)]
struct SystemStatus { cpu_usage: f32, ram_usage: u64, ram_total: u64, tx_speed: u64, rx_speed: u64 }

#[derive(Serialize)]
struct GostConfig { services: Vec<GostService>, chains: Vec<GostChain> }
#[derive(Serialize)]
struct GostService { name: String, addr: String, handler: GostHandler, listener: GostListener }
#[derive(Serialize)]
struct GostHandler { #[serde(rename = "type")] r#type: String, chain: String }
#[derive(Serialize)]
struct GostListener { #[serde(rename = "type")] r#type: String }
#[derive(Serialize)]
struct GostChain { name: String, hops: Vec<GostHop> }
#[derive(Serialize)]
struct GostHop { name: String, addr: String }

struct AppState { data: Mutex<AppData>, sys: Mutex<System>, nets: Mutex<Networks> }

#[tokio::main]
async fn main() {
    let initial_data = load_or_init_data();
    let mut sys = System::new_with_specifics(RefreshKind::new().with_cpu(CpuRefreshKind::everything()).with_memory(MemoryRefreshKind::everything()));
    let mut nets = Networks::new_with_refreshed_list();
    std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL);
    sys.refresh_cpu(); sys.refresh_memory(); nets.refresh();

    let state = Arc::new(AppState { data: Mutex::new(initial_data), sys: Mutex::new(sys), nets: Mutex::new(nets) });

    let app = Router::new()
        .route("/", get(index_page))
        .route("/login", get(login_page).post(login_action))
        .route("/api/rules", get(get_rules).post(add_rule))
        .route("/api/rules/batch", post(batch_add_rules))
        .route("/api/rules/:id", put(update_rule).delete(delete_rule))
        .route("/api/rules/:id/toggle", post(toggle_rule))
        .route("/api/status", get(get_status))
        .route("/logout", post(logout_action))
        .layer(CookieManagerLayer::new()).with_state(state);

    let port = std::env::var("PANEL_PORT").unwrap_or_else(|_| "9794".to_string());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn load_or_init_data() -> AppData {
    if let Ok(content) = fs::read_to_string(DATA_FILE) {
        if let Ok(data) = serde_json::from_str::<AppData>(&content) { save_gost_config(&data); return data; }
    }
    let admin = AdminConfig {
        username: std::env::var("PANEL_USER").unwrap_or("admin".to_string()),
        pass_hash: std::env::var("PANEL_PASS").unwrap_or("123456".to_string()),
        bg_pc: "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".to_string(),
        bg_mobile: "https://img.inim.im/file/1764296937373_bg_m_2.png".to_string(),
    };
    let data = AppData { admin, rules: Vec::new() };
    save_json(&data); save_gost_config(&data); data
}

fn save_json(data: &AppData) { let _ = fs::write(DATA_FILE, serde_json::to_string_pretty(data).unwrap()); }

fn save_gost_config(data: &AppData) {
    let mut services = Vec::new(); let mut chains = Vec::new();
    for rule in data.rules.iter().filter(|r| r.enabled) {
        let chain_name = format!("chain-{}", rule.id);
        chains.push(GostChain { name: chain_name.clone(), hops: vec![GostHop { name: format!("hop-{}", rule.id), addr: rule.remote.clone() }] });
        let service_type = if rule.protocol.to_lowercase() == "udp" { "udp" } else { "tcp" };
        services.push(GostService { name: format!("svc-{}", rule.id), addr: rule.listen.clone(), handler: GostHandler { r#type: service_type.to_string(), chain: chain_name }, listener: GostListener { r#type: service_type.to_string() } });
    }
    let gost_conf = GostConfig { services, chains };
    let _ = fs::write(GOST_CONFIG, serde_json::to_string_pretty(&gost_conf).unwrap());
    let _ = Command::new("systemctl").arg("restart").arg("gost").status();
}

fn check_auth(cookies: &Cookies, state: &AppData) -> bool {
    if let Some(cookie) = cookies.get("auth_session") { return cookie.value() == state.admin.pass_hash; }
    false
}

async fn get_status(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    let mut sys = state.sys.lock().unwrap(); let mut nets = state.nets.lock().unwrap();
    sys.refresh_cpu(); sys.refresh_memory(); nets.refresh();
    let mut tx = 0; let mut rx = 0;
    for (_, data) in &*nets { tx += data.transmitted(); rx += data.received(); }
    Json(SystemStatus { cpu_usage: sys.global_cpu_info().cpu_usage(), ram_usage: sys.used_memory(), ram_total: sys.total_memory(), tx_speed: tx, rx_speed: rx }).into_response()
}

async fn index_page(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return axum::response::Redirect::to("/login").into_response(); }
    let html = get_dash_html().replace("{{USER}}", &data.admin.username).replace("{{BG_PC}}", &data.admin.bg_pc);
    Html(html).into_response()
}
async fn login_page(State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    let html = get_login_html().replace("{{BG_PC}}", &data.admin.bg_pc);
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
    let mut cookie = Cookie::new("auth_session", ""); cookie.set_path("/"); cookies.remove(cookie);
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn get_rules(cookies: Cookies, State(state): State<Arc<AppState>>) -> Response {
    let data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    Json(data.clone()).into_response()
}
#[derive(Deserialize)] struct RuleReq { name: String, listen: String, remote: String, protocol: Option<String> }
async fn add_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Json(req): Json<RuleReq>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
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
    if let Some(rule) = data.rules.iter_mut().find(|r| r.id == id) {
        rule.name = req.name; rule.listen = req.listen; rule.remote = req.remote; rule.protocol = req.protocol.unwrap_or("tcp".to_string());
        save_json(&data); save_gost_config(&data);
    }
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn toggle_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    if let Some(rule) = data.rules.iter_mut().find(|r| r.id == id) { rule.enabled = !rule.enabled; save_json(&data); save_gost_config(&data); }
    Json(serde_json::json!({"status":"ok"})).into_response()
}
async fn delete_rule(cookies: Cookies, State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    let mut data = state.data.lock().unwrap();
    if !check_auth(&cookies, &data) { return StatusCode::UNAUTHORIZED.into_response(); }
    data.rules.retain(|r| r.id != id); save_json(&data); save_gost_config(&data);
    Json(serde_json::json!({"status":"ok"})).into_response()
}

// 封装 HTML 防止截断
fn get_login_html() -> String {
    r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Gost Login</title><style>body{margin:0;height:100vh;display:flex;justify-content:center;align-items:center;background:url('{{BG_PC}}') center/cover;font-family:sans-serif}.box{background:rgba(255,255,255,0.4);backdrop-filter:blur(20px);padding:2rem;border-radius:16px;width:320px;text-align:center}input{width:100%;padding:10px;margin:10px 0;border-radius:8px;border:none}button{width:100%;padding:10px;background:#3b82f6;color:white;border:none;border-radius:8px;cursor:pointer}</style></head><body><div class="box"><h2>Gost Panel v3</h2><form onsubmit="doLogin(event)"><input id="u" placeholder="User"><input id="p" type="password" placeholder="Pass"><button>Login</button></form></div><script>async function doLogin(e){e.preventDefault();await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${document.getElementById('u').value}&password=${document.getElementById('p').value}`}).then(r=>{if(r.redirected)location.href='/';else alert('Fail')})}</script></body></html>"#.to_string()
}
EOF

# 第二部分：追加 DASHBOARD_HTML
cat >> src/main.rs << 'EOF'
fn get_dash_html() -> String {
    r#"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Gost Dashboard</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>
:root{--primary:#3b82f6;--text:#374151;--bg-glass:rgba(255,255,255,0.65)}
body{margin:0;background:url('{{BG_PC}}') center/cover fixed;font-family:sans-serif;height:100vh;display:flex;flex-direction:column;color:var(--text)}
.navbar{background:rgba(255,255,255,0.5);backdrop-filter:blur(20px);padding:1rem 2rem;display:flex;justify-content:space-between;align-items:center;position:sticky;top:0;z-index:100}
.container{flex:1;max-width:1100px;margin:1.5rem auto;width:95%;display:flex;flex-direction:column;gap:1.5rem}
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px}
.stat-card{background:var(--bg-glass);backdrop-filter:blur(20px);padding:15px;border-radius:12px;display:flex;align-items:center;gap:15px;box-shadow:0 4px 10px rgba(0,0,0,0.05)}
.stat-icon{width:45px;height:45px;border-radius:10px;background:white;display:flex;justify-content:center;align-items:center;font-size:1.2rem;color:var(--primary)}
.card{background:var(--bg-glass);backdrop-filter:blur(20px);border-radius:16px;padding:1.5rem;box-shadow:0 4px 15px rgba(0,0,0,0.05)}
.input-group{display:grid;grid-template-columns:1fr 1fr 2fr 1fr auto;gap:10px;align-items:center}
input,select,textarea{padding:10px;border-radius:8px;border:1px solid rgba(0,0,0,0.1);outline:none;background:rgba(255,255,255,0.8)}
button{padding:10px 15px;border-radius:8px;border:none;cursor:pointer;color:white;font-weight:bold;transition:0.2s}
button:hover{transform:translateY(-1px);opacity:0.9}
.btn-add{background:var(--primary)}.btn-del{background:#ef4444}.btn-gray{background:#9ca3af}.btn-warn{background:#f59e0b}
table{width:100%;border-collapse:collapse;margin-top:10px}
td,th{padding:12px;text-align:left;border-bottom:1px solid rgba(0,0,0,0.05)}
.status{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:5px}
.on{background:#34d399;box-shadow:0 0 5px #34d399}.off{background:#9ca3af}
.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.3);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(5px)}
.modal-box{background:white;width:90%;max-width:500px;padding:20px;border-radius:15px;box-shadow:0 10px 30px rgba(0,0,0,0.2)}
@media(max-width:768px){.input-group{grid-template-columns:1fr}thead{display:none}tr{display:flex;flex-direction:column;background:rgba(255,255,255,0.5);margin-bottom:10px;padding:10px;border-radius:10px}td{padding:5px 0}}
</style></head><body>
<div class="navbar">
    <div style="display:flex;align-items:center;gap:10px">
        <i class="fas fa-project-diagram" style="font-size:1.5rem;color:#2563eb"></i>
        <div><h3 style="margin:0">Gost Panel</h3><span style="font-size:0.8rem;opacity:0.6">v1.1 监控版</span></div>
    </div>
    <div style="display:flex;gap:10px">
        <button class="btn-warn" onclick="openBatch()"><i class="fas fa-file-import"></i> 批量</button>
        <button class="btn-del" onclick="logout()"><i class="fas fa-power-off"></i></button>
    </div>
</div>
<div class="container">
    <div class="stats-grid">
        <div class="stat-card">
            <div class="stat-icon"><i class="fas fa-microchip"></i></div>
            <div><div style="font-size:0.8rem;opacity:0.7">CPU 使用率</div><div id="stat_cpu" style="font-weight:bold;font-size:1.1rem">0%</div></div>
        </div>
        <div class="stat-card">
            <div class="stat-icon"><i class="fas fa-memory"></i></div>
            <div><div style="font-size:0.8rem;opacity:0.7">内存使用</div><div id="stat_ram" style="font-weight:bold;font-size:1.1rem">0/0 GB</div></div>
        </div>
        <div class="stat-card">
            <div class="stat-icon"><i class="fas fa-exchange-alt"></i></div>
            <div><div style="font-size:0.8rem;opacity:0.7">实时网速 (↑↓)</div><div id="stat_net" style="font-weight:bold;font-size:1rem">0 KB/s</div></div>
        </div>
    </div>

    <div class="card">
        <h4 style="margin:0 0 15px 0;opacity:0.7">快速添加</h4>
        <div class="input-group">
            <input id="n" placeholder="备注 (Name)">
            <input id="l" placeholder="本地端口 (:10000)">
            <input id="r" placeholder="转发目标 (1.1.1.1:80)">
            <select id="t"><option value="tcp">TCP (通用)</option><option value="udp">UDP (游戏)</option></select>
            <button class="btn-add" onclick="add()"><i class="fas fa-plus"></i></button>
        </div>
    </div>
    <div class="card" style="flex:1;overflow:auto">
        <table>
            <thead><tr><th>状态</th><th>备注</th><th>监听</th><th>协议</th><th>目标</th><th>操作</th></tr></thead>
            <tbody id="list"></tbody>
        </table>
    </div>
</div>

<div id="batchModal" class="modal">
    <div class="modal-box">
        <h3><i class="fas fa-paste"></i> 批量添加</h3>
        <p style="font-size:0.85rem;color:#666">每行一条，格式：备注|本地端口|目标地址<br>例如：上海中转|:20001|1.2.3.4:80</p>
        <textarea id="batchInput" rows="8" style="width:100%;margin:10px 0;font-family:monospace" placeholder="游戏服|:10000|1.1.1.1:80&#10;网站|:20000|2.2.2.2:443"></textarea>
        <div style="display:flex;justify-content:flex-end;gap:10px">
            <button class="btn-gray" onclick="$('batchModal').style.display='none'">取消</button>
            <button class="btn-add" onclick="doBatch()">开始导入</button>
        </div>
    </div>
</div>

<script>
const $=id=>document.getElementById(id);
const fmtBytes=b=>{if(b===0)return'0 B';const k=1024,s=['B','KB','MB','GB'];const i=Math.floor(Math.log(b)/Math.log(k));return parseFloat((b/Math.pow(k,i)).toFixed(1))+' '+s[i]};

async function loadStats(){
    try {
        const r=await fetch('/api/status');
        if(r.ok){
            const d=await r.json();
            $('stat_cpu').innerText = d.cpu_usage.toFixed(1) + '%';
            $('stat_ram').innerText = fmtBytes(d.ram_usage) + ' / ' + fmtBytes(d.ram_total);
            $('stat_net').innerHTML = `<span style="color:#ef4444">↑ ${fmtBytes(d.tx_speed)}/s</span> <span style="color:#10b981">↓ ${fmtBytes(d.rx_speed)}/s</span>`;
        }
    }catch(e){}
}
// 自动刷新状态
setInterval(loadStats, 2000);
loadStats();

async function load(){
    const res=await fetch('/api/rules');
    if(res.status===401)return location.href='/login';
    const data=await res.json();
    const list=$('list');list.innerHTML='';
    data.rules.forEach(r=>{
        const tr=document.createElement('tr');
        tr.style.opacity = r.enabled ? '1' : '0.6';
        tr.innerHTML=`
            <td><span class="status ${r.enabled?'on':'off'}"></span>${r.enabled?'运行':'暂停'}</td>
            <td><strong>${r.name}</strong></td>
            <td>${r.listen}</td>
            <td><span style="background:rgba(0,0,0,0.05);padding:2px 6px;border-radius:4px;font-size:0.8rem">${r.protocol}</span></td>
            <td>${r.remote}</td>
            <td>
                <button class="btn-gray" onclick="tog('${r.id}')"><i class="fas ${r.enabled?'fa-pause':'fa-play'}"></i></button>
                <button class="btn-del" onclick="del('${r.id}')"><i class="fas fa-trash"></i></button>
            </td>
        `;
        list.appendChild(tr);
    });
}
async function add(){
    const n=$('n').value,l=$('l').value,r=$('r').value,t=$('t').value;
    if(!n||!l||!r)return alert('请填写完整');
    if(!l.includes(':')) return alert('端口需带冒号 :');
    await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r,protocol:t})});
    $('n').value='';$('l').value='';$('r').value='';load();
}
function openBatch(){$('batchModal').style.display='flex';$('batchInput').focus();}
async function doBatch(){
    const txt=$('batchInput').value;
    if(!txt.trim())return;
    const lines=txt.split('\n');
    const reqs=[];
    lines.forEach(line=>{
        const p=line.split('|');
        if(p.length===3) reqs.push({name:p[0].trim(),listen:p[1].trim(),remote:p[2].trim(),protocol:'tcp'});
    });
    if(reqs.length===0) return alert('格式错误');
    const r=await fetch('/api/rules/batch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(reqs)});
    const d=await r.json();
    alert('成功导入 '+d.count+' 条');
    $('batchModal').style.display='none';
    load();
}
async function tog(id){await fetch(`/api/rules/${id}/toggle`,{method:'POST'});load()}
async function del(id){if(confirm('删除?'))await fetch(`/api/rules/${id}`,{method:'DELETE'});load()}
async function logout(){await fetch('/logout',{method:'POST'});location.href='/login'}
load();
</script></body></html>
"#.to_string()
}
EOF

# 5. 编译
echo -e "${CYAN}>>> 编译中 (请耐心等待！)...${RESET}"
/root/.cargo/bin/cargo clean
/root/.cargo/bin/cargo build --release

# 6. 部署
if [ -f "target/release/gost-panel" ]; then
    echo -e "${GREEN} [编译成功]${RESET}"
    systemctl stop gost-panel
    cp target/release/gost-panel "$BINARY_PATH"

    # 配置服务
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost v3 Core
After=network.target
[Service]
ExecStart=$GOST_BIN -C $GOST_CONFIG
Restart=always
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/gost-panel.service <<EOF
[Unit]
Description=Gost Panel (Monitor)
After=gost.service
[Service]
Environment="PANEL_PORT=$PANEL_PORT"
Environment="PANEL_USER=$DEFAULT_USER"
Environment="PANEL_PASS=$DEFAULT_PASS"
ExecStart=$BINARY_PATH
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    [ ! -f "$GOST_CONFIG" ] && echo '{"services":[],"chains":[]}' > $GOST_CONFIG
    systemctl enable gost gost-panel >/dev/null 2>&1
    systemctl restart gost gost-panel

    IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
    echo -e "${GREEN}✅ 安装完成！${RESET}"
    echo -e "地址: http://${IP}:${PANEL_PORT}"
    echo -e "账号: admin / 123456"
else
    echo -e "${RED}❌ 编译失败，请截图报错。${RESET}"
fi

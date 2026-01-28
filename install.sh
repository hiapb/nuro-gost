#!/bin/bash

# ==========================================
#   Gost v3 Pro 面板 (侧边栏架构 + 监控版)
# ==========================================

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

# --- 颜色定义 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- 进度条动画 ---
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

print_info() {
    echo -e "${CYAN}>>> $1 ${RESET}"
}

print_success() {
    echo -e "${GREEN}✅ $1 ${RESET}"
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请以 root 用户运行此脚本！${RESET}"
    exit 1
fi

clear
echo -e "${GREEN}==============================================${RESET}"
echo -e "${GREEN}      Gost v3 Pro 面板自动部署脚本           ${RESET}"
echo -e "${GREEN}   (集成: 侧边栏UI | 系统监控 | 批量管理)    ${RESET}"
echo -e "${GREEN}==============================================${RESET}"
echo ""

# ----------------------------------------------------------------
# 1. 环境清理与准备
# ----------------------------------------------------------------
print_info "正在清理旧环境..."
systemctl stop gost-panel gost >/dev/null 2>&1
rm -rf ~/.cargo/config ~/.cargo/config.toml
rm -rf /opt/gost_panel
print_success "环境清理完成"

print_info "正在检查并安装系统依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y build-essential gcc g++ libssl-dev pkg-config curl wget tar >/dev/null 2>&1 &
    spinner $!
elif [ -f /etc/redhat-release ]; then
    yum groupinstall -y 'Development Tools' >/dev/null 2>&1
    yum install -y openssl-devel gcc curl wget tar >/dev/null 2>&1 &
    spinner $!
fi
print_success "依赖安装完成"

# ----------------------------------------------------------------
# 2. 安装 Rust
# ----------------------------------------------------------------
if ! command -v cargo &> /dev/null; then
    print_info "正在安装 Rust 编译器 (官方源)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1 &
    spinner $!
    source "$HOME/.cargo/env"
    print_success "Rust 安装完成"
else
    print_success "Rust 已安装，跳过"
fi

# ----------------------------------------------------------------
# 3. 安装 Gost v3 核心
# ----------------------------------------------------------------
if ! command -v gost &> /dev/null; then
    print_info "正在下载 Gost v3 核心引擎..."
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
    print_success "Gost v3 安装完成"
else
    print_success "Gost v3 已安装，跳过"
fi

mkdir -p "$(dirname "$GOST_CONFIG")"

# ----------------------------------------------------------------
# 4. 生成面板源码 (分块写入防止截断)
# ----------------------------------------------------------------
print_info "正在生成面板源代码..."
mkdir -p "$WORK_DIR/src" "$WORK_DIR/.cargo"

# 修复链接器配置 (强制使用 gcc)
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
version = "2.3.0"
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

# 生成 main.rs 头部
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
struct AdminConfig { username: String, pass_hash: String, bg_pc: String }
#[derive(Serialize, Deserialize, Clone, Debug)]
struct AppData { admin: AdminConfig, rules: Vec<Rule> }
#[derive(Serialize)]
struct SystemStatus { cpu: f32, ram_used: u64, ram_total: u64, tx: u64, rx: u64 }
#[derive(Serialize)]
struct GostConfig { services: Vec<GostSvc>, chains: Vec<GostChain> }
#[derive(Serialize)]
struct GostSvc { name: String, addr: String, handler: GostHdl, listener: GostLsn }
#[derive(Serialize)]
struct GostHdl { #[serde(rename="type")] t: String, chain: String }
#[derive(Serialize)]
struct GostLsn { #[serde(rename="type")] t: String }
#[derive(Serialize)]
struct GostChain { name: String, hops: Vec<GostHop> }
#[derive(Serialize)]
struct GostHop { name: String, addr: String }

struct AppState { data: Mutex<AppData>, sys: Mutex<System>, nets: Mutex<Networks> }

#[tokio::main]
async fn main() {
    let init = load_data();
    let mut sys = System::new_with_specifics(RefreshKind::new().with_cpu(CpuRefreshKind::everything()).with_memory(MemoryRefreshKind::everything()));
    let mut nets = Networks::new_with_refreshed_list();
    std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL);
    sys.refresh_cpu(); sys.refresh_memory(); nets.refresh();
    
    let st = Arc::new(AppState { data: Mutex::new(init), sys: Mutex::new(sys), nets: Mutex::new(nets) });
    let app = Router::new().route("/", get(idx)).route("/login", get(pg_login).post(act_login))
        .route("/api/rules", get(get_r).post(add_r)).route("/api/rules/batch", post(bat_r))
        .route("/api/rules/:id", put(upd_r).delete(del_r)).route("/api/rules/:id/toggle", post(tog_r))
        .route("/api/status", get(get_s)).route("/logout", post(act_logout))
        .layer(CookieManagerLayer::new()).with_state(st);
    
    let p = std::env::var("PANEL_PORT").unwrap_or("9794".to_string());
    let l = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", p)).await.unwrap();
    axum::serve(l, app).await.unwrap();
}

fn load_data() -> AppData {
    if let Ok(c) = fs::read_to_string(DATA_FILE) { if let Ok(d) = serde_json::from_str::<AppData>(&c) { save_gost(&d); return d; } }
    let d = AppData { admin: AdminConfig { username: "admin".into(), pass_hash: "123456".into(), bg_pc: "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".into() }, rules: vec![] };
    save_json(&d); save_gost(&d); d
}
fn save_json(d: &AppData) { let _ = fs::write(DATA_FILE, serde_json::to_string_pretty(d).unwrap()); }
fn save_gost(d: &AppData) {
    let (mut svcs, mut chns) = (vec![], vec![]);
    for r in d.rules.iter().filter(|r| r.enabled) {
        let cn = format!("c-{}", r.id);
        chns.push(GostChain { name: cn.clone(), hops: vec![GostHop { name: format!("h-{}", r.id), addr: r.remote.clone() }] });
        let t = if r.protocol == "udp" { "udp" } else { "tcp" };
        svcs.push(GostSvc { name: format!("s-{}", r.id), addr: r.listen.clone(), handler: GostHdl { t: t.into(), chain: cn }, listener: GostLsn { t: t.into() } });
    }
    let _ = fs::write(GOST_CONFIG, serde_json::to_string_pretty(&GostConfig { services: svcs, chains: chns }).unwrap());
    let _ = Command::new("systemctl").arg("restart").arg("gost").status();
}
fn chk(c: &Cookies, s: &AppData) -> bool { if let Some(v) = c.get("auth_session") { v.value() == s.admin.pass_hash } else { false } }

async fn get_s(c: Cookies, State(s): State<Arc<AppState>>) -> Response {
    let d = s.data.lock().unwrap(); if !chk(&c, &d) { return StatusCode::UNAUTHORIZED.into_response() }
    let mut sys = s.sys.lock().unwrap(); let mut nets = s.nets.lock().unwrap();
    sys.refresh_cpu(); sys.refresh_memory(); nets.refresh();
    let (mut tx, mut rx) = (0, 0); for (_, v) in &*nets { tx += v.transmitted(); rx += v.received(); }
    Json(SystemStatus { cpu: sys.global_cpu_info().cpu_usage(), ram_used: sys.used_memory(), ram_total: sys.total_memory(), tx, rx }).into_response()
}

// 路由与逻辑
async fn idx(c: Cookies, State(s): State<Arc<AppState>>) -> Response {
    let d = s.data.lock().unwrap(); if !chk(&c, &d) { return axum::response::Redirect::to("/login").into_response() }
    Html(get_dash_html().replace("{U}", &d.admin.username)).into_response()
}
async fn pg_login(State(s): State<Arc<AppState>>) -> Response { Html(get_login_html().replace("{B}", &s.data.lock().unwrap().admin.bg_pc)).into_response() }
#[derive(Deserialize)] struct L { username: String, password: String }
async fn act_login(c: Cookies, State(s): State<Arc<AppState>>, Form(f): Form<L>) -> Response {
    let d = s.data.lock().unwrap(); if f.username == d.admin.username && f.password == d.admin.pass_hash {
        let mut k = Cookie::new("auth_session", d.admin.pass_hash.clone()); k.set_path("/"); c.add(k);
        axum::response::Redirect::to("/").into_response()
    } else { StatusCode::UNAUTHORIZED.into_response() }
}
async fn act_logout(c: Cookies) -> Response { let mut k = Cookie::new("auth_session", ""); k.set_path("/"); c.remove(k); Json("ok").into_response() }
async fn get_r(c: Cookies, State(s): State<Arc<AppState>>) -> Response { let d = s.data.lock().unwrap(); if !chk(&c, &d) { return StatusCode::UNAUTHORIZED.into_response() } Json(d.clone()).into_response() }
#[derive(Deserialize)] struct R { name: String, listen: String, remote: String, protocol: Option<String> }
async fn add_r(c: Cookies, State(s): State<Arc<AppState>>, Json(q): Json<R>) -> Response {
    let mut d = s.data.lock().unwrap(); if !chk(&c, &d) { return StatusCode::UNAUTHORIZED.into_response() }
    d.rules.push(Rule { id: uuid::Uuid::new_v4().to_string(), name: q.name, listen: q.listen, remote: q.remote, protocol: q.protocol.unwrap_or("tcp".into()), enabled: true });
    save_json(&d); save_gost(&d); Json("ok").into_response()
}
async fn bat_r(c: Cookies, State(s): State<Arc<AppState>>, Json(qs): Json<Vec<R>>) -> Response {
    let mut d = s.data.lock().unwrap(); if !chk(&c, &d) { return StatusCode::UNAUTHORIZED.into_response() }
    for q in qs { d.rules.push(Rule { id: uuid::Uuid::new_v4().to_string(), name: q.name, listen: q.listen, remote: q.remote, protocol: q.protocol.unwrap_or("tcp".into()), enabled: true }); }
    save_json(&d); save_gost(&d); Json("ok").into_response()
}
async fn upd_r(c: Cookies, State(s): State<Arc<AppState>>, Path(i): Path<String>, Json(q): Json<R>) -> Response {
    let mut d = s.data.lock().unwrap(); if !chk(&c, &d) { return StatusCode::UNAUTHORIZED.into_response() }
    if let Some(r) = d.rules.iter_mut().find(|x| x.id == i) { r.name = q.name; r.listen = q.listen; r.remote = q.remote; r.protocol = q.protocol.unwrap_or("tcp".into()); save_json(&d); save_gost(&d); }
    Json("ok").into_response()
}
async fn del_r(c: Cookies, State(s): State<Arc<AppState>>, Path(i): Path<String>) -> Response {
    let mut d = s.data.lock().unwrap(); if !chk(&c, &d) { return StatusCode::UNAUTHORIZED.into_response() }
    d.rules.retain(|x| x.id != i); save_json(&d); save_gost(&d); Json("ok").into_response()
}
async fn tog_r(c: Cookies, State(s): State<Arc<AppState>>, Path(i): Path<String>) -> Response {
    let mut d = s.data.lock().unwrap(); if !chk(&c, &d) { return StatusCode::UNAUTHORIZED.into_response() }
    if let Some(r) = d.rules.iter_mut().find(|x| x.id == i) { r.enabled = !r.enabled; save_json(&d); save_gost(&d); }
    Json("ok").into_response()
}

// HTML 部分单独封装防止截断
fn get_login_html() -> String {
    r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Login</title><style>body{margin:0;height:100vh;display:flex;justify-content:center;align-items:center;background:url('{B}') center/cover;font-family:system-ui}.b{background:rgba(255,255,255,0.9);padding:2rem;border-radius:12px;width:300px}input{width:100%;padding:10px;margin:8px 0;box-sizing:border-box}button{width:100%;padding:10px;background:#2563eb;color:#fff;border:none;cursor:pointer}</style></head><body><div class="b"><h3 style="text-align:center">Gost Pro Panel</h3><form onsubmit="L(event)"><input id="u"><input id="p" type="password"><button>Login</button></form></div><script>async function L(e){e.preventDefault();await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${document.getElementById('u').value}&password=${document.getElementById('p').value}`}).then(r=>{if(r.redirected)location.href='/';else alert('Fail')})}</script></body></html>"#.to_string()
}
EOF

# 生成 main.rs 尾部 (HTML)
# 这里使用追加 (>>) 模式，把大段 HTML 独立写入
cat >> src/main.rs << 'EOF'
fn get_dash_html() -> String {
    r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Gost Pro</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
<style>:root{--w:220px;--p:#2563eb;--bg:#f3f4f6}body{margin:0;display:flex;height:100vh;font-family:system-ui;background:var(--bg)}.sb{width:var(--w);background:#1f2937;color:#fff;display:flex;flex-direction:column;flex-shrink:0}.br{padding:20px;font-weight:bold;font-size:1.2rem;border-bottom:1px solid #374151}.mn{flex:1;padding:20px 0}.mi{padding:12px 24px;cursor:pointer;display:flex;gap:10px;color:#9ca3af;transition:.2s;align-items:center}.mi:hover,.mi.act{background:#111827;color:#fff;border-right:3px solid var(--p)}.main{flex:1;display:flex;flex-direction:column;overflow:hidden}.hd{background:#fff;padding:15px 30px;border-bottom:1px solid #e5e7eb;display:flex;justify-content:space-between;align-items:center}.cnt{flex:1;overflow:auto;padding:30px}.sec{display:none;animation:F .3s}.sec.act{display:block}@keyframes F{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:translateY(0)}}.cd{background:#fff;border-radius:10px;padding:20px;box-shadow:0 1px 3px rgba(0,0,0,.1);margin-bottom:20px}.gr{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:20px;margin-bottom:30px}.bx{background:#fff;padding:20px;border-radius:10px;display:flex;gap:15px;align-items:center;box-shadow:0 1px 3px rgba(0,0,0,.1)}.ic{width:50px;height:50px;border-radius:10px;display:flex;justify-content:center;align-items:center;font-size:1.5rem}table{width:100%;border-collapse:collapse}td,th{padding:12px;text-align:left;border-bottom:1px solid #f3f4f6}.dt{height:8px;width:8px;border-radius:50%;display:inline-block;margin-right:6px;background:#ccc}.dt.on{background:#10b981;box-shadow:0 0 5px #10b981}input,select,textarea{padding:10px;border:1px solid #d1d5db;border-radius:6px;outline:none}.btn{padding:8px 16px;border-radius:6px;border:none;cursor:pointer;color:#fff;font-weight:500}.bp{background:var(--p)}.bd{background:#ef4444}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.5);z-index:99;justify-content:center;align-items:center}.mb{background:#fff;padding:25px;border-radius:12px;width:500px}@media(max-width:768px){.sb{display:none}}</style></head><body>
<div class="sb"><div class="br"><i class="fas fa-network-wired"></i> Gost Pro</div><div class="mn"><div class="mi act" onclick="N('db',this)"><i class="fas fa-chart-pie"></i> Dashboard</div><div class="mi" onclick="N('rl',this)"><i class="fas fa-list"></i> Rules</div><div class="mi" onclick="N('nd',this)"><i class="fas fa-server"></i> Nodes</div><div class="mi" onclick="N('st',this)"><i class="fas fa-cog"></i> Settings</div></div><div style="padding:20px"><button class="btn bd" style="width:100%" onclick="LO()">Logout</button></div></div>
<div class="main"><div class="hd"><h3 id="pt" style="margin:0">Dashboard</h3><span style="color:#666;font-size:0.9rem">Port: 9794</span></div><div class="cnt">
<div id="db" class="sec act"><div class="gr"><div class="bx"><div class="ic" style="background:#eff6ff;color:#2563eb"><i class="fas fa-microchip"></i></div><div><div style="color:#666">CPU</div><div id="c" style="font-size:1.4rem;font-weight:bold">0%</div></div></div><div class="bx"><div class="ic" style="background:#fdf4ff;color:#d946ef"><i class="fas fa-memory"></i></div><div><div style="color:#666">RAM</div><div id="m" style="font-size:1.4rem;font-weight:bold">0/0</div></div></div><div class="bx"><div class="ic" style="background:#ecfdf5;color:#10b981"><i class="fas fa-arrow-down"></i></div><div><div style="color:#666">Inbound</div><div id="rx" style="font-size:1.4rem;font-weight:bold">0/s</div></div></div><div class="bx"><div class="ic" style="background:#fef2f2;color:#ef4444"><i class="fas fa-arrow-up"></i></div><div><div style="color:#666">Outbound</div><div id="tx" style="font-size:1.4rem;font-weight:bold">0/s</div></div></div></div><div class="cd"><h4>System Overview</h4>Status: <b>Online</b></div></div>
<div id="rl" class="sec"><div class="cd"><div style="display:flex;gap:10px;margin-bottom:15px"><input id="rn" placeholder="Name" style="flex:1"><input id="rl_p" placeholder=":Port" style="width:100px"><input id="rr" placeholder="IP:Port" style="flex:2"><select id="rt" style="width:100px"><option value="tcp">TCP</option><option value="udp">UDP</option></select><button class="btn bp" onclick="A()">Add</button><button class="btn" style="background:#f59e0b" onclick="$('bm').style.display='flex'">Batch</button></div><table><thead><tr><th>St</th><th>Name</th><th>Listen</th><th>Proto</th><th>Target</th><th>Op</th></tr></thead><tbody id="ls"></tbody></table></div></div>
<div id="nd" class="sec"><div class="cd" style="text-align:center;padding:50px;color:#9ca3af"><i class="fas fa-server" style="font-size:3rem;margin-bottom:20px"></i><h3>Nodes Management</h3>(Under Development)</div></div>
<div id="st" class="sec"><div class="cd"><h3>Info</h3>User: {U}<br>Gost: v3.0.0</div></div>
</div></div>
<div id="bm" class="modal"><div class="mb"><h3>Batch Import</h3><textarea id="bi" rows="10" style="width:100%;font-family:monospace;margin:10px 0" placeholder="Name|:Port|IP:Port"></textarea><div style="text-align:right;gap:10px"><button class="btn" style="background:#999;margin-right:10px" onclick="$('bm').style.display='none'">Cancel</button><button class="btn bp" onclick="B()">Import</button></div></div></div>
<script>
const $=i=>document.getElementById(i);const F=b=>{if(!b)return'0 B';const k=1024,s=['B','K','M','G'],i=Math.floor(Math.log(b)/Math.log(k));return parseFloat((b/Math.pow(k,i)).toFixed(1))+s[i]};
function N(i,e){document.querySelectorAll('.sec').forEach(x=>x.classList.remove('act'));document.querySelectorAll('.mi').forEach(x=>x.classList.remove('act'));$(i).classList.add('act');e.classList.add('act');$('pt').innerText=e.innerText}
async function S(){try{let r=await fetch('/api/status');if(r.ok){let d=await r.json();$('c').innerText=d.cpu.toFixed(1)+'%';$('m').innerText=F(d.ram_used)+'/'+F(d.ram_total);$('tx').innerText=F(d.tx)+'/s';$('rx').innerText=F(d.rx)+'/s'}}catch{}}
setInterval(S,2000);S();
async function R(){let r=await fetch('/api/rules');if(r.status==401)location.href='/login';let d=await r.json();let h='';d.rules.forEach(x=>{h+=`<tr><td><div class="dt ${x.enabled?'on':''}"></div></td><td>${x.name}</td><td>${x.listen}</td><td>${x.protocol}</td><td>${x.remote}</td><td><button class="btn" style="background:#9ca3af;font-size:0.8rem;margin-right:5px" onclick="T('${x.id}')"><i class="fas fa-power-off"></i></button><button class="btn bd" style="font-size:0.8rem" onclick="D('${x.id}')"><i class="fas fa-trash"></i></button></td></tr>`});$('ls').innerHTML=h}
if(location.pathname=='/')R();
async function A(){let n=$('rn').value,l=$('rl_p').value,r=$('rr').value,t=$('rt').value;if(!n||!l||!r)return;await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r,protocol:t})});R();$('rn').value=''}
async function B(){let t=$('bi').value.trim();if(!t)return;let q=t.split('\n').map(x=>x.split('|')).filter(x=>x.length==3).map(x=>({name:x[0],listen:x[1],remote:x[2],protocol:'tcp'}));await fetch('/api/rules/batch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(q)});$('bm').style.display='none';R()}
async function T(i){await fetch(`/api/rules/${i}/toggle`,{method:'POST'});R()}
async function D(i){if(confirm('Del?'))await fetch(`/api/rules/${i}`,{method:'DELETE'});R()}
async function LO(){await fetch('/logout',{method:'POST'});location.reload()}
</script></body></html>"#.to_string()
}
EOF

# ----------------------------------------------------------------
# 5. 编译与部署
# ----------------------------------------------------------------
print_info "正在编译 Pro 面板 (请耐心等待)..."
# 强制刷新环境
/root/.cargo/bin/cargo clean
/root/.cargo/bin/cargo build --release >/dev/null 2>&1

if [ ! -f "target/release/gost-panel" ]; then
    echo -e "${RED}编译失败！请检查上方报错信息。${RESET}"
    exit 1
fi
print_success "编译成功"

print_info "正在部署服务..."
systemctl stop gost-panel >/dev/null 2>&1
cp target/release/gost-panel "$BINARY_PATH"

# 写入 Systemd 服务
cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost v3 Core Engine
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
Description=Gost v3 Pro Panel
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
# 初始化空配置
if [ ! -f "$GOST_CONFIG" ]; then
    mkdir -p /etc/gost
    echo '{"services":[],"chains":[]}' > $GOST_CONFIG
fi

systemctl enable gost gost-panel >/dev/null 2>&1
systemctl restart gost gost-panel

# ----------------------------------------------------------------
# 6. 完成
# ----------------------------------------------------------------
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}==============================================${RESET}"
echo -e "${GREEN}      🎉 Gost v3 Pro 面板部署成功！          ${RESET}"
echo -e "${GREEN}==============================================${RESET}"
echo -e " 💻 访问地址 : http://${IP}:${PANEL_PORT}"
echo -e " 👤 默认账号 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e " 🔑 默认密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "${GREEN}==============================================${RESET}"

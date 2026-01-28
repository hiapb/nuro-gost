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

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行！${RESET}"
    exit 1
fi

clear
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}   Gost v3 面板 (精简修复版)   ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 1. 环境清理与准备
echo -e -n "${CYAN}>>> 清理旧环境...${RESET}"
rm -rf ~/.cargo/config ~/.cargo/config.toml /opt/gost_panel
systemctl stop gost-panel >/dev/null 2>&1
echo -e "${GREEN} [完成]${RESET}"

echo -e -n "${CYAN}>>> 安装依赖...${RESET}"
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

# 3. Gost v3
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
echo -e "${CYAN}>>> 生成 Rust 源码...${RESET}"
mkdir -p "$WORK_DIR/src" "$WORK_DIR/.cargo"

# 修复链接器配置
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
version = "2.2.0"
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

# 注意：这里使用了压缩后的 HTML 以防止复制截断
cat > src/main.rs << 'EOF'
use axum::{extract::{State,Path},http::StatusCode,response::{Html,IntoResponse,Response},routing::{get,post,put,delete},Json,Router,Form};
use serde::{Deserialize,Serialize};
use std::{fs,process::Command,sync::{Arc,Mutex}};
use tower_cookies::{Cookie,Cookies,CookieManagerLayer};
use sysinfo::{Networks,RefreshKind};

const GOST_CONFIG:&str="/etc/gost/config.json";
const DATA_FILE:&str="/etc/gost/panel_data.json";

#[derive(Serialize,Deserialize,Clone,Debug)] struct Rule { id:String,name:String,listen:String,remote:String,protocol:String,enabled:bool }
#[derive(Serialize,Deserialize,Clone,Debug)] struct AdminConfig { username:String,pass_hash:String,bg_pc:String }
#[derive(Serialize,Deserialize,Clone,Debug)] struct AppData { admin:AdminConfig,rules:Vec<Rule> }
#[derive(Serialize)] struct DashboardStats { total:usize,active:usize,tx:u64,rx:u64 }
#[derive(Serialize)] struct GostConfig { services:Vec<GostSvc>,chains:Vec<GostChain> }
#[derive(Serialize)] struct GostSvc { name:String,addr:String,handler:GostHdl,listener:GostLsn }
#[derive(Serialize)] struct GostHdl { #[serde(rename="type")] t:String,chain:String }
#[derive(Serialize)] struct GostLsn { #[serde(rename="type")] t:String }
#[derive(Serialize)] struct GostChain { name:String,hops:Vec<GostHop> }
#[derive(Serialize)] struct GostHop { name:String,addr:String }

struct AppState { data:Mutex<AppData>,nets:Mutex<Networks> }

#[tokio::main]
async fn main() {
    let init=load_data();
    let mut n=Networks::new_with_refreshed_list(); n.refresh();
    let st=Arc::new(AppState{data:Mutex::new(init),nets:Mutex::new(n)});
    let app=Router::new().route("/",get(idx)).route("/login",get(pg_login).post(act_login))
        .route("/api/rules",get(get_r).post(add_r)).route("/api/rules/batch",post(bat_r))
        .route("/api/rules/:id",put(upd_r).delete(del_r)).route("/api/rules/:id/toggle",post(tog_r))
        .route("/api/stats",get(get_s)).route("/logout",post(act_logout))
        .layer(CookieManagerLayer::new()).with_state(st);
    let p=std::env::var("PANEL_PORT").unwrap_or("9794".to_string());
    let l=tokio::net::TcpListener::bind(format!("0.0.0.0:{}",p)).await.unwrap();
    axum::serve(l,app).await.unwrap();
}

fn load_data()->AppData{
    if let Ok(c)=fs::read_to_string(DATA_FILE){if let Ok(d)=serde_json::from_str::<AppData>(&c){save_gost(&d);return d;}}
    let d=AppData{admin:AdminConfig{username:"admin".into(),pass_hash:"123456".into(),bg_pc:"https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".into()},rules:vec![]};
    save_json(&d); save_gost(&d); d
}
fn save_json(d:&AppData){let _=fs::write(DATA_FILE,serde_json::to_string_pretty(d).unwrap());}
fn save_gost(d:&AppData){
    let (mut svcs,mut chns)=(vec![],vec![]);
    for r in d.rules.iter().filter(|r|r.enabled){
        let cn=format!("c-{}",r.id);
        chns.push(GostChain{name:cn.clone(),hops:vec![GostHop{name:format!("h-{}",r.id),addr:r.remote.clone()}]});
        let t=if r.protocol=="udp"{"udp"}else{"tcp"};
        svcs.push(GostSvc{name:format!("s-{}",r.id),addr:r.listen.clone(),handler:GostHdl{t:t.into(),chain:cn},listener:GostLsn{t:t.into()}});
    }
    let _=fs::write(GOST_CONFIG,serde_json::to_string_pretty(&GostConfig{services:svcs,chains:chns}).unwrap());
    let _=Command::new("systemctl").arg("restart").arg("gost").status();
}
fn chk(c:&Cookies,s:&AppData)->bool{if let Some(v)=c.get("auth_session"){v.value()==s.admin.pass_hash}else{false}}

async fn get_s(c:Cookies,State(s):State<Arc<AppState>>)->Response{
    let d=s.data.lock().unwrap(); if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}
    let mut n=s.nets.lock().unwrap(); n.refresh();
    let (mut t,mut r)=(0,0); for(_,v)in&*n{t+=v.transmitted();r+=v.received();}
    Json(DashboardStats{total:d.rules.len(),active:d.rules.iter().filter(|x|x.enabled).count(),tx:t,rx:r}).into_response()
}
async fn idx(c:Cookies,State(s):State<Arc<AppState>>)->Response{
    let d=s.data.lock().unwrap(); if!chk(&c,&d){return axum::response::Redirect::to("/login").into_response()}
    Html(DASH_HTML.replace("{U}",&d.admin.username).replace("{B}",&d.admin.bg_pc)).into_response()
}
async fn pg_login(State(s):State<Arc<AppState>>)->Response{Html(LOGIN_HTML.replace("{B}",&s.data.lock().unwrap().admin.bg_pc)).into_response()}
#[derive(Deserialize)] struct L{username:String,password:String}
async fn act_login(c:Cookies,State(s):State<Arc<AppState>>,Form(f):Form<L>)->Response{
    let d=s.data.lock().unwrap(); if f.username==d.admin.username&&f.password==d.admin.pass_hash{
        let mut k=Cookie::new("auth_session",d.admin.pass_hash.clone());k.set_path("/");c.add(k);
        axum::response::Redirect::to("/").into_response()
    }else{StatusCode::UNAUTHORIZED.into_response()}
}
async fn act_logout(c:Cookies)->Response{let mut k=Cookie::new("auth_session","");k.set_path("/");c.remove(k);Json("ok").into_response()}

async fn get_r(c:Cookies,State(s):State<Arc<AppState>>)->Response{let d=s.data.lock().unwrap();if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}Json(d.clone()).into_response()}
#[derive(Deserialize)] struct R{name:String,listen:String,remote:String,protocol:Option<String>}
async fn add_r(c:Cookies,State(s):State<Arc<AppState>>,Json(q):Json<R>)->Response{
    let mut d=s.data.lock().unwrap(); if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}
    d.rules.push(Rule{id:uuid::Uuid::new_v4().to_string(),name:q.name,listen:q.listen,remote:q.remote,protocol:q.protocol.unwrap_or("tcp".into()),enabled:true});
    save_json(&d);save_gost(&d);Json("ok").into_response()
}
async fn bat_r(c:Cookies,State(s):State<Arc<AppState>>,Json(qs):Json<Vec<R>>)->Response{
    let mut d=s.data.lock().unwrap(); if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}
    for q in qs{d.rules.push(Rule{id:uuid::Uuid::new_v4().to_string(),name:q.name,listen:q.listen,remote:q.remote,protocol:q.protocol.unwrap_or("tcp".into()),enabled:true});}
    save_json(&d);save_gost(&d);Json("ok").into_response()
}
async fn upd_r(c:Cookies,State(s):State<Arc<AppState>>,Path(i):Path<String>,Json(q):Json<R>)->Response{
    let mut d=s.data.lock().unwrap(); if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}
    if let Some(r)=d.rules.iter_mut().find(|x|x.id==i){r.name=q.name;r.listen=q.listen;r.remote=q.remote;r.protocol=q.protocol.unwrap_or("tcp".into());save_json(&d);save_gost(&d);}
    Json("ok").into_response()
}
async fn del_r(c:Cookies,State(s):State<Arc<AppState>>,Path(i):Path<String>)->Response{
    let mut d=s.data.lock().unwrap(); if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}
    d.rules.retain(|x|x.id!=i);save_json(&d);save_gost(&d);Json("ok").into_response()
}
async fn tog_r(c:Cookies,State(s):State<Arc<AppState>>,Path(i):Path<String>)->Response{
    let mut d=s.data.lock().unwrap(); if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}
    if let Some(r)=d.rules.iter_mut().find(|x|x.id==i){r.enabled=!r.enabled;save_json(&d);save_gost(&d);}
    Json("ok").into_response()
}

const LOGIN_HTML:&str=r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Login</title><style>body{margin:0;height:100vh;display:flex;justify-content:center;align-items:center;background:url('{B}') center/cover;font-family:system-ui}.b{background:rgba(255,255,255,0.9);padding:2rem;border-radius:12px;width:300px}input{width:100%;padding:10px;margin:8px 0;box-sizing:border-box}button{width:100%;padding:10px;background:#2563eb;color:#fff;border:none;cursor:pointer}</style></head><body><div class="b"><h3 style="text-align:center">Gost Panel</h3><form onsubmit="L(event)"><input id="u"><input id="p" type="password"><button>Login</button></form></div><script>async function L(e){e.preventDefault();await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${document.getElementById('u').value}&password=${document.getElementById('p').value}`}).then(r=>{if(r.redirected)location.href='/';else alert('Fail')})}</script></body></html>"#;

const DASH_HTML:&str=r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Gost Pro</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"><style>:root{--w:220px;--p:#2563eb;--bg:#f3f4f6}body{margin:0;display:flex;height:100vh;font-family:system-ui;background:var(--bg)}.sb{width:var(--w);background:#1f2937;color:#fff;display:flex;flex-direction:column}.br{padding:20px;font-weight:bold;border-bottom:1px solid #374151}.mn{flex:1;padding:20px 0}.mi{padding:12px 24px;cursor:pointer;display:flex;gap:10px;color:#9ca3af;transition:.2s}.mi:hover,.mi.act{background:#111827;color:#fff;border-right:3px solid var(--p)}.main{flex:1;display:flex;flex-direction:column;overflow:hidden}.hd{background:#fff;padding:15px;border-bottom:1px solid #e5e7eb;display:flex;justify-content:space-between}.cnt{flex:1;overflow:auto;padding:20px}.sec{display:none}.sec.act{display:block}.cd{background:#fff;border-radius:8px;padding:20px;box-shadow:0 1px 3px rgba(0,0,0,.1);margin-bottom:20px}.gr{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px}.bx{background:#fff;padding:15px;border-radius:8px;display:flex;gap:15px;align-items:center;box-shadow:0 1px 3px rgba(0,0,0,.1)}.ic{width:45px;height:45px;border-radius:8px;display:flex;justify-content:center;align-items:center;font-size:1.4rem}table{width:100%;border-collapse:collapse}td,th{padding:10px;text-align:left;border-bottom:1px solid #eee}.dt{height:8px;width:8px;border-radius:50%;display:inline-block;margin-right:5px;background:#ccc}.dt.on{background:#10b981}input,select{padding:8px;border:1px solid #ccc;border-radius:4px}.btn{padding:8px 12px;border:none;border-radius:4px;cursor:pointer;color:#fff}.bp{background:var(--p)}.bd{background:#ef4444}@media(max-width:768px){.sb{display:none}}</style></head><body><div class="sb"><div class="br">Gost Pro</div><div class="mn"><div class="mi act" onclick="N('db',this)"><i class="fas fa-chart-line"></i> Dashboard</div><div class="mi" onclick="N('rl',this)"><i class="fas fa-exchange-alt"></i> Rules</div><div class="mi" onclick="N('nd',this)"><i class="fas fa-server"></i> Nodes</div></div><div style="padding:20px"><button class="btn bd" style="width:100%" onclick="LO()">Logout</button></div></div><div class="main"><div class="hd"><b>Dashboard</b><span>9794</span></div><div class="cnt"><div id="db" class="sec act"><div class="gr"><div class="bx"><div class="ic" style="background:#e0f2fe;color:#0ea5e9"><i class="fas fa-list"></i></div><div><div style="color:#666">Total</div><div id="s_t" style="font-size:1.2rem;font-weight:bold">0</div></div></div><div class="bx"><div class="ic" style="background:#dcfce7;color:#22c55e"><i class="fas fa-check"></i></div><div><div style="color:#666">Active</div><div id="s_a" style="font-size:1.2rem;font-weight:bold">0</div></div></div><div class="bx"><div class="ic" style="background:#fef9c3;color:#eab308"><i class="fas fa-arrow-down"></i></div><div><div style="color:#666">RX</div><div id="s_r" style="font-size:1.2rem;font-weight:bold">0</div></div></div><div class="bx"><div class="ic" style="background:#fee2e2;color:#ef4444"><i class="fas fa-arrow-up"></i></div><div><div style="color:#666">TX</div><div id="s_x" style="font-size:1.2rem;font-weight:bold">0</div></div></div></div><br><div class="cd">Welcome {U}</div></div><div id="rl" class="sec"><div class="cd"><div style="display:flex;gap:10px;margin-bottom:15px"><input id="n" placeholder="Name" style="flex:1"><input id="l" placeholder=":Port" style="width:80px"><input id="r" placeholder="IP:Port" style="flex:2"><select id="p"><option value="tcp">TCP</option><option value="udp">UDP</option></select><button class="btn bp" onclick="A()">Add</button></div><table><thead><tr><th>St</th><th>Name</th><th>Listen</th><th>Proto</th><th>Target</th><th>Op</th></tr></thead><tbody id="ls"></tbody></table></div></div><div id="nd" class="sec"><div class="cd" style="text-align:center;padding:40px;color:#999"><h3>Node Management</h3>Coming Soon...</div></div></div></div><script>const $=i=>document.getElementById(i);const F=b=>{if(!b)return'0';const k=1024,s=['B','K','M','G'],i=Math.floor(Math.log(b)/Math.log(k));return parseFloat((b/Math.pow(k,i)).toFixed(1))+s[i]};function N(i,e){document.querySelectorAll('.sec').forEach(x=>x.classList.remove('act'));document.querySelectorAll('.mi').forEach(x=>x.classList.remove('act'));$(i).classList.add('act');e.classList.add('act')}async function S(){try{let r=await fetch('/api/stats');if(r.ok){let d=await r.json();$('s_t').innerText=d.total;$('s_a').innerText=d.active;$('s_x').innerText=F(d.tx)+'/s';$('s_r').innerText=F(d.rx)+'/s'}}catch{}}setInterval(S,2000);S();async function R(){let r=await fetch('/api/rules');if(r.status==401)location.href='/login';let d=await r.json();let h='';d.rules.forEach(x=>{h+=`<tr><td><div class="dt ${x.enabled?'on':''}"></div></td><td>${x.name}</td><td>${x.listen}</td><td>${x.protocol}</td><td>${x.remote}</td><td><button class="btn" style="background:#999;font-size:0.8rem" onclick="T('${x.id}')">T</button> <button class="btn bd" style="font-size:0.8rem" onclick="D('${x.id}')">D</button></td></tr>`});$('ls').innerHTML=h}if(location.pathname=='/')R();async function A(){let n=$('n').value,l=$('l').value,r=$('r').value,p=$('p').value;if(!n||!l||!r)return;await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r,protocol:p})});R();$('n').value=''}async function T(i){await fetch(`/api/rules/${i}/toggle`,{method:'POST'});R()}async function D(i){if(confirm('Del?'))await fetch(`/api/rules/${i}`,{method:'DELETE'});R()}async function LO(){await fetch('/logout',{method:'POST'});location.reload()}</script></body></html>"#;
EOF

# 5. 编译
echo -e "${CYAN}>>> 编译中...${RESET}"
/root/.cargo/bin/cargo clean
/root/.cargo/bin/cargo build --release

if [ ! -f "target/release/gost-panel" ]; then
    echo -e "${RED}编译失败！${RESET}"
    exit 1
fi
echo -e "${GREEN} [编译成功]${RESET}"
cp target/release/gost-panel "$BINARY_PATH"

# 6. 配置服务
cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost Core
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
Description=Gost Panel
After=gost.service
[Service]
Environment="PANEL_PORT=$PANEL_PORT"
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

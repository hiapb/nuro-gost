#!/bin/bash

# =========================================================
#   Gost v3 面板管理脚本 (轻量版 + 菜单管理)
# =========================================================

# --- 基础配置 ---
GOST_BIN="/usr/local/bin/gost"
GOST_CONFIG="/etc/gost/config.json"
WORK_DIR="/opt/gost_panel"
BINARY_PATH="/usr/local/bin/gost-panel"
DATA_FILE="/etc/gost/panel_data.json"
LOG_FILE="/tmp/gost_install.log"

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

print_info() { echo -e "${CYAN}>>> $1${RESET}"; }
print_ok() { echo -e "${GREEN}✅ $1${RESET}"; }
print_err() { echo -e "${RED}❌ $1${RESET}"; }

# =========================================================
#   功能模块 1: 安装面板 (轻量版核心)
# =========================================================
install_panel() {
    clear
    echo -e "${GREEN}正在安装 Gost v3 面板...${RESET}"
    
    # 1. 清理
    print_info "清理旧环境..."
    systemctl stop gost-panel gost >/dev/null 2>&1
    rm -rf ~/.cargo/config ~/.cargo/config.toml /opt/gost_panel
    rm -f "$LOG_FILE"

    # 2. 依赖
    print_info "安装系统依赖..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y build-essential gcc g++ libssl-dev pkg-config curl wget tar >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum groupinstall -y 'Development Tools' >/dev/null 2>&1
        yum install -y openssl-devel gcc curl wget tar >/dev/null 2>&1
    fi

    # 3. Rust
    if ! command -v cargo &> /dev/null; then
        print_info "安装 Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1
        source "$HOME/.cargo/env"
    fi

    # 4. Gost Bin
    if ! command -v gost &> /dev/null; then
        print_info "安装 Gost v3..."
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
    fi
    mkdir -p "$(dirname "$GOST_CONFIG")"

    # 5. 生成源码 (轻量版，无sysinfo)
    print_info "生成面板源码..."
    mkdir -p "$WORK_DIR/src" "$WORK_DIR/.cargo"

    # 修复链接器
    cat > "$WORK_DIR/.cargo/config.toml" <<EOF
[target.x86_64-unknown-linux-gnu]
linker = "gcc"
[target.aarch64-unknown-linux-gnu]
linker = "gcc"
EOF

    cd "$WORK_DIR"
    
    # 依赖配置 (不包含 sysinfo)
    cat > Cargo.toml <<EOF
[package]
name = "gost-panel"
version = "1.0.0"
edition = "2021"
[dependencies]
axum = { version = "0.7", features = ["macros"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tower-cookies = "0.10"
anyhow = "1.0"
uuid = { version = "1", features = ["v4"] }
EOF

    # 写入 Rust 逻辑代码
    cat > src/main.rs << 'EOF'
use axum::{extract::{State,Path},http::StatusCode,response::{Html,IntoResponse,Response},routing::{get,post,put,delete},Json,Router,Form};
use serde::{Deserialize,Serialize};
use std::{fs,process::Command,sync::{Arc,Mutex}};
use tower_cookies::{Cookie,Cookies,CookieManagerLayer};
const GOST_CONFIG:&str="/etc/gost/config.json";const DATA_FILE:&str="/etc/gost/panel_data.json";
#[derive(Serialize,Deserialize,Clone,Debug)] struct Rule{id:String,name:String,listen:String,remote:String,protocol:String,enabled:bool}
#[derive(Serialize,Deserialize,Clone,Debug)] struct AdminConfig{username:String,pass_hash:String,bg_pc:String}
#[derive(Serialize,Deserialize,Clone,Debug)] struct AppData{admin:AdminConfig,rules:Vec<Rule>}
#[derive(Serialize)] struct GConf{services:Vec<GSvc>,chains:Vec<GChn>}
#[derive(Serialize)] struct GSvc{name:String,addr:String,handler:GHdl,listener:GLsn}
#[derive(Serialize)] struct GHdl{#[serde(rename="type")] t:String,chain:String}
#[derive(Serialize)] struct GLsn{#[serde(rename="type")] t:String}
#[derive(Serialize)] struct GChn{name:String,hops:Vec<GHop>}
#[derive(Serialize)] struct GHop{name:String,addr:String}
struct AppState{data:Mutex<AppData>}
#[tokio::main] async fn main(){
 let init=load_data();
 let st=Arc::new(AppState{data:Mutex::new(init)});
 let app=Router::new().route("/",get(idx)).route("/login",get(pg_login).post(act_login)).route("/api/rules",get(get_r).post(add_r)).route("/api/rules/batch",post(bat_r)).route("/api/rules/:id",put(upd_r).delete(del_r)).route("/api/rules/:id/toggle",post(tog_r)).route("/logout",post(act_logout)).layer(CookieManagerLayer::new()).with_state(st);
 let p=std::env::var("PANEL_PORT").unwrap_or("9794".to_string());
 let l=tokio::net::TcpListener::bind(format!("0.0.0.0:{}",p)).await.unwrap();
 axum::serve(l,app).await.unwrap();
}
fn load_data()->AppData{if let Ok(c)=fs::read_to_string(DATA_FILE){if let Ok(d)=serde_json::from_str::<AppData>(&c){save_gost(&d);return d;}}let d=AppData{admin:AdminConfig{username:"admin".into(),pass_hash:"123456".into(),bg_pc:"https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg".into()},rules:vec![]};save_json(&d);save_gost(&d);d}
fn save_json(d:&AppData){let _=fs::write(DATA_FILE,serde_json::to_string_pretty(d).unwrap());}
fn save_gost(d:&AppData){let(mut svcs,mut chns)=(vec![],vec![]);for r in d.rules.iter().filter(|r|r.enabled){let cn=format!("c-{}",r.id);chns.push(GChn{name:cn.clone(),hops:vec![GHop{name:format!("h-{}",r.id),addr:r.remote.clone()}]});let t=if r.protocol=="udp"{"udp"}else{"tcp"};svcs.push(GSvc{name:format!("s-{}",r.id),addr:r.listen.clone(),handler:GHdl{t:t.into(),chain:cn},listener:GLsn{t:t.into()}});}let _=fs::write(GOST_CONFIG,serde_json::to_string_pretty(&GConf{services:svcs,chains:chns}).unwrap());let _=Command::new("systemctl").arg("restart").arg("gost").status();}
fn chk(c:&Cookies,s:&AppData)->bool{if let Some(v)=c.get("auth_session"){v.value()==s.admin.pass_hash}else{false}}
async fn idx(c:Cookies,State(s):State<Arc<AppState>>)->Response{let d=s.data.lock().unwrap();if!chk(&c,&d){return axum::response::Redirect::to("/login").into_response()}Html(D_HTM.replace("{U}",&d.admin.username)).into_response()}
async fn pg_login(State(s):State<Arc<AppState>>)->Response{Html(L_HTM.replace("{B}",&s.data.lock().unwrap().admin.bg_pc)).into_response()}
#[derive(Deserialize)]struct L{username:String,password:String}
async fn act_login(c:Cookies,State(s):State<Arc<AppState>>,Form(f):Form<L>)->Response{let d=s.data.lock().unwrap();if f.username==d.admin.username&&f.password==d.admin.pass_hash{let mut k=Cookie::new("auth_session",d.admin.pass_hash.clone());k.set_path("/");c.add(k);axum::response::Redirect::to("/").into_response()}else{StatusCode::UNAUTHORIZED.into_response()}}
async fn act_logout(c:Cookies)->Response{let mut k=Cookie::new("auth_session","");k.set_path("/");c.remove(k);Json("ok").into_response()}
async fn get_r(c:Cookies,State(s):State<Arc<AppState>>)->Response{let d=s.data.lock().unwrap();if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}Json(d.clone()).into_response()}
#[derive(Deserialize)]struct R{name:String,listen:String,remote:String,protocol:Option<String>}
async fn add_r(c:Cookies,State(s):State<Arc<AppState>>,Json(q):Json<R>)->Response{let mut d=s.data.lock().unwrap();if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}d.rules.push(Rule{id:uuid::Uuid::new_v4().to_string(),name:q.name,listen:q.listen,remote:q.remote,protocol:q.protocol.unwrap_or("tcp".into()),enabled:true});save_json(&d);save_gost(&d);Json("ok").into_response()}
async fn bat_r(c:Cookies,State(s):State<Arc<AppState>>,Json(qs):Json<Vec<R>>)->Response{let mut d=s.data.lock().unwrap();if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}for q in qs{d.rules.push(Rule{id:uuid::Uuid::new_v4().to_string(),name:q.name,listen:q.listen,remote:q.remote,protocol:q.protocol.unwrap_or("tcp".into()),enabled:true});}save_json(&d);save_gost(&d);Json("ok").into_response()}
async fn upd_r(c:Cookies,State(s):State<Arc<AppState>>,Path(i):Path<String>,Json(q):Json<R>)->Response{let mut d=s.data.lock().unwrap();if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}if let Some(r)=d.rules.iter_mut().find(|x|x.id==i){r.name=q.name;r.listen=q.listen;r.remote=q.remote;r.protocol=q.protocol.unwrap_or("tcp".into());save_json(&d);save_gost(&d);}Json("ok").into_response()}
async fn del_r(c:Cookies,State(s):State<Arc<AppState>>,Path(i):Path<String>)->Response{let mut d=s.data.lock().unwrap();if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}d.rules.retain(|x|x.id!=i);save_json(&d);save_gost(&d);Json("ok").into_response()}
async fn tog_r(c:Cookies,State(s):State<Arc<AppState>>,Path(i):Path<String>)->Response{let mut d=s.data.lock().unwrap();if!chk(&c,&d){return StatusCode::UNAUTHORIZED.into_response()}if let Some(r)=d.rules.iter_mut().find(|x|x.id==i){r.enabled=!r.enabled;save_json(&d);save_gost(&d);}Json("ok").into_response()}
const L_HTM:&str=r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Login</title><style>body{margin:0;height:100vh;display:flex;justify-content:center;align-items:center;background:url('{B}') center/cover;font-family:system-ui}.b{background:rgba(255,255,255,0.9);padding:2rem;border-radius:12px;width:300px}input{width:100%;padding:10px;margin:8px 0;box-sizing:border-box}button{width:100%;padding:10px;background:#2563eb;color:#fff;border:none;cursor:pointer}</style></head><body><div class="b"><h3 style="text-align:center">Gost Panel</h3><form onsubmit="L(event)"><input id="u"><input id="p" type="password"><button>Login</button></form></div><script>async function L(e){e.preventDefault();await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`username=${document.getElementById('u').value}&password=${document.getElementById('p').value}`}).then(r=>{if(r.redirected)location.href='/';else alert('Fail')})}</script></body></html>"#;
EOF

    # 追加 Dashboard HTML (轻量版界面，无监控图表)
    cat >> src/main.rs << 'EOF'
const D_HTM:&str=r#"<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Gost Panel</title><link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet"><style>:root{--p:#2563eb;--bg:#f3f4f6}body{margin:0;font-family:system-ui;background:var(--bg);padding:20px}.nav{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px}.cd{background:#fff;border-radius:10px;padding:20px;box-shadow:0 1px 3px rgba(0,0,0,.1);margin-bottom:20px}.ig{display:grid;grid-template-columns:1fr 1fr 2fr 1fr auto;gap:10px}input,select{padding:10px;border:1px solid #ddd;border-radius:6px}button{padding:10px 15px;border:none;border-radius:6px;cursor:pointer;color:#fff;font-weight:bold}.ba{background:var(--p)}.bd{background:#ef4444}.bg{background:#9ca3af}table{width:100%;border-collapse:collapse}td,th{padding:12px;text-align:left;border-bottom:1px solid #eee}.st{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:5px}.on{background:#22c55e}.off{background:#9ca3af}.md{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.3);align-items:center;justify-content:center}.mb{background:#fff;padding:20px;width:500px;border-radius:10px}</style></head><body>
<div class="nav"><h3><i class="fas fa-network-wired"></i> Gost Panel</h3><button class="bd" onclick="LO()"><i class="fas fa-power-off"></i></button></div>
<div class="cd"><div class="ig"><input id="n" placeholder="Name"><input id="l" placeholder=":Port"><input id="r" placeholder="Target:Port"><select id="t"><option value="tcp">TCP</option><option value="udp">UDP</option></select><button class="ba" onclick="A()">Add</button><button class="bg" onclick="$('bm').style.display='flex'">Batch</button></div></div>
<div class="cd" style="overflow:auto"><table><thead><tr><th>State</th><th>Name</th><th>Listen</th><th>Proto</th><th>Target</th><th>Op</th></tr></thead><tbody id="ls"></tbody></table></div>
<div id="bm" class="md"><div class="mb"><h3>Batch Import</h3><textarea id="bi" rows="8" style="width:100%;margin:10px 0" placeholder="Name|:Port|Target:Port"></textarea><div style="text-align:right"><button class="bg" onclick="$('bm').style.display='none'">Cancel</button> <button class="ba" onclick="B()">Import</button></div></div></div>
<script>const $=i=>document.getElementById(i);
async function R(){let r=await fetch('/api/rules');if(r.status==401)location.href='/login';let d=await r.json();let h='';d.rules.forEach(x=>{h+=`<tr><td><span class="st ${x.enabled?'on':'off'}"></span>${x.enabled?'Run':'Stop'}</td><td>${x.name}</td><td>${x.listen}</td><td>${x.protocol}</td><td>${x.remote}</td><td><button class="bg" onclick="T('${x.id}')"><i class="fas fa-pause"></i></button> <button class="bd" onclick="D('${x.id}')"><i class="fas fa-trash"></i></button></td></tr>`});$('ls').innerHTML=h}
async function A(){let n=$('n').value,l=$('l').value,r=$('r').value,t=$('t').value;if(!n||!l)return;await fetch('/api/rules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,listen:l,remote:r,protocol:t})});R();$('n').value=''}
async function B(){let t=$('bi').value.trim();if(!t)return;let q=t.split('\n').map(x=>x.split('|')).filter(x=>x.length==3).map(x=>({name:x[0],listen:x[1],remote:x[2],protocol:'tcp'}));await fetch('/api/rules/batch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(q)});$('bm').style.display='none';R()}
async function T(i){await fetch(`/api/rules/${i}/toggle`,{method:'POST'});R()}async function D(i){if(confirm('Del?'))await fetch(`/api/rules/${i}`,{method:'DELETE'});R()}async function LO(){await fetch('/logout',{method:'POST'});location.href='/login'}
R();</script></body></html>"#.to_string()
}
EOF

    # 6. 编译 (静默)
    print_info "正在后台编译 (请稍候)..."
    /root/.cargo/bin/cargo clean >> "$LOG_FILE" 2>&1
    /root/.cargo/bin/cargo build --release >> "$LOG_FILE" 2>&1 &
    spinner $!

    if [ -f "target/release/gost-panel" ]; then
        print_ok "编译成功"
        cp target/release/gost-panel "$BINARY_PATH"
    else
        print_err "编译失败! 请查看日志: cat $LOG_FILE"
        exit 1
    fi

    # 7. 服务
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
Description=Gost Panel
After=gost.service
[Service]
Environment="PANEL_PORT=9794"
Environment="PANEL_USER=admin"
Environment="PANEL_PASS=123456"
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
    echo ""
    print_ok "安装完成！"
    echo -e "地址: http://${IP}:9794"
    echo -e "账号: admin / 123456"
    read -p "按回车返回菜单..."
}

# =========================================================
#   功能模块 2: 修改配置 (端口/用户/密码)
# =========================================================
modify_config() {
    clear
    echo -e "${CYAN}>>> 修改面板配置${RESET}"
    echo "请输入新信息 (不修改请直接回车)"
    
    read -p "新端口 (当前默认9794): " new_port
    read -p "新账号 (当前默认admin): " new_user
    read -p "新密码 (当前默认123456): " new_pass

    SVC_FILE="/etc/systemd/system/gost-panel.service"

    if [ ! -z "$new_port" ]; then
        sed -i "s/Environment=\"PANEL_PORT=.*/Environment=\"PANEL_PORT=${new_port}\"/" $SVC_FILE
    fi
    if [ ! -z "$new_user" ]; then
        sed -i "s/Environment=\"PANEL_USER=.*/Environment=\"PANEL_USER=${new_user}\"/" $SVC_FILE
    fi
    if [ ! -z "$new_pass" ]; then
        sed -i "s/Environment=\"PANEL_PASS=.*/Environment=\"PANEL_PASS=${new_pass}\"/" $SVC_FILE
    fi

    # 强制刷新 JSON 里的账号缓存
    if [ ! -z "$new_user" ] || [ ! -z "$new_pass" ]; then
        U=${new_user:-admin}
        P=${new_pass:-123456}
        if [ -f "$DATA_FILE" ]; then
             sed -i "s/\"username\": \".*\"/\"username\": \"$U\"/" $DATA_FILE
             sed -i "s/\"pass_hash\": \".*\"/\"pass_hash\": \"$P\"/" $DATA_FILE
        fi
    fi

    systemctl daemon-reload
    systemctl restart gost-panel
    print_ok "配置已更新并重启！"
    read -p "按回车返回菜单..."
}

# =========================================================
#   功能模块 3: 卸载
# =========================================================
uninstall_panel() {
    clear
    echo -e "${RED}⚠️  高能预警：这将删除面板、Gost及所有配置！${RESET}"
    read -p "确认卸载？(输入 y 确认): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    print_info "停止服务..."
    systemctl stop gost gost-panel
    systemctl disable gost gost-panel

    print_info "删除文件..."
    rm -f /etc/systemd/system/gost.service
    rm -f /etc/systemd/system/gost-panel.service
    rm -f /usr/local/bin/gost
    rm -f /usr/local/bin/gost-panel
    rm -rf /etc/gost
    rm -rf /opt/gost_panel
    rm -rf /opt/realm_panel

    systemctl daemon-reload
    print_ok "卸载完成，江湖再见！"
    read -p "按回车退出..."
    exit 0
}

# =========================================================
#   主菜单
# =========================================================
while true; do
    clear
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}            Gost v3 面板            ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    
    if systemctl is-active --quiet gost-panel; then
        echo -e "状态: ${GREEN}● 运行中${RESET}"
    else
        echo -e "状态: ${RED}● 未运行${RESET}"
    fi
    echo ""
    echo -e "1. 安装面板 (Install)"
    echo -e "2. 修改配置 (Config)"
    echo -e "3. 卸载面板 (Uninstall)"
    echo -e "0. 退出 (Exit)"
    echo ""
    read -p "请选择 [0-3]: " choice

    case $choice in
        1) install_panel ;;
        2) modify_config ;;
        3) uninstall_panel ;;
        0) exit 0 ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done

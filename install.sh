#!/bin/bash

# ===== צבעים =====
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ===== הגדרות =====
SERVER_URL="https://advision360.co.il/pyagent"
PI_USER=$(whoami | tr -d '\r')
HOME_DIR="/home/$PI_USER"
PY_FILE="kiosk_manager.py"
HTML_FILE="wifi_setup.html"
SCREEN_FILE="wifi_screen.html"
THEME_DIR="/usr/share/plymouth/themes/advision"

step() { echo -e "\n${BOLD}${BLUE}[$1/6]${NC} $2"; }
ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "\n${RED}❌ Error: $1${NC}"; exit 1; }

# ===== Banner =====
clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║    Digital Signage Lite Installer (Pi 5) - V5   ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ===== SCREEN_ID =====
while true; do
    echo -ne "${YELLOW}🎯 Enter SCREEN_ID for this device: ${NC}"
    read USER_SCREEN_ID
    [[ -n "$USER_SCREEN_ID" ]] && break
    echo -e "  ${RED}SCREEN_ID cannot be empty.${NC}"
done

# ===== סיבוב מסך =====
echo ""
echo -e "${BOLD}🔄 Screen Rotation:${NC}"
echo "   0 = Normal (landscape)"
echo "   1 = 90°  clockwise"
echo "   2 = 180° (upside down)"
echo "   3 = 270° clockwise / portrait (default)"
echo -ne "${YELLOW}Enter rotation [0/1/2/3] (press Enter for 3): ${NC}"
read ROTATION_CHOICE
ROTATION_CHOICE=${ROTATION_CHOICE:-3}
[[ "$ROTATION_CHOICE" =~ ^[0123]$ ]] || { warn "Invalid — defaulting to 3"; ROTATION_CHOICE=3; }

ROTATION_LABEL=$(case $ROTATION_CHOICE in 0) echo "Normal";; 1) echo "90°";; 2) echo "180°";; 3) echo "270°";; esac)
echo ""
echo -e "  ${GREEN}Screen ID : ${BOLD}$USER_SCREEN_ID${NC}"
echo -e "  ${GREEN}Rotation  : ${BOLD}${ROTATION_LABEL}${NC}"
echo ""

# =============================================
# [1/6] התקנת חבילות
# =============================================
step 1 "Installing Kiosk Packages"
sudo apt update -q 2>/dev/null || fail "apt update failed"

# זיהוי שם Chromium (Bookworm: chromium | ישן: chromium-browser)
if apt-cache show chromium &>/dev/null 2>&1; then
    CHROMIUM_PKG="chromium"
else
    CHROMIUM_PKG="chromium-browser"
fi
echo "  Chromium package: $CHROMIUM_PKG"

sudo apt install -y \
    cage \
    "$CHROMIUM_PKG" \
    python3 python3-pip \
    network-manager \
    iptables \
    curl wget \
    unclutter-xfixes \
    plymouth plymouth-themes \
    2>/dev/null || fail "Package installation failed"

echo "$CHROMIUM_PKG" > "$HOME_DIR/.chromium_pkg"

# הוספת המשתמש לקבוצות DRM (נדרש ל-cage/Wayland)
sudo usermod -a -G video,render,input "$PI_USER" 2>/dev/null
ok "Packages installed | Chromium: $CHROMIUM_PKG | Groups: video,render,input"

# =============================================
# [2/6] יצירת קבצי Kiosk
# =============================================
step 2 "Creating Kiosk Files"

# --- kiosk_manager.py ---
# נסה הורדה מהשרת; אם נכשל — צור מקומית
if wget -q --timeout=15 -O "$HOME_DIR/$PY_FILE" "$SERVER_URL/$PY_FILE" 2>/dev/null \
   && python3 -c "import ast; ast.parse(open('$HOME_DIR/$PY_FILE').read())" 2>/dev/null; then
    ok "kiosk_manager.py downloaded from server"
else
    warn "Server unavailable — creating kiosk_manager.py locally"
    cat > "$HOME_DIR/$PY_FILE" << 'PYEOF'
import subprocess, time, os, pwd, urllib.request, logging, signal, sys, threading, http.server, json

SCREEN_ID       = "SCREEN_ID_PLACEHOLDER"
SCREEN_ROTATION = "ROTATION_PLACEHOLDER"
ROTATION_MAP    = {"0":"normal","1":"90","2":"180","3":"270"}

try:    PI_USER = pwd.getpwuid(os.getuid()).pw_name
except: PI_USER = os.environ.get("USER","pi")

HOME_DIR    = f"/home/{PI_USER}"
LOG_FILE    = f"{HOME_DIR}/kiosk.log"
PORTAL_PORT = 8080
HOTSPOT_SSID= "Advision-Setup"
HOTSPOT_CON = "advision-hotspot"
HOTSPOT_IP  = "10.42.0.1"
PANEL_URL   = f"https://panel.advision360.co.il/display?screenId={SCREEN_ID}&prod=true"
WIFI_TV_URL = f"http://localhost:{PORTAL_PORT}/wifi_screen.html"

os.makedirs(HOME_DIR, exist_ok=True)
logging.basicConfig(level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)])
log = logging.info

def _detect_chromium():
    f = f"{HOME_DIR}/.chromium_pkg"
    if os.path.exists(f):
        n = open(f).read().strip()
        if n: return n
    for n in ("chromium","chromium-browser"):
        if os.path.exists(f"/usr/bin/{n}"): return n
    return "chromium"
CHROMIUM_BIN = _detect_chromium()

class PortalHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/networks"): self._networks()
        elif self.path.startswith("/api/status"):  self._status()
        elif self.path in ("/","index.html"):
            self.path="/wifi_setup.html"; super().do_GET()
        elif not self.path.startswith("/wifi_setup") and not self.path.startswith("/wifi_screen") and not self.path.startswith("/wifi_qr"):
            self.send_response(302)
            self.send_header("Location",f"http://{HOTSPOT_IP}:{PORTAL_PORT}/wifi_setup.html")
            self.end_headers()
        else: super().do_GET()
    def do_POST(self):
        if self.path.startswith("/api/connect"): self._connect()
    def do_OPTIONS(self):
        self.send_response(200); self._cors(); self.end_headers()
    def _networks(self):
        try:
            r=subprocess.run(["nmcli","-t","-f","SSID,SIGNAL,SECURITY","device","wifi","list","--rescan","yes"],
                capture_output=True,text=True,timeout=20)
            nets,seen=[],set()
            for line in r.stdout.strip().splitlines():
                p=line.split(":"); ssid=p[0].strip()
                if not ssid or ssid==HOTSPOT_SSID or ssid in seen: continue
                seen.add(ssid)
                sig=int(p[1]) if len(p)>1 and p[1].isdigit() else 0
                sec=bool(p[2].strip()) if len(p)>2 else False
                nets.append({"ssid":ssid,"signal":sig,"secured":sec})
            nets.sort(key=lambda x:x["signal"],reverse=True)
            self._json(nets)
        except Exception as e: self._json({"error":str(e)},500)
    def _status(self):  self._json({"connected":check_internet()})
    def _connect(self):
        try:
            body=json.loads(self.rfile.read(int(self.headers.get("Content-Length",0))))
            ssid=body.get("ssid","").strip(); pwd_=body.get("password","").strip()
            if not ssid: self._json({"success":False,"message":"Missing SSID"},400); return
            log(f"Connecting → {ssid}")
            self._json({"success":True,"message":"מתחבר...","connecting":True})
            def _do():
                time.sleep(0.5)
                subprocess.run(["sudo","nmcli","connection","down",  HOTSPOT_CON],capture_output=True)
                subprocess.run(["sudo","nmcli","connection","delete",HOTSPOT_CON],capture_output=True)
                time.sleep(2)
                cmd=["sudo","nmcli","device","wifi","connect",ssid]
                if pwd_: cmd+=["password",pwd_]
                r=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
                log(f"nmcli({r.returncode}): {r.stdout.strip()}")
            threading.Thread(target=_do,daemon=True).start()
        except Exception as e: log(f"Connect err:{e}"); self._json({"success":False,"message":str(e)},500)
    def _json(self,data,code=200):
        b=json.dumps(data,ensure_ascii=False).encode()
        self.send_response(code); self._cors()
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",len(b))
        self.end_headers(); self.wfile.write(b)
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Methods","GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers","Content-Type")
    def log_message(self,*a): pass

def start_portal_server():
    os.chdir(HOME_DIR)
    httpd=http.server.HTTPServer(("0.0.0.0",PORTAL_PORT),PortalHandler)
    threading.Thread(target=httpd.serve_forever,daemon=True).start()
    log(f"Portal on :{PORTAL_PORT}")

def create_hotspot():
    log(f"Creating hotspot: {HOTSPOT_SSID}")
    subprocess.run(["sudo","nmcli","connection","delete",HOTSPOT_CON],capture_output=True)
    r=subprocess.run(["sudo","nmcli","device","wifi","hotspot","ssid",HOTSPOT_SSID,"band","bg","con-name",HOTSPOT_CON,"password","advision1"],
        capture_output=True,text=True)
    if r.returncode==0:
        subprocess.run(["sudo","iptables","-t","nat","-A","PREROUTING","-i","wlan0","-p","tcp",
            "--dport","80","-j","REDIRECT","--to-port",str(PORTAL_PORT)],capture_output=True)
        return True
    log(f"Hotspot failed: {r.stderr.strip()}"); return False

def stop_hotspot():
    subprocess.run(["sudo","nmcli","connection","down",  HOTSPOT_CON],capture_output=True)
    subprocess.run(["sudo","nmcli","connection","delete",HOTSPOT_CON],capture_output=True)
    subprocess.run(["sudo","iptables","-t","nat","-D","PREROUTING","-i","wlan0","-p","tcp",
        "--dport","80","-j","REDIRECT","--to-port",str(PORTAL_PORT)],capture_output=True)
    log("Hotspot stopped")

def build_cage_cmd(url):
    env=os.environ.copy()
    wlr=ROTATION_MAP.get(str(SCREEN_ROTATION),"normal")
    if wlr!="normal": env["WLR_OUTPUT_TRANSFORM"]=wlr
    if not env.get("XDG_RUNTIME_DIR"):
        xdg=f"/run/user/{os.getuid()}"
        if os.path.isdir(xdg): env["XDG_RUNTIME_DIR"]=xdg
    return ["cage","--",CHROMIUM_BIN,"--kiosk","--noerrdialogs","--disable-infobars",
        "--autoplay-policy=no-user-gesture-required","--enable-features=VaapiVideoDecoder",
        "--ozone-platform=wayland","--disk-cache-dir=/dev/null",url], env

def check_internet():
    for url in ("https://panel.advision360.co.il","https://www.google.com","https://1.1.1.1"):
        try: urllib.request.urlopen(url,timeout=5); return True
        except: continue
    return False

def run_wifi_setup():
    log("No internet — WiFi setup")
    if not create_hotspot(): time.sleep(20); return
    cmd,env=build_cage_cmd(WIFI_TV_URL)
    proc=subprocess.Popen(cmd,env=env)
    while not check_internet():
        if proc.poll() is not None: proc=subprocess.Popen(cmd,env=env)
        time.sleep(5)
    log("Connected!"); stop_hotspot()
    proc.terminate()
    try: proc.wait(timeout=5)
    except: proc.kill()
    time.sleep(3)

def launch_kiosk():
    log(f"Kiosk → {PANEL_URL}")
    cmd,env=build_cage_cmd(PANEL_URL)
    return subprocess.Popen(cmd,env=env)

def handle_exit(sig,frame): log("Exit"); stop_hotspot(); sys.exit(0)

if __name__=="__main__":
    signal.signal(signal.SIGTERM,handle_exit)
    signal.signal(signal.SIGINT, handle_exit)
    log(f"Advision | Screen:{SCREEN_ID} | Rotation:{SCREEN_ROTATION}")
    start_portal_server()
    log("Init 10s..."); time.sleep(10)
    while not check_internet(): run_wifi_setup()
    kiosk=launch_kiosk()
    while True:
        if kiosk.poll() is not None:
            log("Kiosk crashed, restarting")
            while not check_internet(): run_wifi_setup()
            kiosk=launch_kiosk()
        time.sleep(30)
PYEOF
fi

# שתילת SCREEN_ID ו-ROTATION — עם Python (אמין לחלוטין)
python3 - << PYREPLACE
import re
f = open("$HOME_DIR/$PY_FILE").read()
f = re.sub(r'SCREEN_ID_PLACEHOLDER',        '$USER_SCREEN_ID',  f)
f = re.sub(r'ROTATION_PLACEHOLDER',         '$ROTATION_CHOICE', f)
f = re.sub(r'SCREEN_ID\s*=\s*"[^"]*"',     'SCREEN_ID = "$USER_SCREEN_ID"',  f)
f = re.sub(r'SCREEN_ROTATION\s*=\s*"[^"]*"','SCREEN_ROTATION = "$ROTATION_CHOICE"', f)
open("$HOME_DIR/$PY_FILE", "w").write(f)
PYREPLACE
chmod +x "$HOME_DIR/$PY_FILE"

# --- wifi_setup.html ---
if wget -q --timeout=15 -O "$HOME_DIR/$HTML_FILE" "$SERVER_URL/$HTML_FILE" 2>/dev/null \
   && grep -q "Advision" "$HOME_DIR/$HTML_FILE" 2>/dev/null; then
    ok "wifi_setup.html downloaded from server"
else
    warn "Server unavailable — creating wifi_setup.html locally"
    # הקובץ יוצר בנפרד (embed מלא בתוך install.sh)
    cat > "$HOME_DIR/$HTML_FILE" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Advision — WiFi Setup</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0d1b2a;color:#fff;font-family:'Segoe UI',Arial,sans-serif;
min-height:100vh;display:flex;flex-direction:column;align-items:center;
justify-content:center;padding:2rem}
.logo{font-size:1.5rem;font-weight:800;letter-spacing:3px;color:#e0e0e0;margin-bottom:.3rem}
.logo span{color:#4cc9f0}
.tagline{font-size:.85rem;color:#3a5570;letter-spacing:2px;text-transform:uppercase;margin-bottom:2rem}
.card{background:#111e2d;border:1px solid #1e3349;border-radius:16px;padding:2rem;
width:100%;max-width:480px;box-shadow:0 8px 40px rgba(0,0,0,.4)}
h2{font-size:1.4rem;font-weight:700;margin-bottom:.4rem}
.sub{font-size:.9rem;color:#4a6080;margin-bottom:1.5rem}
.badge{background:#0d2238;border:2px solid #4cc9f0;border-radius:50px;padding:.5rem 1.4rem;
font-size:1.3rem;font-weight:700;color:#4cc9f0;display:inline-block;margin-bottom:1.8rem;text-align:center;width:100%}
.divider{display:flex;align-items:center;gap:.8rem;color:#2a4060;font-size:.8rem;margin-bottom:1.4rem}
.divider::before,.divider::after{content:'';flex:1;height:1px;background:#1e3349}
#network-list{display:flex;flex-direction:column;gap:.6rem;margin-bottom:1.2rem}
.net-item{display:flex;align-items:center;gap:.8rem;background:#0d2238;border:1px solid #1e3349;
border-radius:10px;padding:.75rem 1rem;cursor:pointer;transition:border-color .2s}
.net-item:hover,.net-item.selected{border-color:#4cc9f0;background:#0f283d}
.net-ssid{flex:1;font-size:1rem;font-weight:500}
.bars{display:flex;align-items:flex-end;gap:2px;height:16px}
.bars span{width:4px;background:#4cc9f0;border-radius:1px;opacity:.2}
.bars span.on{opacity:1}
#pwd-sec{display:none;margin-bottom:1.2rem}
.pwd-lbl{font-size:.85rem;color:#6b8cad;margin-bottom:.5rem}
.pwd-row{display:flex;gap:.6rem}
#pwd-in{flex:1;background:#0d2238;border:1px solid #1e3349;border-radius:8px;
padding:.65rem .9rem;color:#fff;font-size:1rem;outline:none}
#pwd-in:focus{border-color:#4cc9f0}
.btn{padding:.65rem 1.4rem;border-radius:8px;border:none;font-size:.95rem;
font-weight:600;cursor:pointer}
.btn-sec{background:#1e3349;color:#9ab}
#conn-btn{width:100%;padding:.8rem;font-size:1rem;font-weight:700;background:#4cc9f0;
color:#0d1b2a;border:none;border-radius:10px;cursor:pointer;display:none;margin-top:.4rem}
#status{display:none;text-align:center;padding:1rem;border-radius:10px;margin-top:.8rem}
#status.connecting{background:rgba(76,201,240,.08);border:1px solid rgba(76,201,240,.2)}
#status.success{background:rgba(0,200,100,.08);border:1px solid rgba(0,200,100,.3)}
#status.error{background:rgba(255,80,80,.08);border:1px solid rgba(255,80,80,.3)}
.hint{margin-top:1.5rem;text-align:center;font-size:.8rem;color:#3a5570}
.hint strong{color:#6b8cad}
.waiting{display:flex;align-items:center;gap:.6rem;font-size:.85rem;color:#3a5570;margin-top:1.8rem}
.pulse{width:8px;height:8px;border-radius:50%;background:#4cc9f0;animation:p 2s infinite}
@keyframes p{0%,100%{opacity:1}50%{opacity:.3}}
.dots span{animation:b 1.4s infinite;opacity:0}
.dots span:nth-child(1){animation-delay:0s}
.dots span:nth-child(2){animation-delay:.2s}
.dots span:nth-child(3){animation-delay:.4s}
@keyframes b{0%,100%{opacity:0}40%{opacity:1}}
#msg{color:#4a6080;font-size:.9rem;text-align:center;padding:.5rem}
#scan-btn{width:100%;padding:.7rem;background:#1e3349;color:#4a6080;
border:1px dashed #2a4060;border-radius:10px;cursor:pointer;font-size:.9rem;display:none}
</style>
</head>
<body>
<div class="logo">ADV<span>ISION</span></div>
<div class="tagline">Digital Signage</div>
<div class="card">
  <h2>הגדרת חיבור WiFi</h2>
  <p class="sub">חבר את הטלפון לרשת, ובחר את ה-WiFi שלך</p>
  <div style="text-align:center">
    <div class="badge">📶 Advision-Setup</div>
    <div style="margin-top:.6rem;font-size:.9rem;color:#6b8cad;">סיסמה: <strong style="color:#4cc9f0;letter-spacing:2px;">advision1</strong></div>
  </div>
  <div class="divider">בחר רשת WiFi</div>
  <div id="msg">🔍 סורק...</div>
  <div id="network-list"></div>
  <button id="scan-btn" onclick="load()">🔄 סרוק שוב</button>
  <div id="pwd-sec">
    <div class="pwd-lbl">סיסמה עבור: <strong id="ssid-lbl"></strong></div>
    <div class="pwd-row">
      <input id="pwd-in" type="password" placeholder="הזן סיסמה...">
      <button class="btn btn-sec" onclick="clear_()">ביטול</button>
    </div>
  </div>
  <button id="conn-btn" onclick="connect()">התחבר ✓</button>
  <div id="status"><div id="s-icon" style="font-size:2rem;margin-bottom:.4rem"></div><div id="s-text"></div></div>
</div>
<div class="hint">אם הפורטל לא נפתח, פתח דפדפן ועבור ל: <strong>10.42.0.1:8080</strong></div>
<div class="waiting"><div class="pulse"></div>ממתין<span class="dots"><span>.</span><span>.</span><span>.</span></span></div>
<script>
let sel=null;
function bars(s){let h='<div class="bars">';[25,50,75,100].forEach(t=>{h+=`<span style="height:${Math.round(t*.75)}%" class="${s>=t?'on':''}"></span>`;});return h+'</div>';}
function esc(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function load(){
  document.getElementById('network-list').innerHTML='';
  document.getElementById('msg').textContent='🔍 סורק...';
  document.getElementById('msg').style.display='block';
  document.getElementById('scan-btn').style.display='none';
  fetch('/api/networks').then(r=>r.json()).then(nets=>{
    document.getElementById('msg').style.display='none';
    if(!Array.isArray(nets)||!nets.length){document.getElementById('msg').textContent='⚠️ לא נמצאו רשתות';document.getElementById('msg').style.display='block';document.getElementById('scan-btn').style.display='block';return;}
    nets.forEach(n=>{
      let d=document.createElement('div');d.className='net-item';
      d.innerHTML=`<span class="net-ssid">${esc(n.ssid)}</span>${bars(n.signal)}<span>${n.secured?'🔒':'🔓'}</span>`;
      d.onclick=()=>pick(n.ssid,n.secured);
      document.getElementById('network-list').appendChild(d);
    });
    document.getElementById('scan-btn').style.display='block';
  }).catch(()=>{document.getElementById('msg').textContent='⚠️ שגיאה';document.getElementById('msg').style.display='block';document.getElementById('scan-btn').style.display='block';});
}
function pick(ssid,sec){
  sel=ssid;
  document.querySelectorAll('.net-item').forEach(e=>e.classList.remove('selected'));
  event.currentTarget.classList.add('selected');
  document.getElementById('ssid-lbl').textContent=ssid;
  document.getElementById('pwd-sec').style.display=sec?'block':'none';
  document.getElementById('conn-btn').style.display='block';
  if(sec)setTimeout(()=>document.getElementById('pwd-in').focus(),100);
  document.getElementById('status').style.display='none';
}
function clear_(){sel=null;document.querySelectorAll('.net-item').forEach(e=>e.classList.remove('selected'));document.getElementById('pwd-sec').style.display='none';document.getElementById('conn-btn').style.display='none';}
function connect(){
  if(!sel)return;
  let pw=document.getElementById('pwd-in').value;
  showStatus('connecting','⏳','מתחבר...<br><small>המסך יחזור לפעולה אוטומטית</small>');
  document.getElementById('conn-btn').disabled=true;
  fetch('/api/connect',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:sel,password:pw})})
  .then(r=>r.json()).then(d=>{if(d.connecting||d.success){showStatus('success','✅','בקשה נשלחה!<br><small>המסך יעלה בקרוב</small>');}else{showStatus('error','❌',d.message||'שגיאה');document.getElementById('conn-btn').disabled=false;}})
  .catch(()=>showStatus('success','✅','מתחבר...<br><small>בדוק את המסך</small>'));
}
function showStatus(type,icon,text){let b=document.getElementById('status');b.className=type;document.getElementById('s-icon').innerHTML=icon;document.getElementById('s-text').innerHTML=text;b.style.display='block';}
document.getElementById('pwd-in').addEventListener('keydown',e=>{if(e.key==='Enter')connect();});
window.onload=()=>{document.body.style.cursor='auto';load();};
</script>
</body>
</html>
HTMLEOF
fi

ok "Files ready | Screen ID: $USER_SCREEN_ID | Rotation: ${ROTATION_LABEL}"

# =============================================
# [3/6] יצירת QR Code
# =============================================
step 3 "Generating WiFi QR Code"
pip3 install qrcode pillow --break-system-packages -q 2>/dev/null
python3 -c "
try:
    import qrcode
    qr = qrcode.QRCode(version=2, error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=10, border=4)
    qr.add_data('WIFI:T:WPA;S:Advision-Setup;P:advision1;;')
    qr.make(fit=True)
    qr.make_image(fill_color='#0d1b2a', back_color='white').save('$HOME_DIR/wifi_qr.png')
    print('  QR saved')
except Exception as e:
    print(f'  QR skipped: {e}')
"
ok "QR Code ready"

# --- wifi_screen.html (TV display with QR code) ---
if wget -q --timeout=15 -O "$HOME_DIR/$SCREEN_FILE" "$SERVER_URL/$SCREEN_FILE" 2>/dev/null \
   && grep -q "Advision" "$HOME_DIR/$SCREEN_FILE" 2>/dev/null; then
    ok "wifi_screen.html downloaded from server"
else
    warn "Server unavailable — creating wifi_screen.html locally (embedded)"
    cat > "$HOME_DIR/$SCREEN_FILE" << 'SCREENEOF'
<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Advision — WiFi Setup Display</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#070f1c;--bg2:#0d1b2a;--card:#111e2d;--border:#1a2f45;--accent:#4cc9f0;--accent2:#6e40c9;--success:#22d3a5;--text:#e2e8f0;--muted:#4a6880;--step-bg:rgba(76,201,240,0.06)}
html,body{width:100%;height:100%;overflow:hidden}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',Tahoma,Arial,sans-serif;display:flex;flex-direction:column}
.topbar{display:flex;justify-content:space-between;align-items:center;padding:.9rem 3rem;border-bottom:1px solid var(--border);background:rgba(13,27,42,.9);backdrop-filter:blur(8px);flex-shrink:0}
.logo{font-size:1.7rem;font-weight:900;letter-spacing:4px;color:#d0dce8}
.logo span{color:var(--accent)}
.tagline{font-size:.7rem;letter-spacing:3px;text-transform:uppercase;color:var(--muted);margin-top:.15rem}
.clock{font-size:2rem;font-weight:700;color:var(--accent);letter-spacing:2px;font-variant-numeric:tabular-nums}
.date-str{font-size:.75rem;color:var(--muted);text-align:left;letter-spacing:1px;margin-top:.2rem}
.main{flex:1;display:flex;align-items:stretch;overflow:hidden}
.panel-qr{width:44%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:1.6rem;padding:2rem 2.5rem;border-left:1px solid var(--border);background:linear-gradient(160deg,#0a1525 0%,#0d1b2a 100%)}
.qr-label-top{font-size:1.05rem;font-weight:700;color:var(--accent);letter-spacing:2px;text-transform:uppercase;display:flex;align-items:center;gap:.6rem}
.qr-label-top::before,.qr-label-top::after{content:'';flex:1;height:1px;background:var(--border)}
.qr-frame{position:relative;background:#fff;border-radius:22px;padding:18px;box-shadow:0 0 0 3px var(--bg2),0 0 0 5px var(--accent),0 0 60px rgba(76,201,240,.35),0 0 120px rgba(76,201,240,.15);animation:pulse-glow 3s ease-in-out infinite}
@keyframes pulse-glow{0%,100%{box-shadow:0 0 0 3px var(--bg2),0 0 0 5px var(--accent),0 0 50px rgba(76,201,240,.3),0 0 100px rgba(76,201,240,.1)}50%{box-shadow:0 0 0 3px var(--bg2),0 0 0 5px var(--accent),0 0 80px rgba(76,201,240,.55),0 0 150px rgba(76,201,240,.25)}}
.qr-frame::before,.qr-frame::after{content:'';position:absolute;width:20px;height:20px;border-color:var(--accent2);border-style:solid}
.qr-frame::before{top:-8px;right:-8px;border-width:3px 3px 0 0;border-radius:0 4px 0 0}
.qr-frame::after{bottom:-8px;left:-8px;border-width:0 0 3px 3px;border-radius:0 0 0 4px}
.qr-frame img{width:260px;height:260px;display:block;border-radius:8px;image-rendering:pixelated}
.wifi-badge{background:var(--card);border:1px solid var(--border);border-radius:50px;padding:.6rem 2rem;text-align:center}
.wifi-badge .net-name{font-size:1.3rem;font-weight:800;color:var(--accent);letter-spacing:1px}
.wifi-badge .net-type{font-size:.7rem;color:var(--muted);letter-spacing:2px;text-transform:uppercase;margin-top:.15rem}
.scan-hint{font-size:.9rem;color:var(--muted);display:flex;align-items:center;gap:.5rem}
.scan-hint .arrow{animation:bounce-left 1.2s ease-in-out infinite}
@keyframes bounce-left{0%,100%{transform:translateX(0)}50%{transform:translateX(-5px)}}
.panel-steps{flex:1;display:flex;flex-direction:column;justify-content:center;padding:2rem 3.5rem;gap:1.3rem}
.section-title{font-size:1.8rem;font-weight:800;color:var(--text);line-height:1.3;margin-bottom:.2rem}
.section-title span{color:var(--accent)}
.section-sub{font-size:.9rem;color:var(--muted);margin-bottom:.8rem}
.step{display:flex;align-items:center;gap:1.2rem;background:var(--step-bg);border:1px solid var(--border);border-radius:14px;padding:1rem 1.4rem;transition:border-color .3s;position:relative;overflow:hidden}
.step::before{content:'';position:absolute;right:0;top:0;bottom:0;width:3px;background:var(--accent);opacity:0;transition:opacity .3s}
.step.active{border-color:rgba(76,201,240,.5)}
.step.active::before{opacity:1}
.step.done{border-color:rgba(34,211,165,.3);background:rgba(34,211,165,.04)}
.step.done::before{background:var(--success);opacity:1}
.step-num{width:38px;height:38px;border-radius:50%;background:var(--border);border:2px solid var(--accent);display:flex;align-items:center;justify-content:center;font-size:1rem;font-weight:800;color:var(--accent);flex-shrink:0;transition:all .3s}
.step.done .step-num{background:var(--success);border-color:var(--success);color:#0a1628}
.step.done .step-num::after{content:'✓'}
.step-icon{font-size:1.6rem;flex-shrink:0}
.step-title{font-size:1rem;font-weight:700;color:var(--text)}
.step-desc{font-size:.82rem;color:var(--muted);margin-top:.2rem;line-height:1.5}
.statusbar{display:flex;align-items:center;justify-content:space-between;padding:.75rem 3rem;border-top:1px solid var(--border);background:rgba(13,27,42,.9);flex-shrink:0}
.status-left{display:flex;align-items:center;gap:.8rem;font-size:.82rem;color:var(--muted)}
.pulse-dot{width:8px;height:8px;border-radius:50%;background:var(--accent);animation:pulse-dot 2s ease-in-out infinite}
@keyframes pulse-dot{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(1.6);opacity:.5}}
.status-right{font-size:.8rem;color:var(--muted)}
.status-right strong{color:#6b8cad}
@keyframes ring-spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}
.ring{position:absolute;inset:-12px;border-radius:50%;border:2px solid transparent;border-top-color:var(--accent);border-right-color:rgba(76,201,240,.3);animation:ring-spin 4s linear infinite;pointer-events:none}
.qr-frame-wrap{position:relative;display:inline-flex}
body::after{content:'';position:fixed;inset:0;pointer-events:none;background:radial-gradient(ellipse 60% 40% at 20% 50%,rgba(76,201,240,.04) 0%,transparent 70%),radial-gradient(ellipse 40% 50% at 80% 50%,rgba(110,64,201,.04) 0%,transparent 70%);z-index:0}
.topbar,.main,.statusbar{position:relative;z-index:1}
</style>
</head>
<body>
<div class="topbar">
  <div>
    <div class="logo">ADV<span>ISION</span></div>
    <div class="tagline">Digital Signage</div>
  </div>
  <div style="text-align:left">
    <div class="clock" id="clock">00:00:00</div>
    <div class="date-str" id="dateval"></div>
  </div>
</div>
<div class="main">
  <div class="panel-qr">
    <div class="qr-label-top">סרוק להתחבר</div>
    <div class="qr-frame-wrap">
      <div class="ring"></div>
      <div class="qr-frame">
        <img src="/wifi_qr.png" alt="WiFi QR Code" id="qr-img"
             onerror="this.style.display='none';document.getElementById('qr-fallback').style.display='flex'">
        <div id="qr-fallback" style="display:none;width:260px;height:260px;align-items:center;justify-content:center;flex-direction:column;gap:1rem;text-align:center;padding:1rem">
          <div style="font-size:3rem">📶</div>
          <div style="font-size:.9rem;font-weight:700;color:#4a6880">Advision-Setup</div>
        </div>
      </div>
    </div>
    <div class="wifi-badge">
      <div class="net-name">📶 Advision-Setup</div>
      <div class="net-type">רשת WiFi לחיבור · פתוח</div>
    </div>
    <div class="scan-hint"><span class="arrow">←</span><span>סרוק עם מצלמת הטלפון</span></div>
  </div>
  <div class="panel-steps">
    <div class="section-title">איך <span>מגדירים</span> WiFi?</div>
    <div class="section-sub">עקוב אחר השלבים הבאים — תהליך של פחות מדקה</div>
    <div class="step" id="s1">
      <div class="step-num">1</div><div class="step-icon">📷</div>
      <div class="step-body"><div class="step-title">סרוק את ה-QR Code</div>
      <div class="step-desc">פתח מצלמה בטלפון וסרוק את הקוד משמאל<br>הטלפון יתחבר אוטומטית לרשת הזמנית</div></div>
    </div>
    <div class="step" id="s2">
      <div class="step-num">2</div><div class="step-icon">🌐</div>
      <div class="step-body"><div class="step-title">פורטל הגדרות ייפתח אוטומטית</div>
      <div class="step-desc">לחלופין, פתח דפדפן ועבור ל: <strong style="color:#4cc9f0;letter-spacing:1px">10.42.0.1:8080</strong></div></div>
    </div>
    <div class="step" id="s3">
      <div class="step-num">3</div><div class="step-icon">📋</div>
      <div class="step-body"><div class="step-title">בחר את רשת ה-WiFi הביתית שלך</div>
      <div class="step-desc">בחר מהרשימה את הרשת שברצונך להתחבר אליה<br>והזן את הסיסמה במידת הצורך</div></div>
    </div>
    <div class="step" id="s4">
      <div class="step-num">4</div><div class="step-icon">✅</div>
      <div class="step-body"><div class="step-title">המסך יחזור לפעולה אוטומטית</div>
      <div class="step-desc">לאחר חיבור מוצלח, תצוגת הדיגיטל תעלה מחדש<br>אין צורך בפעולה נוספת מצידך</div></div>
    </div>
  </div>
</div>
<div class="statusbar">
  <div class="status-left"><div class="pulse-dot"></div><span>ממתין לחיבור WiFi<span id="waiting-dots"></span></span></div>
  <div class="status-right">כניסה ידנית לפורטל: <strong>http://10.42.0.1:8080</strong></div>
</div>
<script>
function tick(){
  const now=new Date();
  const hh=String(now.getHours()).padStart(2,'0');
  const mm=String(now.getMinutes()).padStart(2,'0');
  const ss=String(now.getSeconds()).padStart(2,'0');
  document.getElementById('clock').textContent=`${hh}:${mm}:${ss}`;
  const days=['ראשון','שני','שלישי','רביעי','חמישי','שישי','שבת'];
  const months=['ינואר','פברואר','מרץ','אפריל','מאי','יוני','יולי','אוגוסט','ספטמבר','אוקטובר','נובמבר','דצמבר'];
  document.getElementById('dateval').textContent=
    `יום ${days[now.getDay()]} · ${now.getDate()} ${months[now.getMonth()]} ${now.getFullYear()}`;
}
tick(); setInterval(tick,1000);
let dotCount=0;
setInterval(()=>{dotCount=(dotCount+1)%4;document.getElementById('waiting-dots').textContent='.'.repeat(dotCount);},500);
const steps=['s1','s2','s3','s4'];let cur=0;
function hl(){steps.forEach((id,i)=>{const e=document.getElementById(id);e.classList.remove('active','done');if(i<cur)e.classList.add('done');if(i===cur)e.classList.add('active');});cur=(cur+1)%steps.length;}
hl();setInterval(hl,2500);
document.getElementById('qr-img').addEventListener('error',function(){setTimeout(()=>{this.src='/wifi_qr.png?t='+Date.now();},5000);});
</script>
</body>
</html>
SCREENEOF
    ok "wifi_screen.html created locally (embedded)"
fi

# =============================================
# [4/6] Auto-Start (autologin + bash_profile)
# =============================================
step 4 "Configuring Auto-Start (systemd service + autologin fallback)"

# --- הסרת services ישנים ---
sudo systemctl disable kiosk.service        2>/dev/null
sudo systemctl disable advision-kiosk.service 2>/dev/null
sudo rm -f /etc/systemd/system/kiosk.service
sudo rm -f /etc/systemd/system/advision-kiosk.service
sudo systemctl daemon-reload 2>/dev/null

# ─── UID של המשתמש (נדרש ל-XDG_RUNTIME_DIR) ───────────────
PI_UID=$(id -u "$PI_USER")

# ─── advision-kiosk.service ────────────────────────────────
# מפעיל את הקיוסק ישירות דרך systemd — לפני שagetty כותב
# כלום על המסך. cage תופסת את ה-DRM ב-exclusivity ומסתירה
# כל טקסט קונסול.
sudo tee /etc/systemd/system/advision-kiosk.service > /dev/null << SVCEOF
[Unit]
Description=Advision Digital Signage Kiosk
Documentation=https://advision360.co.il
After=systemd-logind.service
After=plymouth-quit-wait.service
Wants=plymouth-quit-wait.service

[Service]
User=$PI_USER
PAMName=login
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Environment=XDG_RUNTIME_DIR=/run/user/$PI_UID
Environment=HOME=$HOME_DIR
WorkingDirectory=$HOME_DIR
ExecStart=/usr/bin/python3 $HOME_DIR/$PY_FILE
Restart=always
RestartSec=5
# כל הפלט עובר ללוג — שום דבר לא נכתב על המסך
StandardOutput=append:$HOME_DIR/kiosk.log
StandardError=append:$HOME_DIR/kiosk.log

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl enable advision-kiosk.service
sudo systemctl daemon-reload
ok "advision-kiosk.service enabled (primary, starts after Plymouth)"

# --- autologin ל-tty1 (fallback לSSH / debugging) ---
# --noissue: אין הצגת /etc/issue (כולל "My IP address is...")
# --noclear: שמירה על מסך Plymouth בזמן המעבר
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $PI_USER --noissue --noclear %I \$TERM
Type=idle
EOF
sudo systemctl daemon-reload
ok "Autologin configured (fallback, --noissue suppresses IP banner)"

# --- kiosk loop ב-~/.bash_profile (fallback בלבד) ---
cat > "$HOME_DIR/.bash_profile" << BPEOF
# === Advision Kiosk — fallback launcher (tty1 only) ===
[[ -f ~/.bashrc ]] && source ~/.bashrc

if [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    # אם ה-service הראשי כבר פועל, אל תפעיל שוב
    if systemctl is-active --quiet advision-kiosk.service 2>/dev/null; then
        exit 0
    fi
    # נקה מסך מיידית + הסתר cursor (מסתיר כל שארית קונסול)
    clear
    printf '\033[?25l'
    setterm --foreground black --background black 2>/dev/null || true
    sleep 2
    while true; do
        /usr/bin/python3 $HOME_DIR/$PY_FILE >> $HOME_DIR/kiosk.log 2>&1
        sleep 5
    done
fi
BPEOF
ok "~/.bash_profile configured (fallback, immediate screen-clear on login)"

# --- passwordless sudo ---
echo "$PI_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/kiosk-nopasswd > /dev/null
sudo chmod 440 /etc/sudoers.d/kiosk-nopasswd
ok "sudo passwordless configured for $PI_USER"

# =============================================
# [5/6] הגדרות תצוגה ודיכוי הודעות אתחול
# =============================================
step 5 "Configuring Display & Suppressing Boot Messages"

# כיבוי screen blanking
sudo raspi-config nonint do_blanking 1
ok "Screen blanking disabled"

# ─── הסרת הודעות כניסה ─────────────────────
sudo touch "$HOME_DIR/.hushlogin"
printf '' | sudo tee /etc/motd         > /dev/null
printf '' | sudo tee /etc/issue        > /dev/null
printf '' | sudo tee /etc/issue.net    > /dev/null
# /etc/issue.d/ — קבצים דינמיים (כולל "My IP address is \4 \6")
sudo rm -f /etc/issue.d/*.issue 2>/dev/null || true
sudo mkdir -p /etc/issue.d/
ok "Login messages suppressed (motd / issue / issue.d)"

# ─── journald: ללא פלט לקונסול ─────────────
sudo mkdir -p /etc/systemd/journald.conf.d/
sudo tee /etc/systemd/journald.conf.d/advision-quiet.conf > /dev/null << 'EOF'
[Journal]
Storage=volatile
ForwardToConsole=no
MaxLevelConsole=emerg
EOF
ok "journald: console output suppressed"

# ─── systemd: ללא status messages ───────────
sudo mkdir -p /etc/systemd/system.conf.d/
sudo tee /etc/systemd/system.conf.d/advision-quiet.conf > /dev/null << 'EOF'
[Manager]
StatusUnitFormat=none
ShowStatus=no
EOF
ok "systemd: status messages suppressed"

# ─── הסרת שורות dmesg מהקונסול ─────────────
# (loglevel=0 בcmdline מטפל בזה בשלב 6)
ok "Cursor hiding ready (unclutter-xfixes)"

# =============================================
# [6/6] Plymouth Boot Theme
# =============================================
step 6 "Installing Advision Boot Theme"
sudo mkdir -p "$THEME_DIR"

# התקנת Pillow עבור Python של root (נדרש לשלב זה)
sudo pip3 install pillow --break-system-packages -q 2>/dev/null

sudo python3 -c "
from PIL import Image, ImageDraw, ImageFont
import os, math

T = '$THEME_DIR'
W, H = 1920, 1080

# ── Background: dark navy with subtle centered radial glow ──
bg = Image.new('RGB', (W, H), (10, 22, 40))
d_bg = ImageDraw.Draw(bg)
for i in range(60, 0, -1):
    alpha = int(12 * (1 - i / 60))
    ellipse = [W//2 - i*10, H//2 - i*7, W//2 + i*10, H//2 + i*7]
    d_bg.ellipse(ellipse, fill=(10 + alpha, 28 + alpha, 55 + alpha))
bg.save(f'{T}/background.png')

# ── Font setup ──
font_paths = [
    '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
    '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
    '/usr/share/fonts/truetype/freefont/FreeSansBold.ttf',
]
f_lg = f_md = None
for fp in font_paths:
    if os.path.exists(fp):
        f_lg = ImageFont.truetype(fp, 108)
        f_md = ImageFont.truetype(fp, 30)
        break
if not f_lg:
    f_lg = f_md = ImageFont.load_default()

# ── Logo: ADV(white) + ISION(cyan) + 'Digital Signage' subtitle ──
probe = Image.new('RGBA', (1, 1))
dp = ImageDraw.Draw(probe)
adv_bb   = dp.textbbox((0, 0), 'ADV',            font=f_lg)
ision_bb = dp.textbbox((0, 0), 'ISION',           font=f_lg)
sub_bb   = dp.textbbox((0, 0), 'Digital Signage', font=f_md)
adv_w  = adv_bb[2]   - adv_bb[0]
text_w = (ision_bb[2] - ision_bb[0]) + adv_w
text_h = adv_bb[3]   - adv_bb[1]
sub_w  = sub_bb[2]   - sub_bb[0]
sub_h  = sub_bb[3]   - sub_bb[1]
pad = 40
lw = max(text_w, sub_w) + pad * 2
lh = text_h + 22 + sub_h + pad * 2
logo = Image.new('RGBA', (lw, lh), (0, 0, 0, 0))
dl = ImageDraw.Draw(logo)
tx = (lw - text_w) // 2
dl.text((tx,          pad), 'ADV',            fill=(215, 228, 242, 255), font=f_lg)
dl.text((tx + adv_w,  pad), 'ISION',          fill=(76,  201, 240, 255), font=f_lg)
dl.text(((lw - sub_w) // 2, pad + text_h + 14), 'Digital Signage', fill=(75, 125, 165, 210), font=f_md)
logo.save(f'{T}/logo.png')

# ── Progress bar assets (1×1 px, scaled by the Plymouth script) ──
Image.new('RGB', (1, 1), (18, 38, 60)).save(f'{T}/bar_bg.png')
Image.new('RGB', (1, 1), (76, 201, 240)).save(f'{T}/bar_fill.png')

# ── Animated loading dots: 4 frames ──
# Frame 0 = all dim  |  Frames 1-3 = one dot lit sequentially
DOT_W, DOT_H = 96, 20
for frame in range(4):
    img = Image.new('RGBA', (DOT_W, DOT_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    active = (frame - 1) % 3 if frame > 0 else -1
    for i in range(3):
        cx = 16 + i * 32
        cy = DOT_H // 2
        lit = (i == active)
        r   = 7 if lit else 4
        col = (76, 201, 240, 255) if lit else (28, 62, 95, 200)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
    img.save(f'{T}/dot{frame + 1}.png')

print('  Plymouth images generated successfully')
" 2>&1 | sed 's/^/  /'

sudo tee "$THEME_DIR/advision.plymouth" > /dev/null << 'EOF'
[Plymouth Theme]
Name=Advision
Description=Advision Digital Signage Boot Screen
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/advision
ScriptFile=/usr/share/plymouth/themes/advision/advision.script
EOF

sudo tee "$THEME_DIR/advision.script" > /dev/null << 'PLEOF'
// ═══════════════════════════════════════════════
//  Advision Digital Signage — Plymouth Boot Theme
// ═══════════════════════════════════════════════

screen_w = Window.GetWidth();
screen_h = Window.GetHeight();

// ── Background (scaled to fill any resolution) ──
bg_src = Image("background.png");
bg = Sprite(bg_src.Scale(screen_w, screen_h));
bg.SetX(0); bg.SetY(0); bg.SetZ(-100);

// ── Logo ──
logo_img = Image("logo.png");
logo_w   = logo_img.GetWidth();
logo_h   = logo_img.GetHeight();
logo_spr = Sprite(logo_img);
logo_spr.SetX(Math.Int((screen_w - logo_w) / 2));
logo_spr.SetY(Math.Int(screen_h / 2 - logo_h / 2 - 70));
logo_spr.SetZ(10);

// ── Progress bar ──
bar_w = Math.Int(screen_w * 0.38);
if (bar_w > 680) { bar_w = 680; }
if (bar_w < 320) { bar_w = 320; }
bar_h = 7;
bar_x = Math.Int((screen_w - bar_w) / 2);
bar_y = Math.Int(screen_h / 2 + logo_h / 2 + 40);

bar_track = Sprite(Image("bar_bg.png").Scale(bar_w, bar_h));
bar_track.SetX(bar_x); bar_track.SetY(bar_y); bar_track.SetZ(9);

bar_fill_1px = Image("bar_fill.png");
bar_spr = Sprite();
bar_spr.SetX(bar_x); bar_spr.SetY(bar_y); bar_spr.SetZ(10);

// ── Animated dots (4 frames, ~3 fps) ──
dot_img_1 = Image("dot1.png");
dot_img_2 = Image("dot2.png");
dot_img_3 = Image("dot3.png");
dot_img_4 = Image("dot4.png");

dot_spr = Sprite(dot_img_1);
dot_spr.SetX(Math.Int((screen_w - dot_img_1.GetWidth()) / 2));
dot_spr.SetY(bar_y + bar_h + 20);
dot_spr.SetZ(10);

// ── State ──
boot_p  = 0;
disp_p  = 0.02;   // start with a tiny sliver visible
tick    = 0;
d_frame = 0;

// ── Refresh: called ~30×/sec by Plymouth ──
fun Refresh() {
    tick++;

    // Smooth interpolation toward boot_p, plus a slow background creep
    disp_p = disp_p + (boot_p - disp_p) * 0.07 + 0.00035;
    if (disp_p > 1) { disp_p = 1; }

    // Render bar
    fill_w = Math.Int(bar_w * disp_p);
    if (fill_w < bar_h) { fill_w = bar_h; }
    if (fill_w > bar_w) { fill_w = bar_w; }
    bar_spr.SetImage(bar_fill_1px.Scale(fill_w, bar_h));
    bar_spr.SetOpacity(1);

    // Rotate dots ~3 fps  (every 10 ticks at 30 fps)
    if (tick % 10 == 0) {
        d_frame = (d_frame + 1) % 4;
        if (d_frame == 0) { dot_spr.SetImage(dot_img_1); dot_spr.SetX(Math.Int((screen_w - dot_img_1.GetWidth()) / 2)); }
        if (d_frame == 1) { dot_spr.SetImage(dot_img_2); dot_spr.SetX(Math.Int((screen_w - dot_img_2.GetWidth()) / 2)); }
        if (d_frame == 2) { dot_spr.SetImage(dot_img_3); dot_spr.SetX(Math.Int((screen_w - dot_img_3.GetWidth()) / 2)); }
        if (d_frame == 3) { dot_spr.SetImage(dot_img_4); dot_spr.SetX(Math.Int((screen_w - dot_img_4.GetWidth()) / 2)); }
    }
}

fun BootProgress(duration, progress) {
    boot_p = progress;
}

Plymouth.SetRefreshFunction(Refresh);
Plymouth.SetBootProgressFunction(BootProgress);
PLEOF

ok "Theme files created"

sudo plymouth-set-default-theme advision
ok "Theme set as default"

echo "  Rebuilding initramfs (~30s)..."
sudo update-initramfs -u -k all 2>/dev/null \
    && ok "initramfs rebuilt" \
    || warn "initramfs failed — Plymouth may not show on boot"

# ─── cmdline.txt: suppress all visible boot output ────────────
CMDLINE="/boot/firmware/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE="/boot/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    # הוסף כל פרמטר בנפרד רק אם לא קיים (idempotent)
    for PARAM in \
        "quiet" \
        "splash" \
        "loglevel=0" \
        "logo.nologo" \
        "vt.global_cursor_default=0" \
        "systemd.show_status=false" \
        "plymouth.ignore-serial-consoles" \
        "rd.systemd.show_status=false" \
        "console=tty3"
    do
        grep -q "$PARAM" "$CMDLINE" \
            || sudo sed -i "s/$/ $PARAM/" "$CMDLINE"
    done
    ok "cmdline.txt: boot messages fully suppressed"
else
    warn "cmdline.txt not found — skipping kernel parameter setup"
fi

# ─── config.txt: כיבוי לוגו הקשת של Raspberry Pi ─────────────
CONFIG="/boot/firmware/config.txt"
[ -f "$CONFIG" ] || CONFIG="/boot/config.txt"
if [ -f "$CONFIG" ]; then
    grep -q "disable_splash" "$CONFIG" \
        || echo "disable_splash=1" | sudo tee -a "$CONFIG" > /dev/null
    # וודא שdtoverlay=vc4-kms-v3d קיים (נדרש ל-Plymouth עם KMS)
    grep -q "vc4-kms-v3d" "$CONFIG" \
        || echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$CONFIG" > /dev/null
    ok "config.txt: rainbow splash disabled, KMS overlay verified"
fi

# =============================================
# סיום
# =============================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║          ✅  INSTALLATION COMPLETE!             ║"
echo "║                                                  ║"
printf "║   Screen ID : %-35s║\n" "$USER_SCREEN_ID"
printf "║   Rotation  : %-35s║\n" "$ROTATION_LABEL"
echo "║                                                  ║"
echo "║          Run:  sudo reboot                       ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

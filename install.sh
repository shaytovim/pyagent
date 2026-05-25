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
WIFI_TV_URL = f"http://localhost:{PORTAL_PORT}/wifi_setup.html"

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
        elif not self.path.startswith("/wifi_setup") and not self.path.startswith("/wifi_qr"):
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
    qr.add_data('WIFI:T:nopass;S:Advision-Setup;;')
    qr.make(fit=True)
    qr.make_image(fill_color='#0d1b2a', back_color='white').save('$HOME_DIR/wifi_qr.png')
    print('  QR saved')
except Exception as e:
    print(f'  QR skipped: {e}')
"
ok "QR Code ready"

# =============================================
# [4/6] Auto-Start (autologin + bash_profile)
# =============================================
step 4 "Configuring Auto-Start (autologin + bash_profile)"

# --- הסרת kiosk.service ישן אם קיים ---
sudo systemctl disable kiosk.service 2>/dev/null
sudo rm -f /etc/systemd/system/kiosk.service
sudo systemctl daemon-reload 2>/dev/null

# --- autologin ל-tty1 עבור המשתמש הנוכחי ---
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $PI_USER --noclear %I \$TERM
Type=idle
EOF
sudo systemctl daemon-reload
ok "Autologin configured for user: $PI_USER on tty1"

# --- kiosk loop ב-~/.bash_profile ---
# פועל רק על tty1 ישירות — לא ב-SSH ולא ב-Wayland קיים
cat > "$HOME_DIR/.bash_profile" << BPEOF
# === Advision Kiosk Auto-Start ===
[[ -f ~/.bashrc ]] && source ~/.bashrc

if [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    sleep 3
    while true; do
        /usr/bin/python3 $HOME_DIR/$PY_FILE >> $HOME_DIR/kiosk.log 2>&1
        sleep 5
    done
fi
BPEOF
ok "Kiosk loop added to ~/.bash_profile (tty1 only, SSH-safe)"

# --- passwordless sudo ---
echo "$PI_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/kiosk-nopasswd > /dev/null
sudo chmod 440 /etc/sudoers.d/kiosk-nopasswd
ok "sudo passwordless configured for $PI_USER"

# =============================================
# [5/6] הגדרות תצוגה
# =============================================
step 5 "Configuring Display Settings"
sudo raspi-config nonint do_blanking 1
ok "Screen blanking disabled"
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
import os
T='$THEME_DIR'
Image.new('RGB',(1920,1080),(13,27,42)).save(f'{T}/background.png')
fps=['/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
     '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf']
fm=fs=None
for fp in fps:
    if os.path.exists(fp): fm=ImageFont.truetype(fp,96); fs=ImageFont.truetype(fp,28); break
if not fm: fm=fs=ImageFont.load_default()
probe=Image.new('RGBA',(1,1)); d=ImageDraw.Draw(probe)
bb=d.textbbox((0,0),'ADVISION',font=fm); tw=bb[2]-bb[0]; th=bb[3]-bb[1]
sb=d.textbbox((0,0),'Digital Signage',font=fs); sw=sb[2]-sb[0]
pad=30; lw=max(tw,sw)+pad*2; lh=th+50+pad*2
logo=Image.new('RGBA',(lw,lh),(0,0,0,0)); dl=ImageDraw.Draw(logo)
ab=dl.textbbox((0,0),'ADV',font=fm); aw=ab[2]-ab[0]
dl.text((pad,pad),'ADV',fill=(220,230,240,255),font=fm)
dl.text((pad+aw,pad),'ISION',fill=(76,201,240,255),font=fm)
dl.text(((lw-sw)//2,pad+th+14),'Digital Signage',fill=(80,120,160,200),font=fs)
logo.save(f'{T}/logo.png')
Image.new('RGB',(1,1),(76,201,240)).save(f'{T}/bar_fill.png')
Image.new('RGB',(1,1),(25,45,65)).save(f'{T}/bar_bg.png')
print('  Images generated')
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
screen_w = Window.GetWidth();
screen_h = Window.GetHeight();
bg = Sprite(Image("background.png"));
bg.SetX(0); bg.SetY(0); bg.SetZ(-100);
logo_img = Image("logo.png");
logo_w = logo_img.GetWidth(); logo_h = logo_img.GetHeight();
logo = Sprite(logo_img);
logo.SetX(Math.Int(screen_w/2 - logo_w/2));
logo.SetY(Math.Int(screen_h/2 - logo_h/2 - 50));
logo.SetZ(10);
bar_w=500; bar_h=10;
bar_x=Math.Int(screen_w/2 - bar_w/2);
bar_y=Math.Int(screen_h/2 + logo_h/2 + 20);
bar_bg_spr=Sprite(Image("bar_bg.png").Scale(bar_w,bar_h));
bar_bg_spr.SetX(bar_x); bar_bg_spr.SetY(bar_y); bar_bg_spr.SetZ(9);
bar_1px=Image("bar_fill.png");
prog=Sprite(); prog.SetX(bar_x); prog.SetY(bar_y); prog.SetZ(10); prog.SetOpacity(0);
fun ProgressCallback(d,p){
    w=Math.Int(bar_w*p); if(w<4){w=4;}
    prog.SetImage(bar_1px.Scale(w,bar_h)); prog.SetOpacity(1);
}
Plymouth.SetBootProgressFunction(ProgressCallback);
PLEOF

ok "Theme files created"

sudo plymouth-set-default-theme advision
ok "Theme set as default"

echo "  Rebuilding initramfs (~30s)..."
sudo update-initramfs -u -k all 2>/dev/null \
    && ok "initramfs rebuilt" \
    || warn "initramfs failed — Plymouth may not show on boot"

# cmdline.txt
CMDLINE="/boot/firmware/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE="/boot/cmdline.txt"
if [ -f "$CMDLINE" ] && ! grep -q "splash" "$CMDLINE"; then
    sudo sed -i 's/$/ quiet splash loglevel=0 logo.nologo/' "$CMDLINE"
    ok "cmdline.txt: quiet splash added"
fi

# config.txt
CONFIG="/boot/firmware/config.txt"
[ -f "$CONFIG" ] || CONFIG="/boot/config.txt"
if [ -f "$CONFIG" ]; then
    grep -q "disable_splash" "$CONFIG" \
        || echo "disable_splash=1" | sudo tee -a "$CONFIG" > /dev/null
    ok "config.txt: rainbow splash disabled"
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

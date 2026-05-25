import subprocess
import time
import os
import pwd
import urllib.request
import logging
import signal
import sys
import threading
import http.server
import json

# ===================== הגדרות =====================
SCREEN_ID       = "SCREEN_ID_PLACEHOLDER"
SCREEN_ROTATION = "ROTATION_PLACEHOLDER"   # 0=normal 1=90° 2=180° 3=270°

# מיפוי ממספר ה-installer לערך wlroots
ROTATION_MAP = {"0": "normal", "1": "90", "2": "180", "3": "270"}

# מזהה המשתמש שמריץ את התהליך
try:
    PI_USER  = pwd.getpwuid(os.getuid()).pw_name
except Exception:
    PI_USER  = os.environ.get("USER", "pi")

HOME_DIR     = f"/home/{PI_USER}"
LOG_FILE     = f"{HOME_DIR}/kiosk.log"
PORTAL_PORT  = 8080
HOTSPOT_SSID = "Advision-Setup"
HOTSPOT_CON  = "advision-hotspot"
HOTSPOT_IP   = "10.42.0.1"
PANEL_URL    = f"https://panel.advision360.co.il/display?screenId={SCREEN_ID}&prod=true"
WIFI_TV_URL  = f"http://localhost:{PORTAL_PORT}/wifi_screen.html"

# ===================== לוגינג =====================
os.makedirs(HOME_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.info

# ===================== זיהוי Chromium =====================
def _detect_chromium():
    pkg_file = f"{HOME_DIR}/.chromium_pkg"
    if os.path.exists(pkg_file):
        name = open(pkg_file).read().strip()
        if name:
            return name
    for name in ("chromium", "chromium-browser"):
        if os.path.exists(f"/usr/bin/{name}"):
            return name
    return "chromium"

CHROMIUM_BIN = _detect_chromium()

# ===================== HTTP PORTAL =====================

class PortalHandler(http.server.SimpleHTTPRequestHandler):
    """מגיש קבצים סטטיים + API endpoints לניהול WiFi"""

    def do_GET(self):
        if self.path.startswith("/api/networks"):
            self._networks()
        elif self.path.startswith("/api/status"):
            self._status()
        elif self.path in ("/", "/index.html"):
            self.path = "/wifi_setup.html"
            super().do_GET()
        else:
            # Captive portal redirect — phones that try any URL get the portal
            if not self.path.startswith("/wifi_setup") and not self.path.startswith("/wifi_screen") and not self.path.startswith("/wifi_qr"):
                self.send_response(302)
                self.send_header("Location", f"http://{HOTSPOT_IP}:{PORTAL_PORT}/wifi_setup.html")
                self.end_headers()
                return
            super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/connect"):
            self._connect()

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    # --- רשימת רשתות ---
    def _networks(self):
        try:
            r = subprocess.run(
                ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes"],
                capture_output=True, text=True, timeout=20,
            )
            nets, seen = [], set()
            for line in r.stdout.strip().splitlines():
                parts = line.split(":")
                ssid = parts[0].strip()
                if not ssid or ssid == HOTSPOT_SSID or ssid in seen:
                    continue
                seen.add(ssid)
                sig  = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
                sec  = bool(parts[2].strip()) if len(parts) > 2 else False
                nets.append({"ssid": ssid, "signal": sig, "secured": sec})
            nets.sort(key=lambda x: x["signal"], reverse=True)
            self._json(nets)
        except Exception as e:
            self._json({"error": str(e)}, 500)

    # --- סטטוס חיבור ---
    def _status(self):
        self._json({"connected": check_internet()})

    # --- התחברות לרשת ---
    def _connect(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            ssid   = body.get("ssid", "").strip()
            pwd_   = body.get("password", "").strip()

            if not ssid:
                self._json({"success": False, "message": "SSID ריק"}, 400)
                return

            log(f"WiFi connect request → {ssid}")
            # שלח תשובה מיידית — ה-hotspot ייסגר ברקע
            self._json({"success": True, "message": "מתחבר...", "connecting": True})

            def _do():
                time.sleep(0.5)
                subprocess.run(["sudo", "nmcli", "connection", "down",   HOTSPOT_CON], capture_output=True)
                subprocess.run(["sudo", "nmcli", "connection", "delete", HOTSPOT_CON], capture_output=True)
                time.sleep(2)
                cmd = ["sudo", "nmcli", "device", "wifi", "connect", ssid]
                if pwd_:
                    cmd += ["password", pwd_]
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                log(f"nmcli result ({result.returncode}): {result.stdout.strip()}")

            threading.Thread(target=_do, daemon=True).start()

        except Exception as e:
            log(f"Connect error: {e}")
            self._json({"success": False, "message": str(e)}, 500)

    # --- עזרים ---
    def _json(self, data, code=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin",  "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, *args):
        pass  # שתיקת לוגים


def start_portal_server():
    os.chdir(HOME_DIR)
    httpd = http.server.HTTPServer(("0.0.0.0", PORTAL_PORT), PortalHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"Portal server listening on :{PORTAL_PORT}")

# ===================== WIFI HOTSPOT =====================

def create_hotspot():
    log(f"Creating WiFi hotspot: {HOTSPOT_SSID}")
    subprocess.run(["sudo", "nmcli", "connection", "delete", HOTSPOT_CON], capture_output=True)
    r = subprocess.run([
        "sudo", "nmcli", "device", "wifi", "hotspot",
        "ssid", HOTSPOT_SSID, "band", "bg", "con-name", HOTSPOT_CON,
        "password", "advision1",
    ], capture_output=True, text=True)

    if r.returncode == 0:
        # Captive portal: redirect port 80 → portal port
        subprocess.run([
            "sudo", "iptables", "-t", "nat", "-A", "PREROUTING",
            "-i", "wlan0", "-p", "tcp", "--dport", "80",
            "-j", "REDIRECT", "--to-port", str(PORTAL_PORT),
        ], capture_output=True)
        log("Hotspot ready — iptables redirect active")
        return True

    log(f"Hotspot failed: {r.stderr.strip()}")
    return False


def stop_hotspot():
    subprocess.run(["sudo", "nmcli", "connection", "down",   HOTSPOT_CON], capture_output=True)
    subprocess.run(["sudo", "nmcli", "connection", "delete", HOTSPOT_CON], capture_output=True)
    subprocess.run([
        "sudo", "iptables", "-t", "nat", "-D", "PREROUTING",
        "-i", "wlan0", "-p", "tcp", "--dport", "80",
        "-j", "REDIRECT", "--to-port", str(PORTAL_PORT),
    ], capture_output=True)
    log("Hotspot stopped")

# ===================== KIOSK =====================

def build_cage_cmd(url):
    env = os.environ.copy()
    wlr = ROTATION_MAP.get(str(SCREEN_ROTATION), "normal")
    if wlr != "normal":
        env["WLR_OUTPUT_TRANSFORM"] = wlr

    # וודא שה-XDG_RUNTIME_DIR מוגדר
    if not env.get("XDG_RUNTIME_DIR"):
        xdg = f"/run/user/{os.getuid()}"
        if os.path.isdir(xdg):
            env["XDG_RUNTIME_DIR"] = xdg

    cmd = [
        "cage", "--",
        CHROMIUM_BIN,
        "--kiosk",
        "--noerrdialogs",
        "--disable-infobars",
        "--autoplay-policy=no-user-gesture-required",
        "--enable-features=VaapiVideoDecoder",
        "--ozone-platform=wayland",
        "--disk-cache-dir=/dev/null",
        url,
    ]
    return cmd, env


def check_internet():
    for url in (
        "https://panel.advision360.co.il",
        "https://www.google.com",
        "https://1.1.1.1",
    ):
        try:
            urllib.request.urlopen(url, timeout=5)
            return True
        except Exception:
            continue
    return False


def run_wifi_setup():
    """מציג פורטל WiFi על המסך + hotspot לטלפון"""
    log("No internet — starting WiFi setup...")
    if not create_hotspot():
        log("Hotspot creation failed, retrying in 20s")
        time.sleep(20)
        return

    cmd, env = build_cage_cmd(WIFI_TV_URL)
    portal_proc = subprocess.Popen(cmd, env=env)
    log(f"WiFi portal screen open. Phone: http://{HOTSPOT_IP}:{PORTAL_PORT}")

    # המתן עד שיש אינטרנט
    while not check_internet():
        if portal_proc.poll() is not None:
            # cage קרס — הפעל מחדש
            portal_proc = subprocess.Popen(cmd, env=env)
        time.sleep(5)

    log("Internet connected!")
    stop_hotspot()
    portal_proc.terminate()
    try:
        portal_proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        portal_proc.kill()
    time.sleep(3)


def launch_kiosk():
    log(f"Launching kiosk → {PANEL_URL}")
    cmd, env = build_cage_cmd(PANEL_URL)
    return subprocess.Popen(cmd, env=env)


def handle_exit(sig, frame):
    log("Shutdown signal — exiting.")
    stop_hotspot()
    sys.exit(0)

# ===================== MAIN =====================

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_exit)
    signal.signal(signal.SIGINT,  handle_exit)

    log("=" * 52)
    log(f" Advision Kiosk  |  Screen: {SCREEN_ID}  |  Rotation: {SCREEN_ROTATION}")
    log("=" * 52)

    start_portal_server()

    log("Waiting 10s for system to initialize...")
    time.sleep(10)

    # שלב 1 — וודא חיבור אינטרנט
    while not check_internet():
        run_wifi_setup()

    # שלב 2 — הפעל כיוסק
    kiosk = launch_kiosk()

    # שלב 3 — ניטור
    while True:
        if kiosk.poll() is not None:
            log("Kiosk exited unexpectedly — restarting...")
            while not check_internet():
                run_wifi_setup()
            kiosk = launch_kiosk()
        time.sleep(30)

#!/bin/bash
# update.sh — עדכון Kiosk Manager למסכים שכבר הותקנו
# בטוח לריצה חוזרת (idempotent). אינו מריץ apt update מלא ואינו משנה הגדרות מסך.

USB_PATH=$(pwd | tr -d '\r')
PI_USER=$(whoami | tr -d '\r')
HOME_DIR="/home/$PI_USER"
PY_FILE="kiosk_manager.py"

echo "================================================"
echo "   Kiosk Manager Update Script"
echo "================================================"

# ── 1. התקנת חבילות מערכת חדשות שנדרשו בעדכון ───────────────────────────────
echo "[1/5] Installing new required packages (network-manager, psmisc)..."
# ללא apt update — מהיר יותר ובטוח יותר למסכים פעילים
sudo apt install -y network-manager psmisc

# הפעלת NetworkManager אם לא פעיל (בטוח לריצה חוזרת)
if ! systemctl is-active --quiet NetworkManager; then
    echo "  → Activating NetworkManager (replacing dhcpcd)..."
    sudo systemctl disable dhcpcd 2>/dev/null || true
    sudo systemctl enable NetworkManager
    sudo systemctl start NetworkManager
else
    echo "  → NetworkManager: already active. Skipping."
fi

# ── 2. עצירת הסקריפט הנוכחי ────────────────────────────────────────────────
echo "[2/5] Stopping current kiosk process..."
# עוצר גם גרסה ישנה (autostart) וגם חדשה (systemd service)
systemctl --user stop kiosk.service 2>/dev/null || true
pkill -f "kiosk_manager.py" 2>/dev/null || true
sleep 2

# ── 3. עדכון קובץ Python ────────────────────────────────────────────────────
echo "[3/5] Deploying new kiosk_manager.py..."
cp "$USB_PATH/$PY_FILE" "$HOME_DIR/"
chmod +x "$HOME_DIR/$PY_FILE"
echo "  → Copied to $HOME_DIR/$PY_FILE"

# ── 4. מעבר מ-autostart ל-systemd user service ──────────────────────────────
echo "[4/5] Upgrading from autostart to systemd user service..."

# הסרת autostart ישן
if [ -f "$HOME_DIR/.config/autostart/kiosk.desktop" ]; then
    rm -f "$HOME_DIR/.config/autostart/kiosk.desktop"
    echo "  → Removed old autostart entry."
else
    echo "  → No old autostart entry found."
fi

# יצירת/עדכון קובץ ה-service
mkdir -p "$HOME_DIR/.config/systemd/user"
cat <<EOF > "$HOME_DIR/.config/systemd/user/kiosk.service"
[Unit]
Description=Kiosk Manager - Digital Signage Watchdog
After=graphical-session.target
Wants=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 $HOME_DIR/$PY_FILE
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_RUNTIME_DIR=/run/user/%U

[Install]
WantedBy=graphical-session.target
EOF

# הפעלת service — תומך גם בחיבור SSH (DBUS_SESSION_BUS_ADDRESS ידני)
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable kiosk.service 2>/dev/null || true
systemctl --user restart kiosk.service 2>/dev/null || true
sudo loginctl enable-linger "$PI_USER"
echo "  → systemd service enabled and started."

# ── 5. הגדרת journald persistent (אם עדיין לא הוגדר) ────────────────────────
echo "[5/5] Configuring persistent logging..."
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal

sudo mkdir -p /etc/systemd/journald.conf.d
if [ ! -f /etc/systemd/journald.conf.d/kiosk.conf ]; then
    cat <<'EOF' | sudo tee /etc/systemd/journald.conf.d/kiosk.conf
[Journal]
SystemMaxUse=50M
SystemKeepFree=100M
MaxFileSec=1month
RuntimeMaxUse=10M
EOF
    sudo systemctl restart systemd-journald
    echo "  → journald configured."
else
    echo "  → journald already configured. Skipping."
fi

echo ""
echo "================================================"
echo "   UPDATE COMPLETE — no reboot required!"
echo ""
echo "   Check live logs:"
echo "   journalctl -u kiosk -f"
echo ""
echo "   Check service status:"
echo "   systemctl --user status kiosk"
echo "================================================"

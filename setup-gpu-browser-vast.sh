#!/usr/bin/env bash
# GPU Browser Stack - Vast.ai / Headless NVIDIA
# Xorg + NVIDIA OpenGL + Chrome ANGLE + WebGL/WebGPU + x11vnc + noVNC
# Container-friendly: no systemd required.

set -Eeuo pipefail

APP_DIR="/opt/gpu-browser"
LOG_DIR="/var/log/gpu-browser"
RUN_DIR="/run/gpu-browser"
XORG_CONF="/etc/X11/xorg.conf"
DISPLAY_NUM=":0"
WIDTH=1920
HEIGHT=1080
VNC_PORT=5900
NOVNC_PORT=6080
VNC_PASSFILE="$APP_DIR/vnc.pass"

say(){ printf '%s\n' "$*"; }
info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

LANG_MODE="en"
if [[ -t 0 ]]; then
  echo "============================================================"
  echo " GPU BROWSER STACK / VAST.AI"
  echo "============================================================"
  echo "Language / Dil:"
  echo "  1) Türkçe"
  echo "  2) English"
  read -r -p "Seçim / Choice [1-2]: " choice || true
  [[ "$choice" == "1" ]] && LANG_MODE="tr"
fi

if [[ "$LANG_MODE" == "tr" ]]; then
  T_TITLE="GPU Browser Stack - Vast.ai"
  T_ROOT="Bu script root olarak çalıştırılmalı."
  T_START="Kurulum başlıyor. Her adımda ne yapıldığını göstereceğim."
  T_GPU="NVIDIA ortamı kontrol ediliyor..."
  T_PKGS="Gerekli paketler kontrol ediliyor/kuruluyor..."
  T_XORG="Xorg sanal ekranı hazırlanıyor..."
  T_VNC="VNC güvenliği hazırlanıyor..."
  T_EXIST="Mevcut VNC şifresi bulundu. Korunuyor."
  T_PASS="VNC şifrenizi belirleyin. En fazla 8 karakter."
  T_PASS1="VNC şifresi (maks. 8 karakter): "
  T_PASS2="Şifreyi tekrar girin: "
  T_EMPTY="Şifre boş olamaz."
  T_LONG="Şifre en fazla 8 karakter olabilir."
  T_MISMATCH="Şifreler eşleşmiyor. Tekrar deneyin."
  T_CHROME="Chrome GPU hızlandırma ile başlatılıyor..."
  T_VNCSTART="x11vnc başlatılıyor (sadece localhost)..."
  T_NOVNC="noVNC/websockify başlatılıyor (sadece localhost)..."
  T_WATCH="Watchdog başlatılıyor; çöken servisleri yeniden ayağa kaldıracak."
  T_DONE="Kurulum tamamlandı."
  T_DISCONNECT="SSH bağlantısını kapatsanız bile işlemler çalışmaya devam eder."
  T_REBOOT="Container tamamen yeniden başlarsa bu scripti tekrar çalıştırmanız gerekir."
  T_HELP="Yönetim komutları"
  T_TUNNEL="Kendi bilgisayarınızdan SSH tunnel açın"
  T_OPEN="Sonra tarayıcıdan açın"
else
  T_TITLE="GPU Browser Stack - Vast.ai"
  T_ROOT="This script must be run as root."
  T_START="Setup is starting. I will explain each step as it runs."
  T_GPU="Checking the NVIDIA environment..."
  T_PKGS="Checking/installing required packages..."
  T_XORG="Preparing the virtual Xorg display..."
  T_VNC="Preparing VNC security..."
  T_EXIST="An existing VNC password was found. Keeping it."
  T_PASS="Choose your VNC password. Maximum 8 characters."
  T_PASS1="VNC password (max 8 characters): "
  T_PASS2="Confirm password: "
  T_EMPTY="Password cannot be empty."
  T_LONG="Password must be 8 characters or less."
  T_MISMATCH="Passwords do not match. Try again."
  T_CHROME="Starting Chrome with GPU acceleration..."
  T_VNCSTART="Starting x11vnc (localhost only)..."
  T_NOVNC="Starting noVNC/websockify (localhost only)..."
  T_WATCH="Starting watchdog; it will restart managed processes if they die."
  T_DONE="Setup complete."
  T_DISCONNECT="The processes continue running after you close SSH."
  T_REBOOT="After a full container/instance restart, run this script again."
  T_HELP="Management commands"
  T_TUNNEL="Open an SSH tunnel from your own computer"
  T_OPEN="Then open in your browser"
fi

[[ $EUID -eq 0 ]] || die "$T_ROOT"
mkdir -p "$APP_DIR" "$LOG_DIR" "$RUN_DIR"
umask 077

info "$T_START"

# ------------------------- dependency helpers -------------------------
install_packages(){
  local missing=() pkg
  for pkg in "$@"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    info "apt: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${missing[@]}"
  fi
}

pid_ok(){
  local f="$1" p
  [[ -s "$f" ]] || return 1
  p=$(cat "$f" 2>/dev/null || true)
  [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null
}

kill_pidfile(){
  local f="$1" p
  if [[ -s "$f" ]]; then
    p=$(cat "$f" 2>/dev/null || true)
    if [[ "$p" =~ ^[0-9]+$ ]]; then kill "$p" 2>/dev/null || true; sleep 1; kill -9 "$p" 2>/dev/null || true; fi
  fi
  rm -f "$f"
}

# ------------------------- NVIDIA detection -------------------------
info "$T_GPU"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found. NVIDIA driver is required."
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 | xargs)
GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | xargs)
GPU_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | head -n1 | xargs)
[[ -n "$GPU_NAME" && -n "$GPU_PCI" ]] || die "Could not detect NVIDIA GPU."
ok "GPU: $GPU_NAME"
ok "Driver: $GPU_DRIVER"
ok "PCI: $GPU_PCI"

# NVIDIA driver is deliberately NOT installed/replaced by this script.
NVIDIA_DRV=$(find /usr/lib /usr/lib64 -type f -path '*/nvidia/xorg/nvidia_drv.so' -print -quit 2>/dev/null || true)
[[ -n "$NVIDIA_DRV" ]] || die "NVIDIA Xorg driver (nvidia_drv.so) not found."

# Convert 00000000:5E:00.0 -> PCI:94:0:0
PCI_NO_DOMAIN="${GPU_PCI#*:}"
PCI_BUS_HEX="${PCI_NO_DOMAIN%%:*}"
PCI_DEVFUNC="${PCI_NO_DOMAIN##*:}"
PCI_DEV_HEX="${PCI_DEVFUNC%%.*}"
PCI_FUNC="${PCI_DEVFUNC#*.}"
XORG_BUSID="PCI:$((16#$PCI_BUS_HEX)):$((16#$PCI_DEV_HEX)):$((16#$PCI_FUNC))"
ok "Xorg BusID: $XORG_BUSID"

# ------------------------- packages -------------------------
info "$T_PKGS"
install_packages xorg xserver-xorg-core x11vnc x11-utils mesa-utils dbus-x11 curl wget ca-certificates procps psmisc net-tools novnc python3-websockify

XORG_BIN=$(command -v Xorg || command -v X || true)
WEBSOCKIFY=$(command -v websockify || true)
CHROME=/usr/bin/google-chrome
[[ -n "$XORG_BIN" ]] || die "Xorg not found after installation."
[[ -n "$WEBSOCKIFY" ]] || die "websockify not found after installation."
[[ -x "$CHROME" ]] || die "Google Chrome not found at $CHROME."

NOVNC_WEB=""
for d in /usr/share/novnc /usr/share/noVNC /usr/share/novnc/web /usr/share/noVNC/web /opt/novnc /opt/noVNC; do
  if [[ -f "$d/vnc.html" ]]; then NOVNC_WEB="$d"; break; fi
done
if [[ -z "$NOVNC_WEB" ]]; then
  v=$(find /usr/share /usr/lib /opt -type f -name vnc.html -print -quit 2>/dev/null || true)
  [[ -n "$v" ]] && NOVNC_WEB=$(dirname "$v")
fi
[[ -n "$NOVNC_WEB" ]] || die "noVNC vnc.html could not be found."
ok "noVNC: $NOVNC_WEB"

# ------------------------- Xorg -------------------------
info "$T_XORG"
cat > "$XORG_CONF" <<EOF
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection

Section "Device"
    Identifier "Device0"
    Driver "nvidia"
    BusID "$XORG_BUSID"
    Option "AllowEmptyInitialConfiguration" "True"
    Option "UseDisplayDevice" "None"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual $WIDTH $HEIGHT
    EndSubSection
EndSection
EOF
ok "Xorg config: $XORG_CONF"

# ------------------------- VNC password -------------------------
info "$T_VNC"
if [[ -s "$VNC_PASSFILE" ]]; then
  chmod 600 "$VNC_PASSFILE"
  ok "$T_EXIST"
else
  say "$T_PASS"
  while true; do
    read -r -s -p "$T_PASS1" P1; echo
    read -r -s -p "$T_PASS2" P2; echo
    [[ -n "$P1" ]] || { warn "$T_EMPTY"; continue; }
    [[ ${#P1} -le 8 ]] || { warn "$T_LONG"; continue; }
    [[ "$P1" == "$P2" ]] || { warn "$T_MISMATCH"; continue; }
    break
  done
  x11vnc -storepasswd "$P1" "$VNC_PASSFILE" >/dev/null
  unset P1 P2
  chmod 600 "$VNC_PASSFILE"
  [[ -s "$VNC_PASSFILE" ]] || die "VNC password file could not be created."
  ok "VNC password saved securely: $VNC_PASSFILE"
fi

# ------------------------- launchers -------------------------
cat > "$APP_DIR/start-chrome.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
exec /usr/bin/google-chrome \
  --no-sandbox \
  --disable-dev-shm-usage \
  --user-data-dir=/opt/gpu-browser/chrome-profile \
  --ozone-platform=x11 \
  --use-gl=angle \
  --use-angle=gl \
  --enable-gpu \
  --ignore-gpu-blocklist \
  --disable-software-rasterizer \
  --enable-webgl \
  --enable-webgl2 \
  --enable-gpu-rasterization \
  --enable-unsafe-webgpu \
  --no-first-run \
  --no-default-browser-check \
  about:blank
EOF
chmod 755 "$APP_DIR/start-chrome.sh"
mkdir -p "$APP_DIR/chrome-profile"

cat > "$APP_DIR/start-stack.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR=/opt/gpu-browser
RUN_DIR=/run/gpu-browser
LOG_DIR=/var/log/gpu-browser
mkdir -p "$RUN_DIR" "$LOG_DIR"
if [[ -s "$RUN_DIR/watchdog.pid" ]]; then
  p=$(cat "$RUN_DIR/watchdog.pid" 2>/dev/null || true)
  if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then
    echo "GPU browser watchdog already running: PID $p"
    exit 0
  fi
fi
nohup "$APP_DIR/watchdog.sh" >> "$LOG_DIR/watchdog.log" 2>&1 &
echo $! > "$RUN_DIR/watchdog.pid"
echo "GPU browser watchdog started: PID $!"
EOF
chmod 755 "$APP_DIR/start-stack.sh"

cat > "$APP_DIR/stop-stack.sh" <<'EOF'
#!/usr/bin/env bash
set -u
RUN_DIR=/run/gpu-browser
for f in watchdog.pid chrome.pid novnc.pid x11vnc.pid xorg.pid; do
  pfile="$RUN_DIR/$f"
  if [[ -s "$pfile" ]]; then
    p=$(cat "$pfile" 2>/dev/null || true)
    [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null || true
    rm -f "$pfile"
  fi
done
echo "GPU browser stack stopped."
EOF
chmod 755 "$APP_DIR/stop-stack.sh"

# ------------------------- watchdog -------------------------
cat > "$APP_DIR/watchdog.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP=/opt/gpu-browser
RUN=/run/gpu-browser
LOG=/var/log/gpu-browser
DISPLAY=:0
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG/watchdog.log"; }
alive(){ local f=$1 p; [[ -s "$f" ]] || return 1; p=$(cat "$f" 2>/dev/null || true); [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; }
start_x(){
  if alive "$RUN/xorg.pid" && DISPLAY=$DISPLAY xdpyinfo >/dev/null 2>&1; then return; fi
  log 'Starting/restarting Xorg.'
  rm -f "$RUN/xorg.pid" /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
  nohup "$(command -v Xorg)" "$DISPLAY" -config /etc/X11/xorg.conf -noreset -nolisten tcp -logfile "$LOG/xorg.log" >/dev/null 2>&1 &
  echo $! > "$RUN/xorg.pid"
  for _ in {1..30}; do DISPLAY=$DISPLAY xdpyinfo >/dev/null 2>&1 && return; sleep 1; done
  log 'Xorg did not become ready.'
}
start_vnc(){
  if alive "$RUN/x11vnc.pid" && ss -ltn 2>/dev/null | grep -q ':5900'; then return; fi
  log 'Starting/restarting x11vnc.'
  rm -f "$RUN/x11vnc.pid"
  nohup x11vnc -display "$DISPLAY" -localhost -forever -shared -noxdamage -rfbauth "$APP/vnc.pass" -rfbport 5900 >> "$LOG/x11vnc.log" 2>&1 &
  echo $! > "$RUN/x11vnc.pid"
}
start_novnc(){
  if alive "$RUN/novnc.pid" && ss -ltn 2>/dev/null | grep -q ':6080'; then return; fi
  local web='' f='' ws=''
  for d in /usr/share/novnc /usr/share/noVNC /usr/share/novnc/web /usr/share/noVNC/web /opt/novnc /opt/noVNC; do [[ -f "$d/vnc.html" ]] && web="$d" && break; done
  [[ -n "$web" ]] || { f=$(find /usr/share /usr/lib /opt -type f -name vnc.html -print -quit 2>/dev/null || true); [[ -n "$f" ]] && web=$(dirname "$f"); }
  ws=$(command -v websockify || true)
  [[ -n "$web" && -n "$ws" ]] || { log 'noVNC/websockify unavailable.'; return; }
  log 'Starting/restarting noVNC.'
  rm -f "$RUN/novnc.pid"
  nohup "$ws" --web="$web" 127.0.0.1:6080 127.0.0.1:5900 >> "$LOG/novnc.log" 2>&1 &
  echo $! > "$RUN/novnc.pid"
}
start_chrome(){
  if alive "$RUN/chrome.pid"; then return; fi
  log 'Starting/restarting Chrome.'
  rm -f "$RUN/chrome.pid"
  nohup "$APP/start-chrome.sh" >> "$LOG/chrome.log" 2>&1 &
  echo $! > "$RUN/chrome.pid"
}
log 'Watchdog started.'
while true; do
  start_x || true
  sleep 2
  start_vnc || true
  start_novnc || true
  start_chrome || true
  sleep 5
done
EOF
chmod 755 "$APP_DIR/watchdog.sh"

# ------------------------- management commands -------------------------
cat > /usr/local/bin/gpu-browser-status <<'EOF'
#!/usr/bin/env bash
set -u
RUN=/run/gpu-browser
APP=/opt/gpu-browser
DISPLAY=:0
echo '============================================================'
echo ' GPU BROWSER STATUS'
echo '============================================================'
nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null || true
echo
echo 'Processes:'
for x in 'Xorg:xorg.pid' 'x11vnc:x11vnc.pid' 'noVNC:novnc.pid' 'Chrome:chrome.pid' 'Watchdog:watchdog.pid'; do
  n=${x%%:*}; f=$RUN/${x#*:}; p=$(cat "$f" 2>/dev/null || true)
  if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then echo "  [ OK ] $n PID $p"; else echo "  [FAIL] $n"; fi
done
echo
echo 'Display:'
DISPLAY=$DISPLAY xdpyinfo 2>/dev/null | grep dimensions || echo '  [FAIL] X display unavailable'
echo
echo 'OpenGL:'
DISPLAY=$DISPLAY glxinfo -B 2>/dev/null | grep -E 'OpenGL vendor|OpenGL renderer' || echo '  [FAIL] NVIDIA OpenGL unavailable'
echo
echo 'Ports:'
ss -ltn 2>/dev/null | grep -E ':5900|:6080' || echo '  [FAIL] VNC/noVNC not listening'
echo
echo 'noVNC: http://127.0.0.1:6080/vnc.html'
echo 'VNC password: protected file exists?'; [[ -s "$APP/vnc.pass" ]] && echo '  [ OK ] yes' || echo '  [FAIL] no'
EOF
chmod 755 /usr/local/bin/gpu-browser-status
ln -sf "$APP_DIR/stop-stack.sh" /usr/local/bin/gpu-browser-stop
ln -sf "$APP_DIR/start-stack.sh" /usr/local/bin/gpu-browser-start
cat > /usr/local/bin/gpu-browser-restart <<'EOF'
#!/usr/bin/env bash
set -e
/opt/gpu-browser/stop-stack.sh || true
sleep 2
/opt/gpu-browser/start-stack.sh
EOF
chmod 755 /usr/local/bin/gpu-browser-restart

# ------------------------- start -------------------------
info "Starting Xorg..."
kill_pidfile "$RUN_DIR/xorg.pid"
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
nohup "$XORG_BIN" "$DISPLAY_NUM" -config "$XORG_CONF" -noreset -nolisten tcp -logfile "$LOG_DIR/xorg.log" >/dev/null 2>&1 &
echo $! > "$RUN_DIR/xorg.pid"
for _ in {1..30}; do DISPLAY=$DISPLAY_NUM xdpyinfo >/dev/null 2>&1 && break; sleep 1; done
DISPLAY=$DISPLAY_NUM xdpyinfo >/dev/null 2>&1 || die "Xorg failed. Check $LOG_DIR/xorg.log"
DISPLAY=$DISPLAY_NUM glxinfo -B 2>/dev/null | grep -q 'NVIDIA Corporation' || die "NVIDIA OpenGL is not active. Check Xorg log."
ok "Xorg + NVIDIA OpenGL ready ($WIDTH x $HEIGHT)"

info "$T_VNCSTART"
kill_pidfile "$RUN_DIR/x11vnc.pid"
nohup x11vnc -display "$DISPLAY_NUM" -localhost -forever -shared -noxdamage -rfbauth "$VNC_PASSFILE" -rfbport "$VNC_PORT" >> "$LOG_DIR/x11vnc.log" 2>&1 &
echo $! > "$RUN_DIR/x11vnc.pid"
for _ in {1..15}; do ss -ltn 2>/dev/null | grep -q "127.0.0.1:$VNC_PORT" && break; sleep 1; done
ss -ltn 2>/dev/null | grep -q "127.0.0.1:$VNC_PORT" || die "x11vnc failed. Check $LOG_DIR/x11vnc.log"
ok "VNC listening on localhost:$VNC_PORT"

info "$T_NOVNC"
kill_pidfile "$RUN_DIR/novnc.pid"
nohup "$WEBSOCKIFY" --web="$NOVNC_WEB" "127.0.0.1:$NOVNC_PORT" "127.0.0.1:$VNC_PORT" >> "$LOG_DIR/novnc.log" 2>&1 &
echo $! > "$RUN_DIR/novnc.pid"
for _ in {1..15}; do ss -ltn 2>/dev/null | grep -q "127.0.0.1:$NOVNC_PORT" && break; sleep 1; done
ss -ltn 2>/dev/null | grep -q "127.0.0.1:$NOVNC_PORT" || die "noVNC failed. Check $LOG_DIR/novnc.log"
ok "noVNC listening on localhost:$NOVNC_PORT"

info "$T_CHROME"
kill_pidfile "$RUN_DIR/chrome.pid"
nohup "$APP_DIR/start-chrome.sh" >> "$LOG_DIR/chrome.log" 2>&1 &
echo $! > "$RUN_DIR/chrome.pid"
sleep 3
pid_ok "$RUN_DIR/chrome.pid" || die "Chrome failed. Check $LOG_DIR/chrome.log"
ok "Chrome running with ANGLE OpenGL + WebGL/WebGL2/WebGPU flags"

info "$T_WATCH"
kill_pidfile "$RUN_DIR/watchdog.pid"
nohup "$APP_DIR/watchdog.sh" >> "$LOG_DIR/watchdog.log" 2>&1 &
echo $! > "$RUN_DIR/watchdog.pid"
ok "Watchdog running: PID $(cat "$RUN_DIR/watchdog.pid")"

# ------------------------- final message -------------------------
echo
echo '============================================================'
echo " $T_DONE"
echo '============================================================'
echo
ok "GPU: $GPU_NAME"
ok "NVIDIA driver: $GPU_DRIVER"
ok "Display: $DISPLAY_NUM / ${WIDTH}x${HEIGHT}"
ok "OpenGL renderer: NVIDIA"
ok "VNC: 127.0.0.1:$VNC_PORT (password protected)"
ok "noVNC: 127.0.0.1:$NOVNC_PORT"
echo
echo "$T_TUNNEL:"
echo '  ssh -p <VAST_SSH_PORT> -L 6080:127.0.0.1:6080 root@<VAST_IP>'
echo
echo "$T_OPEN:"
echo '  http://127.0.0.1:6080/vnc.html'
echo
echo "$T_HELP:"
echo '  gpu-browser-status   -> durum / GPU / port kontrolü'
echo '  gpu-browser-start    -> watchdog başlat'
echo '  gpu-browser-stop     -> stacki durdur'
echo '  gpu-browser-restart  -> yeniden başlat'
echo
echo 'Log files:'
echo "  $LOG_DIR/xorg.log"
echo "  $LOG_DIR/x11vnc.log"
echo "  $LOG_DIR/novnc.log"
echo "  $LOG_DIR/chrome.log"
echo "  $LOG_DIR/watchdog.log"
echo
echo "$T_DISCONNECT"
echo "$T_REBOOT"
echo
echo 'IMPORTANT: NVIDIA driver packages were NOT installed, upgraded, purged, or replaced.'
echo '============================================================'

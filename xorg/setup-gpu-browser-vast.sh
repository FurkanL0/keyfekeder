#!/usr/bin/env bash
# GPU Browser Stack for Vast.ai / NVIDIA GPU containers
# Xorg + NVIDIA OpenGL + Chrome ANGLE OpenGL + WebGL/WebGPU
# x11vnc localhost-only + noVNC + watchdog
# Chrome runs as non-root user (sandbox remains enabled).
# NVIDIA driver packages are NEVER installed, upgraded, purged, or replaced by this script.

set -Eeuo pipefail

APP_DIR="/opt/gpu-browser"
LOG_DIR="/var/log/gpu-browser"
RUN_DIR="/run/gpu-browser"
XORG_CONF="/etc/X11/xorg.conf"
DISPLAY_NUM=":0"
DISPLAY=":0"
WIDTH=1920
HEIGHT=1080
VNC_PORT=5900
NOVNC_PORT=6080
VNC_PASSFILE="$APP_DIR/vnc.pass"
CHROME_USER="gpuchrome"
CHROME_HOME="/home/$CHROME_USER"

XORG_LOG="$LOG_DIR/xorg.log"
X11VNC_LOG="$LOG_DIR/x11vnc.log"
NOVNC_LOG="$LOG_DIR/novnc.log"
CHROME_LOG="$LOG_DIR/chrome.log"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"

XORG_PID="$RUN_DIR/xorg.pid"
X11VNC_PID="$RUN_DIR/x11vnc.pid"
NOVNC_PID="$RUN_DIR/novnc.pid"
CHROME_PID="$RUN_DIR/chrome.pid"
WATCHDOG_PID="$RUN_DIR/watchdog.pid"

LANG_CODE="en"
XORG_BIN=""
WEBSOCKIFY_BIN=""
NOVNC_WEB=""
CHROME_BIN="/usr/bin/google-chrome"
GPU_NAME=""
GPU_DRIVER=""
GPU_PCI=""
XORG_BUSID=""

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'

say() { printf '%s\n' "$*"; }
info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
die() { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }

tr() {
    if [[ "$LANG_CODE" == "tr" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

pause_info() { sleep 0.3; }

choose_language() {
    clear 2>/dev/null || true
    say "============================================================"
    say "        GPU BROWSER STACK / VAST.AI"
    say "============================================================"
    say ""
    say "Language / Dil:"
    say "  1) Türkçe"
    say "  2) English"
    say ""
    while true; do
        read -r -p "Seçim / Choice [1-2]: " choice
        case "$choice" in
            1) LANG_CODE="tr"; break;;
            2) LANG_CODE="en"; break;;
            *) say "Lütfen 1 veya 2 seçin / Please choose 1 or 2.";;
        esac
    done
    say ""
}

require_root() {
    [[ $EUID -eq 0 ]] || die "$(tr 'Bu script root olarak çalıştırılmalıdır.' 'This script must be run as root.')"
}

ensure_dirs() {
    mkdir -p "$APP_DIR" "$LOG_DIR" "$RUN_DIR"
    chmod 755 "$APP_DIR" "$LOG_DIR" "$RUN_DIR"
}

install_packages() {
    local missing=() p
    for p in "$@"; do
        if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
            missing+=("$p")
        fi
    done
    if ((${#missing[@]} == 0)); then
        return
    fi
    info "$(tr "Eksik paketler kuruluyor: ${missing[*]}" "Installing missing packages: ${missing[*]}")"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${missing[@]}"
}

find_nvidia_xorg_driver() {
    local candidates=(
        /usr/lib/x86_64-linux-gnu/nvidia/xorg/nvidia_drv.so
        /usr/lib/x86_64-linux-gnu/nvidia/current/nvidia_drv.so
        /usr/lib/x86_64-linux-gnu/nvidia/nvidia_drv.so
        /usr/lib/nvidia/xorg/nvidia_drv.so
        /usr/lib/nvidia/current/nvidia_drv.so
        /usr/lib/nvidia/nvidia_drv.so
        /usr/lib/xorg/modules/drivers/nvidia_drv.so
        /usr/lib64/nvidia/xorg/nvidia_drv.so
        /usr/lib64/nvidia/current/nvidia_drv.so
        /usr/lib64/nvidia/nvidia_drv.so
    )
    local p
    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    while IFS= read -r p; do
        [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done < <(find /usr/lib /usr/lib64 /lib /lib64 -type f -name nvidia_drv.so -print 2>/dev/null)
    return 1
}

check_nvidia() {
    command -v nvidia-smi >/dev/null 2>&1 || die "$(tr 'nvidia-smi bulunamadı. NVIDIA runtime bu containera verilmemiş olabilir.' 'nvidia-smi was not found. The NVIDIA runtime may not be exposed to this container.')"
    GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 | xargs)"
    GPU_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | xargs)"
    GPU_PCI="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | head -n1 | xargs)"
    [[ -n "$GPU_NAME" ]] || die "$(tr 'GPU modeli tespit edilemedi.' 'Could not detect GPU model.')"
    [[ -n "$GPU_PCI" ]] || die "$(tr 'GPU PCI adresi tespit edilemedi.' 'Could not detect GPU PCI address.')"
    ok "$(tr "GPU: $GPU_NAME" "GPU: $GPU_NAME")"
    ok "Driver: $GPU_DRIVER"
    ok "PCI: $GPU_PCI"

    local bus dev func
    bus="$(echo "$GPU_PCI" | awk -F: '{print $(NF-1)}')"
    dev="$(echo "$GPU_PCI" | awk -F: '{print $NF}' | cut -d. -f1)"
    func="$(echo "$GPU_PCI" | awk -F. '{print $NF}')"
    XORG_BUSID="PCI:$((16#$bus)):$((16#$dev)):$((16#$func))"
    info "$(tr "Xorg BusID: $XORG_BUSID" "Xorg BusID: $XORG_BUSID")"

    NVIDIA_XORG_DRIVER="$(find_nvidia_xorg_driver || true)"
    if [[ -z "$NVIDIA_XORG_DRIVER" ]]; then
        warn "$(tr 'nvidia-smi çalışıyor ancak nvidia_drv.so bulunamadı.' 'nvidia-smi works, but nvidia_drv.so was not found.')"
        info "$(tr 'Alternatif NVIDIA/Xorg yolları kontrol edildi.' 'Alternative NVIDIA/Xorg paths were checked.')"
        info "$(tr 'NVIDIA driver paketleri bilerek kurulmayacak veya değiştirilmeyecek.' 'NVIDIA driver packages will NOT be installed or replaced.')"
        say ""
        say "$(tr 'Bu Vast.ai image NVIDIA compute runtime sağlıyor olabilir ancak Xorg NVIDIA modülünü sağlamıyor.' 'This Vast.ai image may expose the NVIDIA compute runtime but not the NVIDIA Xorg module.')"
        say "$(tr 'Xorg için nvidia_drv.so gerekiyor. Farklı bir graphics-capable image kullanmanız gerekebilir.' 'Xorg requires nvidia_drv.so. A graphics-capable image may be required.')"
        die "$(tr 'NVIDIA Xorg modülü bulunamadığı için güvenli şekilde durduruluyor.' 'Stopping safely because the NVIDIA Xorg module is unavailable.')"
    fi
    ok "NVIDIA Xorg driver: $NVIDIA_XORG_DRIVER"
}

install_chrome_if_needed() {
    if [[ -x "$CHROME_BIN" ]]; then
        ok "$(tr 'Google Chrome zaten kurulu.' 'Google Chrome is already installed.')"
        "$CHROME_BIN" --version || true
        return
    fi

    info "$(tr 'Google Chrome bulunamadı. Google resmi Stable .deb paketi indiriliyor...' 'Google Chrome not found. Downloading the official Google Stable .deb...')"
    local deb=/tmp/google-chrome-stable_current_amd64.deb
    rm -f "$deb"
    command -v wget >/dev/null 2>&1 || install_packages wget ca-certificates
    wget -q --show-progress -O "$deb" 'https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb' || die "$(tr 'Chrome paketi indirilemedi.' 'Could not download Chrome package.')"
    info "$(tr 'Chrome kuruluyor...' 'Installing Chrome...')"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "$deb"
    rm -f "$deb"
    [[ -x "$CHROME_BIN" ]] || die "$(tr 'Chrome kurulumu doğrulanamadı.' 'Chrome installation could not be verified.')"
    ok "$(tr 'Google Chrome başarıyla kuruldu.' 'Google Chrome installed successfully.')"
    "$CHROME_BIN" --version || true
}

detect_novnc() {
    local d found
    for d in /usr/share/novnc /usr/share/noVNC /usr/share/novnc/web /usr/share/noVNC/web /opt/novnc /opt/noVNC; do
        if [[ -f "$d/vnc.html" ]]; then NOVNC_WEB="$d"; break; fi
    done
    if [[ -z "$NOVNC_WEB" ]]; then
        found="$(find /usr/share /usr/lib /opt -type f -name vnc.html -print -quit 2>/dev/null || true)"
        [[ -n "$found" ]] && NOVNC_WEB="$(dirname "$found")"
    fi
    if [[ -z "$NOVNC_WEB" ]]; then
        info "$(tr 'noVNC bulunamadı, paket kuruluyor...' 'noVNC not found, installing package...')"
        install_packages novnc
        found="$(find /usr/share /usr/lib /opt -type f -name vnc.html -print -quit 2>/dev/null || true)"
        [[ -n "$found" ]] && NOVNC_WEB="$(dirname "$found")"
    fi
    [[ -n "$NOVNC_WEB" ]] || die "$(tr 'noVNC kurulamadı veya vnc.html bulunamadı.' 'noVNC could not be installed or vnc.html was not found.')"
    ok "noVNC: $NOVNC_WEB"
}

setup_chrome_user() {
    if ! id "$CHROME_USER" >/dev/null 2>&1; then
        info "$(tr "Chrome için güvenli non-root kullanıcı oluşturuluyor: $CHROME_USER" "Creating secure non-root Chrome user: $CHROME_USER")"
        useradd --create-home --home-dir "$CHROME_HOME" --shell /bin/bash "$CHROME_USER"
    fi
    mkdir -p "$CHROME_HOME/.config" "$CHROME_HOME/.cache" "$APP_DIR/chrome-profile"
    chown -R "$CHROME_USER:$CHROME_USER" "$CHROME_HOME" "$APP_DIR/chrome-profile"
    chmod 700 "$CHROME_HOME"
    ok "$(tr "Chrome kullanıcı hesabı hazır: $CHROME_USER" "Chrome user ready: $CHROME_USER")"
}

setup_vnc_password() {
    if [[ -s "$VNC_PASSFILE" ]]; then
        chmod 600 "$VNC_PASSFILE"
        ok "$(tr 'Mevcut VNC şifresi korunuyor.' 'Existing VNC password will be kept.')"
        return
    fi
    say ""
    say "============================================================"
    say "$(tr 'VNC ŞİFRESİ' 'VNC PASSWORD')"
    say "============================================================"
    say "$(tr 'VNC bağlantısı şifre ile korunacaktır.' 'VNC access will be password protected.')"
    say "$(tr 'Maksimum uzunluk: 8 karakter.' 'Maximum length: 8 characters.')"
    say ""
    local p1 p2
    while true; do
        read -r -s -p "$(tr 'VNC şifresi (maks. 8 karakter): ' 'VNC password (max 8 characters): ')" p1; echo
        read -r -s -p "$(tr 'VNC şifresini tekrar girin: ' 'Confirm VNC password: ')" p2; echo
        if [[ -z "$p1" ]]; then warn "$(tr 'Şifre boş olamaz.' 'Password cannot be empty.')"; continue; fi
        if [[ ${#p1} -gt 8 ]]; then warn "$(tr 'Şifre en fazla 8 karakter olabilir.' 'Password must be at most 8 characters.')"; continue; fi
        if [[ "$p1" != "$p2" ]]; then warn "$(tr 'Şifreler eşleşmiyor.' 'Passwords do not match.')"; continue; fi
        break
    done
    x11vnc -storepasswd "$p1" "$VNC_PASSFILE" >/dev/null
    unset p1 p2
    chmod 600 "$VNC_PASSFILE"
    [[ -s "$VNC_PASSFILE" ]] || die "$(tr 'VNC şifre dosyası oluşturulamadı.' 'Could not create VNC password file.')"
    ok "$(tr 'VNC şifresi kaydedildi.' 'VNC password saved securely.')"
}

write_xorg_config() {
    cat > "$XORG_CONF" <<CFG
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection

Section "Device"
    Identifier "Device0"
    Driver "nvidia"
    BusID "${XORG_BUSID}"
    Option "AllowEmptyInitialConfiguration" "True"
    Option "UseDisplayDevice" "None"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual ${WIDTH} ${HEIGHT}
    EndSubSection
EndSection
CFG
    ok "$(tr "Xorg yapılandırması yazıldı: $XORG_CONF" "Xorg configuration written: $XORG_CONF")"
}

pid_alive() { local f="$1" p; [[ -s "$f" ]] || return 1; p="$(cat "$f" 2>/dev/null || true)"; [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; }
kill_pidfile() { local f="$1" p; if [[ -s "$f" ]]; then p="$(cat "$f" 2>/dev/null || true)"; [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null || true; sleep 1; [[ "$p" =~ ^[0-9]+$ ]] && kill -9 "$p" 2>/dev/null || true; fi; rm -f "$f"; }
stop_managed() { kill_pidfile "$CHROME_PID"; kill_pidfile "$NOVNC_PID"; kill_pidfile "$X11VNC_PID"; kill_pidfile "$WATCHDOG_PID"; kill_pidfile "$XORG_PID"; }

start_xorg() {
    if pid_alive "$XORG_PID" && DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1; then return; fi
    kill_pidfile "$XORG_PID"
    rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
    info "$(tr 'Xorg başlatılıyor...' 'Starting Xorg...')"
    nohup "$XORG_BIN" "$DISPLAY" -config "$XORG_CONF" -noreset -nolisten tcp -logfile "$XORG_LOG" >/dev/null 2>&1 &
    echo $! > "$XORG_PID"
    for _ in {1..30}; do DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1 && { ok "Xorg: $WIDTHx$HEIGHT"; return; }; sleep 1; done
    die "$(tr "Xorg başlatılamadı. Log: $XORG_LOG" "Xorg failed to start. Log: $XORG_LOG")"
}

start_x11vnc() {
    if pid_alive "$X11VNC_PID" && ss -ltn 2>/dev/null | grep -q "127.0.0.1:$VNC_PORT"; then return; fi
    kill_pidfile "$X11VNC_PID"
    info "$(tr 'x11vnc başlatılıyor (sadece localhost)...' 'Starting x11vnc (localhost-only)...')"
    nohup x11vnc -display "$DISPLAY" -localhost -forever -shared -noxdamage -rfbauth "$VNC_PASSFILE" -rfbport "$VNC_PORT" >> "$X11VNC_LOG" 2>&1 &
    echo $! > "$X11VNC_PID"
    for _ in {1..15}; do ss -ltn 2>/dev/null | grep -q "127.0.0.1:$VNC_PORT" && { ok "VNC: 127.0.0.1:$VNC_PORT"; return; }; sleep 1; done
    die "$(tr "x11vnc başlatılamadı. Log: $X11VNC_LOG" "x11vnc failed to start. Log: $X11VNC_LOG")"
}

start_novnc() {
    if pid_alive "$NOVNC_PID" && ss -ltn 2>/dev/null | grep -q "127.0.0.1:$NOVNC_PORT"; then return; fi
    kill_pidfile "$NOVNC_PID"
    WEBSOCKIFY_BIN="$(command -v websockify || true)"
    [[ -n "$WEBSOCKIFY_BIN" ]] || { install_packages python3-websockify; WEBSOCKIFY_BIN="$(command -v websockify || true)"; }
    [[ -n "$WEBSOCKIFY_BIN" ]] || die "$(tr 'websockify bulunamadı.' 'websockify was not found.')"
    info "$(tr 'noVNC başlatılıyor...' 'Starting noVNC...')"
    nohup "$WEBSOCKIFY_BIN" --web="$NOVNC_WEB" "127.0.0.1:$NOVNC_PORT" "127.0.0.1:$VNC_PORT" >> "$NOVNC_LOG" 2>&1 &
    echo $! > "$NOVNC_PID"
    for _ in {1..15}; do ss -ltn 2>/dev/null | grep -q "127.0.0.1:$NOVNC_PORT" && { ok "noVNC: http://127.0.0.1:$NOVNC_PORT/vnc.html"; return; }; sleep 1; done
    die "$(tr "noVNC başlatılamadı. Log: $NOVNC_LOG" "noVNC failed to start. Log: $NOVNC_LOG")"
}

write_chrome_launcher() {
    cat > "$APP_DIR/start-chrome.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export DISPLAY=":0"
export XDG_RUNTIME_DIR="/tmp/runtime-gpuchrome"
mkdir -p "\$XDG_RUNTIME_DIR"
chmod 700 "\$XDG_RUNTIME_DIR"
exec /usr/bin/google-chrome \\
  --user-data-dir="$APP_DIR/chrome-profile" \\
  --ozone-platform=x11 \\
  --use-gl=angle \\
  --use-angle=gl \\
  --enable-gpu \\
  --ignore-gpu-blocklist \\
  --disable-software-rasterizer \\
  --enable-webgl \\
  --enable-webgl2 \\
  --enable-gpu-rasterization \\
  --enable-unsafe-webgpu \\
  --no-first-run \\
  --no-default-browser-check \\
  about:blank
EOF
    chmod 755 "$APP_DIR/start-chrome.sh"
    chown root:root "$APP_DIR/start-chrome.sh"
}

start_chrome() {
    if pid_alive "$CHROME_PID"; then return; fi
    kill_pidfile "$CHROME_PID"
    info "$(tr 'Chrome non-root kullanıcı ile başlatılıyor (sandbox açık)...' 'Starting Chrome as non-root user (sandbox enabled)...')"
    mkdir -p /tmp/runtime-gpuchrome
    chown "$CHROME_USER:$CHROME_USER" /tmp/runtime-gpuchrome
    chmod 700 /tmp/runtime-gpuchrome
    : > "$CHROME_LOG"
    chown "$CHROME_USER:$CHROME_USER" "$CHROME_LOG"
    nohup runuser -u "$CHROME_USER" -- env DISPLAY="$DISPLAY" XDG_RUNTIME_DIR=/tmp/runtime-gpuchrome "$APP_DIR/start-chrome.sh" >> "$CHROME_LOG" 2>&1 &
    echo $! > "$CHROME_PID"
    sleep 5
    pid_alive "$CHROME_PID" || die "$(tr "Chrome başlatılamadı. Log: $CHROME_LOG" "Chrome failed to start. Log: $CHROME_LOG")"
    ok "$(tr 'Chrome çalışıyor: ANGLE OpenGL + sandbox' 'Chrome running: ANGLE OpenGL + sandbox')"
}

write_tools() {
    cat > /usr/local/bin/gpu-browser-status <<'STATUS_EOF'
#!/usr/bin/env bash
RUN_DIR=/run/gpu-browser
DISPLAY=:0
echo '============================================================'
echo ' GPU BROWSER STATUS'
echo '============================================================'
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null || true
echo
echo 'Processes:'
for x in 'Xorg:xorg.pid' 'x11vnc:x11vnc.pid' 'noVNC:novnc.pid' 'Chrome:chrome.pid' 'Watchdog:watchdog.pid'; do
  n=${x%%:*}; f=$RUN_DIR/${x#*:}; p=$(cat "$f" 2>/dev/null || true)
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
ss -ltn 2>/dev/null | grep -E ':5900|:6080' || echo '  [FAIL] VNC/noVNC ports unavailable'
echo
echo 'noVNC: http://127.0.0.1:6080/vnc.html'
STATUS_EOF
    chmod 755 /usr/local/bin/gpu-browser-status

    cat > /usr/local/bin/gpu-browser-stop <<'STOP_EOF'
#!/usr/bin/env bash
set -u
for f in /run/gpu-browser/watchdog.pid /run/gpu-browser/chrome.pid /run/gpu-browser/novnc.pid /run/gpu-browser/x11vnc.pid /run/gpu-browser/xorg.pid; do
  if [[ -s "$f" ]]; then p=$(cat "$f" 2>/dev/null || true); [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null || true; rm -f "$f"; fi
done
echo 'GPU browser stack stopped.'
STOP_EOF
    chmod 755 /usr/local/bin/gpu-browser-stop

    cat > /usr/local/bin/gpu-browser-start <<'START_EOF'
#!/usr/bin/env bash
set -e
/opt/gpu-browser/start-stack.sh
START_EOF
    chmod 755 /usr/local/bin/gpu-browser-start

    cat > /usr/local/bin/gpu-browser-restart <<'RESTART_EOF'
#!/usr/bin/env bash
set -e
/usr/local/bin/gpu-browser-stop || true
sleep 2
/opt/gpu-browser/start-stack.sh
RESTART_EOF
    chmod 755 /usr/local/bin/gpu-browser-restart
}

write_watchdog() {
    cat > "$APP_DIR/watchdog.sh" <<'WD_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP=/opt/gpu-browser
RUN=/run/gpu-browser
LOG=/var/log/gpu-browser
DISPLAY=:0
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG/watchdog.log"; }
alive(){ local f=$1 p; [[ -s "$f" ]] || return 1; p=$(cat "$f" 2>/dev/null || true); [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; }
start_x(){ if alive "$RUN/xorg.pid" && DISPLAY=$DISPLAY xdpyinfo >/dev/null 2>&1; then return; fi; log 'Xorg missing; restarting'; rm -f "$RUN/xorg.pid" /tmp/.X0-lock /tmp/.X11-unix/X0; nohup "$(command -v Xorg)" :0 -config /etc/X11/xorg.conf -noreset -nolisten tcp -logfile "$LOG/xorg.log" >/dev/null 2>&1 & echo $! > "$RUN/xorg.pid"; sleep 5; }
start_v(){ if alive "$RUN/x11vnc.pid" && ss -ltn 2>/dev/null | grep -q ':5900'; then return; fi; log 'x11vnc missing; restarting'; nohup x11vnc -display :0 -localhost -forever -shared -noxdamage -rfbauth "$APP/vnc.pass" -rfbport 5900 >> "$LOG/x11vnc.log" 2>&1 & echo $! > "$RUN/x11vnc.pid"; }
start_n(){ if alive "$RUN/novnc.pid" && ss -ltn 2>/dev/null | grep -q ':6080'; then return; fi; log 'noVNC missing; restarting'; WEB=''; for d in /usr/share/novnc /usr/share/noVNC /usr/share/novnc/web /usr/share/noVNC/web /opt/novnc /opt/noVNC; do [[ -f "$d/vnc.html" ]] && WEB="$d" && break; done; [[ -n "$WEB" ]] || return 1; WS=$(command -v websockify || true); [[ -n "$WS" ]] || return 1; nohup "$WS" --web="$WEB" 127.0.0.1:6080 127.0.0.1:5900 >> "$LOG/novnc.log" 2>&1 & echo $! > "$RUN/novnc.pid"; }
start_c(){ if alive "$RUN/chrome.pid"; then return; fi; log 'Chrome missing; restarting'; mkdir -p /tmp/runtime-gpuchrome; chown gpuchrome:gpuchrome /tmp/runtime-gpuchrome; chmod 700 /tmp/runtime-gpuchrome; nohup runuser -u gpuchrome -- env DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-gpuchrome "$APP/start-chrome.sh" >> "$LOG/chrome.log" 2>&1 & echo $! > "$RUN/chrome.pid"; }
log 'Watchdog started'; while true; do start_x || true; sleep 2; start_v || true; start_n || true; start_c || true; sleep 5; done
WD_EOF
    chmod 755 "$APP_DIR/watchdog.sh"
}

write_start_stack() {
    cat > "$APP_DIR/start-stack.sh" <<'STARTSTACK_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP=/opt/gpu-browser
RUN=/run/gpu-browser
LOG=/var/log/gpu-browser
mkdir -p "$RUN" "$LOG"
if [[ -s "$RUN/watchdog.pid" ]]; then p=$(cat "$RUN/watchdog.pid" 2>/dev/null || true); if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then echo "Watchdog already running: PID $p"; exit 0; fi; fi
nohup "$APP/watchdog.sh" >> "$LOG/watchdog.log" 2>&1 &
echo $! > "$RUN/watchdog.pid"
echo "GPU browser watchdog started: PID $!"
STARTSTACK_EOF
    chmod 755 "$APP_DIR/start-stack.sh"
}

verify() {
    info "$(tr 'Son sağlık kontrolleri yapılıyor...' 'Running final health checks...')"
    sleep 3
    DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1 || die 'Xorg health check failed.'
    ok "Xorg: $WIDTHx$HEIGHT"
    DISPLAY="$DISPLAY" glxinfo -B 2>/dev/null | grep -q 'NVIDIA Corporation' || die "$(tr 'NVIDIA OpenGL aktif değil.' 'NVIDIA OpenGL is not active.')"
    ok 'NVIDIA OpenGL active'
    ss -ltn 2>/dev/null | grep -q "127.0.0.1:$VNC_PORT" || die 'VNC port check failed.'
    ss -ltn 2>/dev/null | grep -q "127.0.0.1:$NOVNC_PORT" || die 'noVNC port check failed.'
    ok 'VNC/noVNC listening on localhost only'
    pid_alive "$CHROME_PID" || die 'Chrome health check failed.'
    ok "$(tr 'Chrome sandbox + ANGLE OpenGL çalışıyor.' 'Chrome sandbox + ANGLE OpenGL running.')"
    pid_alive "$WATCHDOG_PID" || die 'Watchdog health check failed.'
    ok "$(tr 'Watchdog çalışıyor.' 'Watchdog running.')"
}

main() {
    choose_language
    require_root
    ensure_dirs
    info "$(tr 'Kurulum başlıyor. Her adımda ne yapıldığını göstereceğim.' 'Installation starting. I will explain each step.')"
    info "$(tr 'NVIDIA ortamı kontrol ediliyor...' 'Checking NVIDIA environment...')"
    check_nvidia
    info "$(tr 'Temel paketler kontrol ediliyor...' 'Checking base packages...')"
    install_packages xorg xserver-xorg-core x11vnc x11-utils mesa-utils dbus-x11 curl wget ca-certificates procps psmisc iproute2 novnc python3-websockify
    XORG_BIN="$(command -v Xorg || command -v X || true)"
    [[ -n "$XORG_BIN" ]] || die 'Xorg binary not found.'
    info "$(tr 'Chrome kontrol ediliyor...' 'Checking Chrome...')"
    install_chrome_if_needed
    info "$(tr 'Chrome için güvenli kullanıcı hazırlanıyor...' 'Preparing secure Chrome user...')"
    setup_chrome_user
    info "$(tr 'noVNC kontrol ediliyor...' 'Checking noVNC...')"
    detect_novnc
    info "$(tr 'Xorg yapılandırması hazırlanıyor...' 'Preparing Xorg configuration...')"
    write_xorg_config
    setup_vnc_password
    stop_managed
    write_chrome_launcher
    write_watchdog
    write_start_stack
    write_tools
    start_xorg
    start_x11vnc
    start_novnc
    start_chrome
    nohup "$APP_DIR/watchdog.sh" >> "$WATCHDOG_LOG" 2>&1 & echo $! > "$WATCHDOG_PID"
    verify
    say ""
    say "============================================================"
    say "$(tr 'KURULUM TAMAMLANDI' 'SETUP COMPLETE')"
    say "============================================================"
    say ""
    say "GPU: $GPU_NAME"
    say "Driver: $GPU_DRIVER"
    say "Display: $DISPLAY (${WIDTH}x${HEIGHT})"
    say 'Chrome: ANGLE OpenGL / WebGL / WebGL2 / WebGPU / Sandbox'
    say "VNC: 127.0.0.1:$VNC_PORT"
    say "noVNC: http://127.0.0.1:$NOVNC_PORT/vnc.html"
    say ""
    say "$(tr 'Kendi bilgisayarından SSH tunnel:' 'SSH tunnel from your own PC:')"
    say '  ssh -p <VAST_SSH_PORT> -L 6080:127.0.0.1:6080 root@<VAST_IP>'
    say ""
    say "$(tr 'Sonra tarayıcıda aç:' 'Then open in your browser:')"
    say '  http://127.0.0.1:6080/vnc.html'
    say ""
    say "$(tr 'Yönetim komutları:' 'Management commands:')"
    say '  gpu-browser-status'
    say '  gpu-browser-start'
    say '  gpu-browser-stop'
    say '  gpu-browser-restart'
    say ""
    say "$(tr 'Loglar:' 'Logs:')"
    say "  $LOG_DIR/xorg.log"
    say "  $LOG_DIR/x11vnc.log"
    say "  $LOG_DIR/novnc.log"
    say "  $LOG_DIR/chrome.log"
    say "  $LOG_DIR/watchdog.log"
    say ""
    say "$(tr 'SSH bağlantısını kapatsan bile süreçler çalışmaya devam eder.' 'Processes continue after SSH disconnect.')"
    say "$(tr 'Container tamamen restart edilirse startup scriptini tekrar çalıştırmalısın.' 'After a full container restart, run the startup script again.')"
    say "============================================================"
}

main "$@"

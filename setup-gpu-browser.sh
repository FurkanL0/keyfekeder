cd /workspace
rm -f setup-gpu-browser.sh

cat > setup-gpu-browser.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="gpu-browser"
BASE_DIR="/opt/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
RUN_DIR="/run/${APP_NAME}"

DISPLAY_NUM="${DISPLAY_NUM:-0}"
DISPLAY=":${DISPLAY_NUM}"

VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"

SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"

GPU_INDEX="${GPU_INDEX:-0}"

XORG_CONF="/etc/X11/xorg.conf.d/90-gpu-browser.conf"
XORG_LOG="${LOG_DIR}/xorg.log"

export DEBIAN_FRONTEND=noninteractive

mkdir -p "$LOG_DIR" "$RUN_DIR" "$BASE_DIR"

log() {
    printf '\033[1;36m[%s]\033[0m %s\n' "$APP_NAME" "$*"
}

ok() {
    printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root."
}

check_nvidia() {
    log "Checking NVIDIA runtime..."

    command -v nvidia-smi >/dev/null 2>&1 \
        || die "nvidia-smi not found. NVIDIA driver must already be installed."

    nvidia-smi >/dev/null 2>&1 \
        || die "nvidia-smi failed. NVIDIA runtime is not healthy."

    GPU_NAME="$(
        nvidia-smi -i "$GPU_INDEX" \
        --query-gpu=name \
        --format=csv,noheader 2>/dev/null |
        head -n1 |
        xargs
    )"

    DRIVER_VERSION="$(
        nvidia-smi -i "$GPU_INDEX" \
        --query-gpu=driver_version \
        --format=csv,noheader 2>/dev/null |
        head -n1 |
        xargs
    )"

    PCI_BUS="$(
        nvidia-smi -i "$GPU_INDEX" \
        --query-gpu=pci.bus_id \
        --format=csv,noheader 2>/dev/null |
        head -n1 |
        xargs
    )"

    [[ -n "$GPU_NAME" ]] \
        || die "Could not determine GPU name."

    [[ -n "$PCI_BUS" ]] \
        || die "Could not determine GPU PCI bus ID."

    ok "GPU: ${GPU_NAME}"
    ok "NVIDIA driver: ${DRIVER_VERSION}"
    ok "PCI bus: ${PCI_BUS}"

    if [[ "$GPU_NAME" =~ RTX[[:space:]]+(40|50)[0-9]{2} ]]; then
        ok "RTX 40/50-series GPU detected."
    else
        warn "GPU is not recognized as a standard RTX 40/50 model. Continuing anyway."
    fi

    if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
        NVIDIA_MODESET="$(cat /sys/module/nvidia_drm/parameters/modeset)"

        if [[ "$NVIDIA_MODESET" == "Y" ]]; then
            ok "nvidia_drm modeset: Y"
        else
            warn "nvidia_drm modeset: ${NVIDIA_MODESET}"
        fi
    fi

    NVIDIA_XORG="$(
        find /usr/lib /usr/lib64 \
        -type f \
        -path '*/nvidia/xorg/nvidia_drv.so' \
        -print \
        -quit 2>/dev/null || true
    )"

    [[ -n "$NVIDIA_XORG" ]] \
        || die "NVIDIA Xorg driver not found. Refusing to modify NVIDIA packages."

    ok "NVIDIA Xorg driver: ${NVIDIA_XORG}"
}

pci_to_xorg() {
    log "Converting NVIDIA PCI address to Xorg BusID..."

    local busdev
    local bus_hex
    local devfunc
    local dev_hex
    local func
    local bus_dec
    local dev_dec

    busdev="${PCI_BUS#*:}"
    bus_hex="${busdev%%:*}"

    devfunc="${busdev#*:}"
    dev_hex="${devfunc%%.*}"
    func="${devfunc#*.}"

    bus_dec=$((16#$bus_hex))
    dev_dec=$((16#$dev_hex))

    XORG_BUSID="PCI:${bus_dec}:${dev_dec}:${func}"

    ok "Xorg BusID: ${XORG_BUSID}"
}

install_packages() {
    log "Installing generic X11/browser dependencies..."

    apt-get update

    apt-get install -y \
        xorg \
        xserver-xorg-core \
        x11vnc \
        dbus-x11 \
        x11-utils \
        mesa-utils \
        ca-certificates \
        curl \
        wget \
        procps \
        psmisc

    ok "Generic X11 dependencies installed."
}

install_chrome() {
    if command -v google-chrome >/dev/null 2>&1; then
        ok "Chrome: $(google-chrome --version 2>/dev/null | head -n1)"
        return
    fi

    log "Google Chrome not found. Installing Chrome Stable..."

    cd /tmp

    wget -q \
        -O google-chrome.deb \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

    apt-get install -y ./google-chrome.deb

    command -v google-chrome >/dev/null 2>&1 \
        || die "Chrome installation failed."

    ok "Chrome: $(google-chrome --version 2>/dev/null | head -n1)"
}

write_xorg() {
    log "Preparing headless NVIDIA Xorg configuration..."

    mkdir -p /etc/X11/xorg.conf.d

    if [[ -f "$XORG_CONF" ]]; then
        cp -a \
            "$XORG_CONF" \
            "${XORG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    cat > "$XORG_CONF" <<CFG
Section "ServerLayout"
    Identifier "GPUBrowserLayout"
    Screen 0 "GPUBrowserScreen"
EndSection

Section "Device"
    Identifier "GPUBrowserDevice"
    Driver "nvidia"
    BusID "${XORG_BUSID}"

    Option "AllowEmptyInitialConfiguration" "True"
    Option "UseDisplayDevice" "None"
EndSection

Section "Screen"
    Identifier "GPUBrowserScreen"
    Device "GPUBrowserDevice"

    DefaultDepth 24

    SubSection "Display"
        Depth 24
        Virtual ${SCREEN_WIDTH} ${SCREEN_HEIGHT}
    EndSubSection
EndSection
CFG

    ok "Xorg config written:"
    echo "    ${XORG_CONF}"
}

stop_previous() {
    log "Stopping previous GPU browser processes..."

    for pidfile in "$RUN_DIR"/*.pid; do
        [[ -f "$pidfile" ]] || continue

        pid="$(cat "$pidfile" 2>/dev/null || true)"

        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                sleep 1
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi

        rm -f "$pidfile"
    done

    if [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]]; then
        warn "An X11 display already exists on ${DISPLAY}."

        local xpid
        xpid="$(
            pgrep -f \
            "[X]org .*:${DISPLAY_NUM}([[:space:]]|$)" |
            head -n1 || true
        )"

        if [[ -n "$xpid" ]]; then
            warn "Existing Xorg PID: ${xpid}"

            if tr '\0' ' ' < "/proc/${xpid}/cmdline" 2>/dev/null |
                grep -q "$XORG_CONF"; then

                log "Existing Xorg appears to belong to this setup."

                kill "$xpid" 2>/dev/null || true
                sleep 2
            else
                warn "Existing Xorg does not appear to be ours."
                warn "It will NOT be killed."
            fi
        fi
    fi
}

start_xorg() {
    log "Starting headless Xorg ${DISPLAY}..."

    mkdir -p /tmp/.X11-unix
    chmod 1777 /tmp/.X11-unix

    rm -f "/tmp/.X${DISPLAY_NUM}-lock" 2>/dev/null || true

    XORG_BIN="$(command -v Xorg || true)"

    if [[ -z "$XORG_BIN" ]]; then
        XORG_BIN="/usr/lib/xorg/Xorg"
    fi

    [[ -x "$XORG_BIN" ]] \
        || die "Xorg binary not found."

    nohup "$XORG_BIN" "$DISPLAY" \
        -config "$XORG_CONF" \
        -noreset \
        -nolisten tcp \
        -logfile "$XORG_LOG" \
        >/dev/null 2>&1 &

    XORG_PID=$!

    echo "$XORG_PID" > "$RUN_DIR/xorg.pid"

    log "Xorg PID: ${XORG_PID}"

    for _ in $(seq 1 30); do

        if [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]]; then

            if DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1; then
                ok "Xorg is ready on ${DISPLAY}."
                return
            fi
        fi

        sleep 1
    done

    echo
    echo "========== XORG LOG =========="
    tail -n 100 "$XORG_LOG" 2>/dev/null || true
    echo "==============================="

    die "Xorg failed to start."
}

check_opengl() {
    log "Checking NVIDIA OpenGL renderer..."

    local vendor
    local renderer
    local dimensions

    dimensions="$(
        DISPLAY="$DISPLAY" \
        xdpyinfo 2>/dev/null |
        awk '/dimensions:/{print $2; exit}'
    )"

    vendor="$(
        DISPLAY="$DISPLAY" \
        glxinfo -B 2>/dev/null |
        awk -F: '
            /OpenGL vendor string/ {
                sub(/^ /,"",$2);
                print $2;
                exit
            }'
    )"

    renderer="$(
        DISPLAY="$DISPLAY" \
        glxinfo -B 2>/dev/null |
        awk -F: '
            /OpenGL renderer string/ {
                sub(/^ /,"",$2);
                print $2;
                exit
            }'
    )"

    [[ -n "$vendor" ]] \
        || die "Could not query OpenGL vendor."

    [[ "$vendor" == *NVIDIA* ]] \
        || die "Xorg is NOT using NVIDIA OpenGL. Vendor: ${vendor}"

    ok "X11 resolution: ${dimensions}"
    ok "OpenGL vendor: ${vendor}"
    ok "OpenGL renderer: ${renderer}"
}

write_chrome_launcher() {
    log "Creating Chrome launcher..."

    mkdir -p "$BASE_DIR/chrome-profile"

    cat > "$BASE_DIR/start-chrome.sh" <<'CHROME'
#!/usr/bin/env bash
set -Eeuo pipefail

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

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
CHROME

    chmod +x "$BASE_DIR/start-chrome.sh"

    ok "Chrome launcher created."
}

start_process() {
    local name="$1"
    local logfile="$2"
    shift 2

    local pidfile="$RUN_DIR/${name}.pid"

    nohup "$@" \
        >> "$logfile" \
        2>&1 &

    local pid=$!

    echo "$pid" > "$pidfile"

    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        ok "${name} started (PID ${pid})."
    else
        echo
        echo "========== ${name} LOG =========="
        tail -n 80 "$logfile" 2>/dev/null || true
        echo "=================================="

        die "${name} failed to start."
    fi
}

start_x11vnc() {
    log "Starting x11vnc..."

    start_process \
        x11vnc \
        "$LOG_DIR/x11vnc.log" \
        x11vnc \
        -display "$DISPLAY" \
        -localhost \
        -forever \
        -shared \
        -nopw \
        -noxdamage \
        -rfbport "$VNC_PORT"
}

start_novnc() {
    log "Starting noVNC/websockify..."

    if command -v websockify >/dev/null 2>&1; then

        start_process \
            novnc \
            "$LOG_DIR/novnc.log" \
            websockify \
            --web=/usr/share/novnc/ \
            "$NOVNC_PORT" \
            "127.0.0.1:${VNC_PORT}"

        return
    fi

    local proxy=""

    proxy="$(command -v novnc_proxy 2>/dev/null || true)"

    if [[ -z "$proxy" ]]; then
        proxy="$(
            find /usr/share/novnc \
                -type f \
                -name novnc_proxy \
                -print \
                -quit 2>/dev/null || true
        )"
    fi

    if [[ -n "$proxy" ]]; then

        start_process \
            novnc \
            "$LOG_DIR/novnc.log" \
            "$proxy" \
            --listen "127.0.0.1:${NOVNC_PORT}" \
            --vnc "127.0.0.1:${VNC_PORT}"

        return
    fi

    warn "websockify/novnc_proxy not found."

    apt-get install -y python3-websockify

    command -v websockify >/dev/null 2>&1 \
        || die "Could not install websockify."

    start_process \
        novnc \
        "$LOG_DIR/novnc.log" \
        websockify \
        --web=/usr/share/novnc/ \
        "$NOVNC_PORT" \
        "127.0.0.1:${VNC_PORT}"
}

start_chrome() {
    log "Starting Chrome with ANGLE OpenGL..."

    if pgrep -f \
        '[g]oogle-chrome.*--user-data-dir=/opt/gpu-browser/chrome-profile' \
        >/dev/null 2>&1; then

        warn "GPU Chrome is already running."
        return
    fi

    start_process \
        chrome \
        "$LOG_DIR/chrome.log" \
        env \
        DISPLAY="$DISPLAY" \
        "$BASE_DIR/start-chrome.sh"
}

write_status_command() {
    log "Installing status command..."

    cat > "$BASE_DIR/status.sh" <<'STATUS'
#!/usr/bin/env bash

BASE_DIR="/opt/gpu-browser"
RUN_DIR="/run/gpu-browser"
DISPLAY=":0"

echo
echo "============================================================"
echo " GPU BROWSER STATUS"
echo "============================================================"

echo
echo "[ NVIDIA ]"

nvidia-smi \
    --query-gpu=name,driver_version,pci.bus_id,temperature.gpu,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader 2>/dev/null || true

echo
echo "[ XORG ]"

if DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1; then

    DISPLAY="$DISPLAY" xdpyinfo |
        grep dimensions ||
        true

    DISPLAY="$DISPLAY" glxinfo -B 2>/dev/null |
        grep -E \
        'OpenGL vendor|OpenGL renderer|OpenGL version' ||
        true

else

    echo "Xorg :0 is NOT responding."

fi

echo
echo "[ PROCESSES ]"

for pidfile in "$RUN_DIR"/*.pid; do

    [[ -f "$pidfile" ]] || continue

    name="$(basename "$pidfile" .pid)"
    pid="$(cat "$pidfile" 2>/dev/null || true)"

    if [[ "$pid" =~ ^[0-9]+$ ]] &&
       kill -0 "$pid" 2>/dev/null; then

        echo "${name}: RUNNING (PID ${pid})"

    else

        echo "${name}: STOPPED"

    fi

done

echo
echo "[ PORTS ]"

ss -ltn 2>/dev/null |
    grep -E ':(5900|6080)\b' ||
    true

echo
echo "[ LOGS ]"

echo "${BASE_DIR}"
echo "/var/log/gpu-browser/xorg.log"
echo "/var/log/gpu-browser/x11vnc.log"
echo "/var/log/gpu-browser/novnc.log"
echo "/var/log/gpu-browser/chrome.log"

echo
echo "============================================================"
STATUS

    chmod +x "$BASE_DIR/status.sh"

    ln -sf \
        "$BASE_DIR/status.sh" \
        /usr/local/bin/gpu-browser-status

    ok "Installed: gpu-browser-status"
}

main() {

    require_root

    echo
    echo "============================================================"
    echo "       HEADLESS NVIDIA GPU BROWSER - VAST.AI"
    echo "============================================================"
    echo
    echo " Display       : ${DISPLAY}"
    echo " Resolution    : ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"
    echo " VNC           : localhost:${VNC_PORT}"
    echo " noVNC         : localhost:${NOVNC_PORT}"
    echo " GPU index     : ${GPU_INDEX}"
    echo
    echo " NVIDIA driver will NOT be replaced."
    echo " systemd is NOT required."
    echo "============================================================"
    echo

    check_nvidia

    pci_to_xorg

    install_packages

    install_chrome

    write_xorg

    stop_previous

    start_xorg

    check_opengl

    write_chrome_launcher

    start_x11vnc

    start_novnc

    start_chrome

    write_status_command

    sleep 3

    echo
    echo "============================================================"
    echo "              GPU BROWSER IS READY"
    echo "============================================================"
    echo

    ok "GPU: ${GPU_NAME}"
    ok "Driver: ${DRIVER_VERSION}"
    ok "Xorg: ${DISPLAY}"
    ok "Resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"
    ok "Chrome: ANGLE OpenGL"
    ok "WebGL: enabled"
    ok "WebGL2: enabled"
    ok "WebGPU: enabled"

    echo
    echo "VNC:"
    echo "  localhost:${VNC_PORT}"

    echo
    echo "noVNC:"
    echo "  http://127.0.0.1:${NOVNC_PORT}/vnc.html"

    echo
    echo "SSH tunnel from your own PC:"
    echo
    echo "  ssh -L ${NOVNC_PORT}:127.0.0.1:${NOVNC_PORT} -p YOUR_SSH_PORT root@YOUR_SERVER_IP"
    echo
    echo "Then open:"
    echo
    echo "  http://127.0.0.1:${NOVNC_PORT}/vnc.html"

    echo
    echo "Chrome GPU diagnostics:"
    echo
    echo "  chrome://gpu"

    echo
    echo "Status:"
    echo
    echo "  gpu-browser-status"

    echo
    echo "Logs:"
    echo
    echo "  ${LOG_DIR}/xorg.log"
    echo "  ${LOG_DIR}/x11vnc.log"
    echo "  ${LOG_DIR}/novnc.log"
    echo "  ${LOG_DIR}/chrome.log"

    echo
    echo "============================================================"
}

main "$@"
EOF

chmod +x setup-gpu-browser.sh
bash -n setup-gpu-browser.sh
echo "SCRIPT SYNTAX: OK"

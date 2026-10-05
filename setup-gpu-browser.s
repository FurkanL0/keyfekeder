#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Headless NVIDIA GPU Browser Server
#
# Target:
#   NVIDIA RTX 4000 / 5000 series
#   Ubuntu 22.04 / 24.04
#   Vast.ai / bare-metal / GPU VM
#
# Provides:
#   NVIDIA Xorg :0
#   1920x1080 virtual display
#   Chrome GPU acceleration
#   WebGL / WebGL2 / WebGPU
#   ANGLE OpenGL backend
#   x11vnc localhost:5900
#   noVNC localhost:6080
#
# IMPORTANT:
#   - Does NOT install/upgrade/remove NVIDIA drivers.
#   - Does NOT touch CUDA.
#   - Does NOT expose VNC/noVNC publicly.
###############################################################################

NAME="gpu-browser"

DISPLAY_NUM=":0"
DISPLAY_ID="0"

SCREEN_WIDTH="1920"
SCREEN_HEIGHT="1080"
SCREEN_DEPTH="24"

XORG_CONF="/etc/X11/xorg.conf.d/90-${NAME}.conf"
LOG_DIR="/var/log/${NAME}"
RUN_DIR="/run/${NAME}"
CHROME_DATA="/opt/${NAME}/chrome-profile"

X11VNC_PORT="5900"
NOVNC_PORT="6080"

CHROME_BIN="/usr/bin/google-chrome"

###############################################################################
# Helpers
###############################################################################

log() {
    echo
    echo "============================================================"
    echo "[${NAME}] $*"
    echo "============================================================"
}

ok() {
    echo "[OK] $*"
}

warn() {
    echo "[WARN] $*"
}

fail() {
    echo
    echo "[ERROR] $*"
    echo
    exit 1
}

cleanup_on_error() {
    echo
    echo "Setup failed."
    echo "Check:"
    echo "  ${LOG_DIR}/xorg.log"
    echo "  ${LOG_DIR}/x11vnc.log"
    echo "  ${LOG_DIR}/novnc.log"
    echo "  journalctl -u ${NAME}-xorg"
    echo
}

trap cleanup_on_error ERR

###############################################################################
# Root
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    fail "Run as root: sudo bash $0"
fi

###############################################################################
# OS detection
###############################################################################

if [[ ! -f /etc/os-release ]]; then
    fail "/etc/os-release not found."
fi

source /etc/os-release

echo
echo "GPU Browser Server"
echo "OS:      ${PRETTY_NAME:-unknown}"
echo "Kernel:  $(uname -r)"
echo

###############################################################################
# Directories
###############################################################################

mkdir -p "${LOG_DIR}"
mkdir -p "${RUN_DIR}"
mkdir -p "${CHROME_DATA}"

chmod 700 "${CHROME_DATA}"

###############################################################################
# NVIDIA detection
###############################################################################

log "Detecting NVIDIA GPU"

command -v nvidia-smi >/dev/null 2>&1 || \
    fail "nvidia-smi not found. NVIDIA driver/runtime is not available."

NVIDIA_SMI_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | xargs || true)"

[[ -n "${NVIDIA_SMI_VERSION}" ]] || \
    fail "NVIDIA driver detected but nvidia-smi could not query driver version."

GPU_COUNT="$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -n1 | xargs || echo 0)"

GPU_COUNT="${GPU_COUNT:-0}"

if [[ "${GPU_COUNT}" -lt 1 ]]; then
    fail "No NVIDIA GPU detected."
fi

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | xargs)"
GPU_UUID="$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -n1 | xargs)"
GPU_PCI="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -n1 | xargs)"

echo "GPU:       ${GPU_NAME}"
echo "Driver:    ${NVIDIA_SMI_VERSION}"
echo "GPU count: ${GPU_COUNT}"
echo "UUID:      ${GPU_UUID}"
echo "PCI:       ${GPU_PCI}"

###############################################################################
# RTX family sanity check
###############################################################################

if [[ "${GPU_NAME}" =~ RTX[[:space:]]+(40|50)[0-90-9]* ]]; then
    ok "RTX 40/50 series detected."
else
    warn "GPU is not obviously an RTX 40/50 series."
    warn "Continuing anyway because NVIDIA Xorg/WebGL may still work."
fi

###############################################################################
# Check NVIDIA kernel driver
###############################################################################

log "Checking NVIDIA kernel driver"

if ! lsmod | grep -q '^nvidia'; then
    warn "nvidia kernel module is not visible in lsmod."
    warn "Trying nvidia-smi anyway..."
fi

nvidia-smi >/dev/null 2>&1 || \
    fail "nvidia-smi failed. Do not continue."

ok "NVIDIA runtime is operational."

###############################################################################
# IMPORTANT:
# Never manipulate NVIDIA packages here.
###############################################################################

log "Protecting existing NVIDIA installation"

echo "Existing NVIDIA driver: ${NVIDIA_SMI_VERSION}"
echo "No NVIDIA packages will be installed, upgraded, downgraded or removed."

###############################################################################
# Convert PCI bus address to Xorg BusID
#
# Example:
#   00000000:5E:00.0
#
# Xorg:
#   PCI:94:0:0
###############################################################################

log "Converting PCI bus ID"

PCI_CLEAN="${GPU_PCI#00000000:}"

IFS=':' read -r PCI_BUS PCI_REST <<< "${PCI_CLEAN}"
IFS='.' read -r PCI_DEV PCI_FUNC <<< "${PCI_REST}"

PCI_BUS_DEC=$((16#${PCI_BUS}))
PCI_DEV_DEC=$((16#${PCI_DEV}))
PCI_FUNC_DEC=$((16#${PCI_FUNC}))

XORG_BUS_ID="PCI:${PCI_BUS_DEC}:${PCI_DEV_DEC}:${PCI_FUNC_DEC}"

echo "NVIDIA PCI: ${GPU_PCI}"
echo "Xorg BusID: ${XORG_BUS_ID}"

###############################################################################
# Packages
###############################################################################

log "Installing userspace packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    xorg \
    xserver-xorg-core \
    xserver-xorg-video-nvidia \
    x11vnc \
    novnc \
    websockify \
    dbus-x11 \
    x11-utils \
    mesa-utils \
    wget \
    curl \
    ca-certificates \
    pciutils \
    procps

###############################################################################
# Chrome
###############################################################################

log "Checking Google Chrome"

if [[ ! -x "${CHROME_BIN}" ]]; then

    echo "Google Chrome not found."
    echo "Installing stable Chrome..."

    TMP_DEB="/tmp/google-chrome-stable.deb"

    rm -f "${TMP_DEB}"

    wget -q \
        -O "${TMP_DEB}" \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

    apt-get install -y "${TMP_DEB}"

    rm -f "${TMP_DEB}"
fi

[[ -x "${CHROME_BIN}" ]] || \
    fail "Google Chrome installation failed."

CHROME_VERSION="$("${CHROME_BIN}" --version 2>/dev/null || true)"

ok "Chrome: ${CHROME_VERSION}"

###############################################################################
# Existing Xorg config backup
###############################################################################

log "Preparing Xorg configuration"

if [[ -f "${XORG_CONF}" ]]; then
    BACKUP="${XORG_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "${XORG_CONF}" "${BACKUP}"
    echo "Existing GPU browser config backed up:"
    echo "  ${BACKUP}"
fi

###############################################################################
# Generate NVIDIA headless Xorg config
###############################################################################

cat > "${XORG_CONF}" <<EOF
Section "ServerLayout"
    Identifier "GPUHeadlessLayout"
    Screen 0 "GPUHeadlessScreen"
EndSection

Section "Device"
    Identifier "GPUHeadlessDevice"
    Driver "nvidia"
    BusID "${XORG_BUS_ID}"

    Option "AllowEmptyInitialConfiguration" "True"
    Option "UseDisplayDevice" "None"
EndSection

Section "Screen"
    Identifier "GPUHeadlessScreen"
    Device "GPUHeadlessDevice"

    DefaultDepth 24

    SubSection "Display"
        Depth 24
        Virtual ${SCREEN_WIDTH} ${SCREEN_HEIGHT}
    EndSubSection
EndSection
EOF

ok "Xorg config generated:"
echo "  ${XORG_CONF}"

###############################################################################
# Kill conflicting old processes
###############################################################################

log "Cleaning previous GPU browser processes"

pkill -TERM Xorg 2>/dev/null || true
pkill -TERM x11vnc 2>/dev/null || true
pkill -TERM websockify 2>/dev/null || true

sleep 2

pkill -KILL Xorg 2>/dev/null || true
pkill -KILL x11vnc 2>/dev/null || true
pkill -KILL websockify 2>/dev/null || true

rm -f /tmp/.X0-lock
rm -f /tmp/.X11-unix/X0

mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

###############################################################################
# Xorg systemd service
###############################################################################

log "Creating Xorg systemd service"

cat > "/etc/systemd/system/${NAME}-xorg.service" <<EOF
[Unit]
Description=Headless NVIDIA Xorg for GPU Browser
After=local-fs.target
Wants=network-online.target

[Service]
Type=simple
User=root

Environment=DISPLAY=${DISPLAY_NUM}

ExecStart=/usr/lib/xorg/Xorg ${DISPLAY_NUM} -config ${XORG_CONF} -noreset -nolisten tcp

Restart=always
RestartSec=2

StandardOutput=append:${LOG_DIR}/xorg.log
StandardError=append:${LOG_DIR}/xorg.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${NAME}-xorg.service"

systemctl restart "${NAME}-xorg.service"

###############################################################################
# Wait for X
###############################################################################

log "Waiting for Xorg"

X_READY=0

for i in $(seq 1 30); do

    if [[ -S /tmp/.X11-unix/X0 ]]; then
        if DISPLAY=:0 xdpyinfo >/dev/null 2>&1; then
            X_READY=1
            break
        fi
    fi

    sleep 1
done

if [[ "${X_READY}" -ne 1 ]]; then

    echo
    echo "Xorg failed."
    echo
    tail -n 100 "${LOG_DIR}/xorg.log" || true
    echo

    systemctl status "${NAME}-xorg.service" --no-pager || true

    fail "Xorg :0 did not become ready."
fi

ok "Xorg :0 is running."

###############################################################################
# Verify resolution
###############################################################################

DIMENSIONS="$(DISPLAY=:0 xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')"

if [[ "${DIMENSIONS}" != "${SCREEN_WIDTH}x${SCREEN_HEIGHT}" ]]; then
    warn "Unexpected X resolution: ${DIMENSIONS}"
else
    ok "Virtual display: ${DIMENSIONS}"
fi

###############################################################################
# Verify NVIDIA OpenGL
###############################################################################

log "Testing NVIDIA OpenGL"

GL_RENDERER="$(
    DISPLAY=:0 glxinfo -B 2>/dev/null |
    awk -F': ' '/OpenGL renderer string/ {print $2; exit}'
)"

GL_VENDOR="$(
    DISPLAY=:0 glxinfo -B 2>/dev/null |
    awk -F': ' '/OpenGL vendor string/ {print $2; exit}'
)"

echo "OpenGL vendor:   ${GL_VENDOR:-unknown}"
echo "OpenGL renderer: ${GL_RENDERER:-unknown}"

if [[ "${GL_RENDERER}" != *NVIDIA* ]]; then
    warn "OpenGL renderer does not appear to be NVIDIA."
    warn "Full glxinfo:"
    DISPLAY=:0 glxinfo -B || true
else
    ok "NVIDIA OpenGL renderer detected."
fi

###############################################################################
# x11vnc systemd service
###############################################################################

log "Creating x11vnc service"

cat > "/etc/systemd/system/${NAME}-x11vnc.service" <<EOF
[Unit]
Description=Localhost x11vnc for GPU Browser
Requires=${NAME}-xorg.service
After=${NAME}-xorg.service

[Service]
Type=simple
User=root

Environment=DISPLAY=${DISPLAY_NUM}

ExecStart=/usr/bin/x11vnc \
    -display ${DISPLAY_NUM} \
    -localhost \
    -forever \
    -shared \
    -nopw \
    -rfbport ${X11VNC_PORT} \
    -noxdamage

Restart=always
RestartSec=2

StandardOutput=append:${LOG_DIR}/x11vnc.log
StandardError=append:${LOG_DIR}/x11vnc.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${NAME}-x11vnc.service"
systemctl restart "${NAME}-x11vnc.service"

sleep 2

if ss -lnt | grep -q ":${X11VNC_PORT} "; then
    ok "x11vnc listening on localhost:${X11VNC_PORT}"
else
    warn "x11vnc port ${X11VNC_PORT} not detected."
fi

###############################################################################
# noVNC/websockify systemd service
###############################################################################

log "Creating noVNC service"

NOVNC_WEB="/usr/share/novnc"

if [[ ! -d "${NOVNC_WEB}" ]]; then
    fail "noVNC web root not found: ${NOVNC_WEB}"
fi

cat > "/etc/systemd/system/${NAME}-novnc.service" <<EOF
[Unit]
Description=noVNC WebSocket proxy for GPU Browser
Requires=${NAME}-x11vnc.service
After=${NAME}-x11vnc.service

[Service]
Type=simple
User=root

ExecStart=/usr/bin/websockify \
    --web=${NOVNC_WEB} \
    ${NOVNC_PORT} \
    127.0.0.1:${X11VNC_PORT}

Restart=always
RestartSec=2

StandardOutput=append:${LOG_DIR}/novnc.log
StandardError=append:${LOG_DIR}/novnc.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${NAME}-novnc.service"
systemctl restart "${NAME}-novnc.service"

sleep 2

if ss -lnt | grep -q ":${NOVNC_PORT} "; then
    ok "noVNC listening on localhost:${NOVNC_PORT}"
else
    warn "noVNC port ${NOVNC_PORT} not detected."
fi

###############################################################################
# Chrome launcher
###############################################################################

log "Creating Chrome GPU launcher"

cat > "/usr/local/bin/${NAME}-chrome" <<'EOF'
#!/usr/bin/env bash

set -e

export DISPLAY=:0

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
    --enable-zero-copy \
    --enable-native-gpu-memory-buffers \
    --enable-unsafe-webgpu \
    --no-first-run \
    --no-default-browser-check \
    "$@"
EOF

chmod +x "/usr/local/bin/${NAME}-chrome"

ok "Chrome launcher created."

###############################################################################
# Chrome systemd service
###############################################################################

log "Creating Chrome service"

cat > "/etc/systemd/system/${NAME}-chrome.service" <<EOF
[Unit]
Description=Chrome NVIDIA GPU Browser
Requires=${NAME}-xorg.service
After=${NAME}-xorg.service

[Service]
Type=simple
User=root

Environment=DISPLAY=${DISPLAY_NUM}

ExecStart=/usr/local/bin/${NAME}-chrome about:blank

Restart=on-failure
RestartSec=5

StandardOutput=append:${LOG_DIR}/chrome.log
StandardError=append:${LOG_DIR}/chrome.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${NAME}-chrome.service"

###############################################################################
# GPU smoke tests
###############################################################################

log "Running GPU smoke tests"

echo
echo "---- X DISPLAY ----"

DISPLAY=:0 xdpyinfo | grep -E \
    'dimensions:|depth of root window' || true

echo
echo "---- NVIDIA OPENGL ----"

DISPLAY=:0 glxinfo -B 2>/dev/null |
    grep -E \
    'OpenGL vendor|OpenGL renderer|OpenGL version|OpenGL core profile version' \
    || true

echo
echo "---- NVIDIA SMI ----"

nvidia-smi \
    --query-gpu=name,driver_version,memory.total,utilization.gpu \
    --format=csv,noheader

###############################################################################
# Start Chrome
###############################################################################

log "Starting Chrome"

systemctl restart "${NAME}-chrome.service"

sleep 8

if systemctl is-active --quiet "${NAME}-chrome.service"; then
    ok "Chrome service is running."
else
    warn "Chrome service failed to stay running."
    systemctl status "${NAME}-chrome.service" --no-pager || true
fi

###############################################################################
# Final status
###############################################################################

log "Final status"

echo
systemctl --no-pager --type=service \
    --state=running |
    grep -E \
    "${NAME}-(xorg|x11vnc|novnc|chrome)" \
    || true

echo
echo "GPU:"
echo "  ${GPU_NAME}"

echo
echo "Driver:"
echo "  ${NVIDIA_SMI_VERSION}"

echo
echo "Xorg:"
echo "  DISPLAY=:0"
echo "  Resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"

echo
echo "Chrome:"
echo "  ${CHROME_BIN}"
echo "  ${CHROME_VERSION}"

echo
echo "ANGLE:"
echo "  OpenGL"

echo
echo "VNC:"
echo "  localhost:${X11VNC_PORT}"

echo
echo "noVNC:"
echo "  http://127.0.0.1:${NOVNC_PORT}/vnc.html"

echo
echo "SSH tunnel from your PC:"
echo
echo "  ssh -L ${NOVNC_PORT}:127.0.0.1:${NOVNC_PORT} -p YOUR_SSH_PORT root@YOUR_SERVER_IP"
echo
echo "Then open:"
echo
echo "  http://127.0.0.1:${NOVNC_PORT}/vnc.html"
echo

echo "Logs:"
echo "  ${LOG_DIR}/xorg.log"
echo "  ${LOG_DIR}/x11vnc.log"
echo "  ${LOG_DIR}/novnc.log"
echo "  ${LOG_DIR}/chrome.log"

echo
echo "Useful commands:"
echo "  nvidia-smi"
echo "  watch -n 1 nvidia-smi"
echo "  systemctl status ${NAME}-xorg"
echo "  systemctl status ${NAME}-chrome"
echo "  journalctl -u ${NAME}-xorg -f"
echo "  tail -f ${LOG_DIR}/chrome.log"

echo
echo "============================================================"
echo " GPU BROWSER SERVER READY"
echo "============================================================"

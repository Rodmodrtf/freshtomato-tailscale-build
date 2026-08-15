#!/bin/sh
# FreshTomato Tailscale Easy Install/Update Script
# Run this on your FreshTomato router to install or update Tailscale

set -eu

REPO="Rodmodrtf/freshtomato-tailscale-build"
BINARY_NAME="tailscale_combo"
INSTALL_DIR="/opt/bin"
STATE_DIR="/opt/var/lib/tailscale"
SOCKET_DIR="/var/run/tailscale"
SOCKET_PATH="$SOCKET_DIR/tailscaled.sock"
HOSTNAME="fresh-1"
ENTWARE_SRC="/tmp/mnt/usb/entware"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }

# Check root (UID/write test)
if [ "${UID:-$(id -u 2>/dev/null || echo 1)}" -ne 0 ] 2>/dev/null; then
    if ! touch /root/.test_write 2>/dev/null; then
        log_error "This script must be run as root"
        exit 1
    fi
    rm -f /root/.test_write
fi

# Create directories (including /var/run/tailscale for socket)
mkdir -p "$INSTALL_DIR" "$STATE_DIR" "$SOCKET_DIR"

# Download latest binary
log_info "Fetching latest release information..."
LATEST_RELEASE=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)
DOWNLOAD_URL=$(echo "$LATEST_RELEASE" | grep -o '"browser_download_url": "[^"]*' | cut -d'"' -f4 | head -1)

log_info "Downloading from: $DOWNLOAD_URL"
TEMP_FILE=$(mktemp)
curl -fsSL "$DOWNLOAD_URL" -o "$TEMP_FILE"
chmod +x "$TEMP_FILE"

# Verify ELF binary
if ! head -c 20 "$TEMP_FILE" | grep -q $'\x7f''ELF'; then
    log_error "Downloaded file is not a valid ELF binary"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Stop existing
if pidof tailscaled >/dev/null 2>&1; then
    log_info "Stopping existing tailscaled..."
    killall tailscaled 2>/dev/null || true
    sleep 2
fi

# Install
mv "$TEMP_FILE" "$INSTALL_DIR/$BINARY_NAME"
chmod +x "$INSTALL_DIR/$BINARY_NAME"
ln -sf "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/tailscale"
ln -sf "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/tailscaled"

log_info "Binary installed."

# Firewall/Tun
iptables -I INPUT 1 -i tailscale0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || true
modprobe tun 2>/dev/null || true

# Helper: bind Entware if not already mounted
bind_entware() {
    if [ -d "$ENTWARE_SRC" ] && ! mount | grep -q "on /opt "; then
        mount --bind "$ENTWARE_SRC" /opt
        log_info "Bound Entware to /opt"
    fi
}

# Interactive configuration
printf "[INFO] Add auto-start to nvram? [y/N]: "
read -r ADD_AUTOSTART
if [ "$ADD_AUTOSTART" = "y" ] || [ "$ADD_AUTOSTART" = "Y" ]; then
    STARTUP_SCRIPT='
# Entware bind mount
if [ -d /tmp/mnt/usb/entware ]; then
    mount --bind /tmp/mnt/usb/entware /opt
fi

# Tailscale auto-start
modprobe tun
/opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 5
/opt/bin/tailscale up --accept-routes --accept-dns=true --hostname=fresh-1 --advertise-routes=192.168.1.0/24
iptables -I INPUT 1 -i tailscale0 -j ACCEPT 2>/dev/null
iptables -I FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
iptables -I FORWARD -o tailscale0 -j ACCEPT 2>/dev/null
'
    add_to_nvram_script() {
        script_name="$1"
        current=$(nvram get "$script_name" 2>/dev/null || echo "")
        if ! echo "$current" | grep -q "Tailscale auto-start"; then
            nvram set "$script_name"="$(printf "%s\n%s" "$current" "$STARTUP_SCRIPT")"
        fi
    }
    add_to_nvram_script "script_startup"
    add_to_nvram_script "script_usbmount"
    nvram commit
    log_info "NVRAM updated with Entware bind mount + Tailscale auto-start."
fi

printf "[INFO] Start tailscaled now? [y/N]: "
read -r START_NOW
if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
    bind_entware
    /opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
    sleep 3
    /opt/bin/tailscale up --accept-routes --accept-dns=true --hostname=fresh-1 --advertise-routes=192.168.1.0/24
fi
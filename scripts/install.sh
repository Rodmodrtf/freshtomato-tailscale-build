#!/bin/sh
# FreshTomato Tailscale Easy Install/Update Script
# Run this on your FreshTomato router to install or update Tailscale
# Usage: curl -fsSL https://raw.githubusercontent.com/Rodmodrtf/freshtomato-tailscale-build/main/scripts/install.sh | sh
# Or download and run: wget -O install.sh https://... && sh install.sh

set -eu

REPO="Rodmodrtf/freshtomato-tailscale-build"
BINARY_NAME="tailscale_combo"
INSTALL_DIR="/opt/bin"
STATE_DIR="/opt/var/lib/tailscale"
SOCKET_PATH="/var/run/tailscaled.sock"
HOSTNAME="fresh-1"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Check if we're on FreshTomato
if [ ! -f /etc/freshtomato_version ] && [ ! -f /etc/tomato_version ]; then
    log_warn "This doesn't appear to be a FreshTomato router. Continuing anyway..."
fi

# Check for Entware
if [ ! -d /opt ] || [ ! -f /opt/bin/opkg ]; then
    log_error "Entware not found at /opt. Please install Entware first."
    log_info "See: https://github.com/Entware/Entware/wiki/Install-on-FreshTomato"
    exit 1
fi

# Create directories
mkdir -p "$INSTALL_DIR" "$STATE_DIR"

# Get latest release info from GitHub
log_info "Fetching latest release information..."
LATEST_RELEASE=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)
if [ -z "$LATEST_RELEASE" ] || echo "$LATEST_RELEASE" | grep -q "Not Found"; then
    log_error "Could not fetch release info. Check repository: $REPO"
    exit 1
fi

DOWNLOAD_URL=$(echo "$LATEST_RELEASE" | grep -o '"browser_download_url": "[^"]*' | cut -d'"' -f4 | head -1)
VERSION_TAG=$(echo "$LATEST_RELEASE" | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    log_error "Could not find download URL in release"
    exit 1
fi

log_info "Found release: $VERSION_TAG"
log_info "Downloading from: $DOWNLOAD_URL"

# Download binary
TEMP_FILE=$(mktemp)
curl -fsSL "$DOWNLOAD_URL" -o "$TEMP_FILE"
chmod +x "$TEMP_FILE"

# Verify it's a valid ARM binary
if ! file "$TEMP_FILE" | grep -q "ARM"; then
    log_error "Downloaded file is not an ARM binary"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Stop existing tailscaled if running
if pidof tailscaled >/dev/null 2>&1; then
    log_info "Stopping existing tailscaled..."
    killall tailscaled 2>/dev/null || true
    sleep 2
fi

# Install new binary
log_info "Installing to $INSTALL_DIR/$BINARY_NAME"
mv "$TEMP_FILE" "$INSTALL_DIR/$BINARY_NAME"
chmod +x "$INSTALL_DIR/$BINARY_NAME"

# Create symlink for tailscaled
ln -sf "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/tailscaled"

log_info "Binary installed successfully"

# Setup firewall rules (idempotent)
log_info "Setting up firewall rules..."
iptables -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i tailscale0 -j ACCEPT
iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tailscale0 -j ACCEPT
iptables -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o tailscale0 -j ACCEPT

# Ensure tun module is loaded
modprobe tun 2>/dev/null || log_warn "Could not load tun module (may already be loaded)"

# Start tailscaled
log_info "Starting tailscaled..."
$INSTALL_DIR/tailscaled --state="$STATE_DIR/tailscaled.state" --socket="$SOCKET_PATH" &
sleep 3

# Bring up Tailscale
log_info "Bringing up Tailscale interface..."
$INSTALL_DIR/tailscale up --accept-routes --accept-dns=true --hostname="$HOSTNAME"

log_info "Installation complete!"
log_info ""
log_info "Next steps:"
log_info "1. Run '$INSTALL_DIR/tailscale up' to authenticate (if not already done)"
log_info "2. Add the following to BOTH 'script_startup' and 'script_usbmount' in FreshTomato GUI:"
log_info ""
cat << 'EOF'
# Tailscale auto-start
modprobe tun
/opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscaled.sock &
sleep 3
/opt/bin/tailscale up --accept-routes --accept-dns=true --hostname=fresh-1
iptables -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i tailscale0 -j ACCEPT
iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tailscale0 -j ACCEPT
iptables -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o tailscale0 -j ACCEPT
EOF
log_info ""
log_info "3. Run '/opt/bin/tailscale status' to verify connection"
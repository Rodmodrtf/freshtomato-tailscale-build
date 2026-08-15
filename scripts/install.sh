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
ENTWARE_SRC="/tmp/mnt/usb/entware"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }

# Check if running as root
if [ "${UID:-$(id -u 2>/dev/null || echo 1)}" -ne 0 ] 2>/dev/null; then
    if ! touch /root/.test_write 2>/dev/null; then
        log_error "This script must be run as root"
        exit 1
    fi
    rm -f /root/.test_write
fi

# Check if we're on FreshTomato
if [ ! -f /etc/freshtomato_version ] && [ ! -f /etc/tomato_version ]; then
    log_warn "This doesn't appear to be a FreshTomato router. Continuing anyway..."
fi

# Check for Entware (at source location, not /opt which might not be bound yet)
if [ ! -d "$ENTWARE_SRC" ] || [ ! -f "$ENTWARE_SRC/bin/opkg" ]; then
    log_error "Entware not found at $ENTWARE_SRC. Please install Entware first."
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

# Verify it's a valid ELF binary
if ! head -c 20 "$TEMP_FILE" | grep -q $'\x7f''ELF'; then
    log_error "Downloaded file is not a valid ELF binary"
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

# Create symlinks for both tailscale and tailscaled (argv[0] detection)
ln -sf "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/tailscale"
ln -sf "$INSTALL_DIR/$BINARY_NAME" "$INSTALL_DIR/tailscaled"

log_info "Binary installed with symlinks: tailscale and tailscaled"

# Setup firewall rules (idempotent)
log_info "Setting up firewall rules..."
iptables -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i tailscale0 -j ACCEPT
iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tailscale0 -j ACCEPT
iptables -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o tailscale0 -j ACCEPT

# Ensure tun module is loaded
modprobe tun 2>/dev/null || log_warn "Could not load tun module (may already be loaded)"

# --- Interactive prompts ---

# Ask about auto-start configuration
echo ""
log_info "Do you want to add auto-start to nvram (script_startup & script_usbmount)?"
log_info "This will make Tailscale start automatically on boot and USB mount."
log_info "It will also add the Entware bind mount ($ENTWARE_SRC -> /opt)."
printf "[INFO] Add auto-start to nvram? [y/N]: "
read -r ADD_AUTOSTART
case "$ADD_AUTOSTART" in
    [Yy]|[Yy][Ee][Ss])
        DO_AUTOSTART=1
        ;;
    *)
        DO_AUTOSTART=0
        log_info "Skipping nvram auto-start configuration."
        ;;
esac

# Ask about starting daemon now
echo ""
log_info "Do you want to start tailscaled now in the background?"
printf "[INFO] Start tailscaled now? [y/N]: "
read -r START_NOW
case "$START_NOW" in
    [Yy]|[Yy][Ee][Ss])
        DO_START=1
        ;;
    *)
        DO_START=0
        log_info "Skipping daemon start. You can start later with:"
        log_info "  /opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscaled.sock &"
        ;;
esac

# Configure auto-start in nvram if requested
if [ "$DO_AUTOSTART" -eq 1 ]; then
    log_info "Configuring auto-start in nvram..."
    
    # Script for script_startup (runs on boot)
    STARTUP_SCRIPT='
# Entware bind mount
if [ -d /tmp/mnt/usb/entware ]; then
    mount --bind /tmp/mnt/usb/entware /opt
fi

# Tailscale auto-start
modprobe tun
/opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscaled.sock &
sleep 5
/opt/bin/tailscale up --accept-routes --accept-dns=true --hostname=fresh-1
iptables -I INPUT 1 -i tailscale0 -j ACCEPT 2>/dev/null
iptables -I FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
iptables -I FORWARD -o tailscale0 -j ACCEPT 2>/dev/null
'

    # Script for script_usbmount (runs when USB is mounted)
    USBMOUNT_SCRIPT='
# Entware bind mount
if [ -d /tmp/mnt/usb/entware ]; then
    mount --bind /tmp/mnt/usb/entware /opt
fi

# Tailscale auto-start
modprobe tun
/opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscaled.sock &
sleep 5
/opt/bin/tailscale up --accept-routes --accept-dns=true --hostname=fresh-1
iptables -I INPUT 1 -i tailscale0 -j ACCEPT 2>/dev/null
iptables -I FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
iptables -I FORWARD -o tailscale0 -j ACCEPT 2>/dev/null
'

    add_to_nvram_script() {
        script_name="$1"
        script_content="$2"
        current=$(nvram get "$script_name" 2>/dev/null || echo "")
        if echo "$current" | grep -q "Tailscale auto-start"; then
            log_info "$script_name already contains Tailscale startup"
        else
            new_script=$(printf "%s\n%s" "$current" "$script_content")
            nvram set "$script_name"="$new_script"
            log_info "Added auto-start to $script_name"
        fi
    }

    add_to_nvram_script "script_startup" "$STARTUP_SCRIPT"
    add_to_nvram_script "script_usbmount" "$USBMOUNT_SCRIPT"

    # Commit nvram changes
    nvram commit
    log_info "NVRAM committed. Auto-start configured for boot and USB mount (includes Entware bind mount)."
fi

# Start daemon if requested
if [ "$DO_START" -eq 1 ]; then
    # Ensure Entware is bound now
    if [ -d "$ENTWARE_SRC" ] && ! mount | grep -q "on /opt "; then
        log_info "Binding Entware to /opt..."
        mount --bind "$ENTWARE_SRC" /opt
    fi
    
    log_info "Starting tailscaled..."
    $INSTALL_DIR/tailscaled --state="$STATE_DIR/tailscaled.state" --socket="$SOCKET_PATH" &
    sleep 3

    # Bring up Tailscale
    log_info "Bringing up Tailscale interface..."
    $INSTALL_DIR/tailscale up --accept-routes --accept-dns=true --hostname="$HOSTNAME"
else
    log_info ""
    log_info "To start manually later (ensure Entware is bound first):"
    log_info "  mount --bind /tmp/mnt/usb/entware /opt"
    log_info "  /opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscaled.sock &"
    log_info "  /opt/bin/tailscale up --accept-routes --accept-dns=true --hostname=fresh-1"
fi

log_info ""
log_info "Installation complete!"
log_info "Run '/opt/bin/tailscale status' to verify connection"
log_info "Run '/opt/bin/tailscale up' to re-authenticate if needed"
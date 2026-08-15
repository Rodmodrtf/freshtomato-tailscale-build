# FreshTomato Tailscale Build (armv5/GOARM=5)

Automated GitHub Actions builds of Tailscale combined binary (`tailscale` + `tailscaled`) for FreshTomato routers on legacy Broadcom hardware (Linux kernel 2.6.36, ARMv5 soft-float).

## Quick Install on FreshTomato

Run this one-liner on your router (via SSH):

```bash
curl -fsSL https://raw.githubusercontent.com/Rodmodrtf/freshtomato-tailscale-build/main/scripts/install.sh | bash
```

Or download and inspect first:

```bash
wget https://raw.githubusercontent.com/Rodmodrtf/freshtomato-tailscale-build/main/scripts/install.sh
bash install.sh
```

## What This Provides

- **Combined binary**: Single `tailscale_combo` (~5.2 MB UPX-packed) that works as both `tailscale` CLI and `tailscaled` daemon
- **Architecture**: ARMv5 soft-float (`GOARM=5`) - compatible with kernel 2.6.36
- **Auto-updates**: GitHub Actions rebuilds daily and on every push to main
- **Easy install**: One-script installation with firewall rules and auto-start configuration

## Requirements

- FreshTomato 2026.1+ (K26ARM USB AIO-64K)
- Entware installed on USB storage (`/opt` bind-mount)
- Swap file configured (256MB+ recommended)
- USB storage mounted at `/tmp/mnt/usb` with `.entware-ready` marker

## Installation Details

The install script:
1. Downloads the latest `tailscale_combo` binary from GitHub Releases
2. Installs to `/opt/bin/tailscale_combo`
3. Creates symlink: `/opt/bin/tailscaled` → `tailscale_combo`
4. Loads `tun` kernel module
5. Adds required iptables firewall rules (idempotent)
6. Starts `tailscaled` with persistent state at `/opt/var/lib/tailscale/tailscaled.state`
7. Runs `tailscale up` with `--accept-routes --accept-dns`

## Firewall Rules (Required for Kernel 2.6.36)

Due to kernel limitations, automatic iptables rule injection doesn't work. These rules **must** be present:

```bash
iptables -I INPUT 1 -i tailscale0 -j ACCEPT
iptables -I FORWARD -i tailscale0 -j ACCEPT
iptables -I FORWARD -o tailscale0 -j ACCEPT
```

The install script adds these automatically. They're also included in the auto-start configuration below.

## Auto-Start Configuration

Add the following to **BOTH** `script_startup` AND `script_usbmount` in FreshTomato GUI (Administration → Scripts):

```bash
# Tailscale auto-start
modprobe tun
/opt/bin/tailscaled --state=/opt/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscaled.sock &
sleep 3
/opt/bin/tailscale up --accept-routes --accept-dns=true --hostname=fresh-1
iptables -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i tailscale0 -j ACCEPT
iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tailscale0 -j ACCEPT
iptables -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o tailscale0 -j ACCEPT
```

Using both scripts ensures Tailscale starts on boot AND when USB storage is remounted.

## Updating

Simply re-run the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/Rodmodrtf/freshtomato-tailscale-build/main/scripts/install.sh | bash
```

It will download the latest version, stop the old daemon, replace the binary, and restart.

## Manual Commands

```bash
# Check status
/opt/bin/tailscale status

# View logs
/opt/bin/tailscaled -verbose

# Re-authenticate
/opt/bin/tailscale up --accept-routes --accept-dns=true

# Disconnect
/opt/bin/tailscale down

# Check binary version
/opt/bin/tailscale version
```

## Build Details

- **Source**: Tailscale v1.102.2 (tagged release)
- **Build tag**: `ts_include_cli` (combines CLI + daemon)
- **Go version**: 1.26.5
- **Target**: `GOARCH=arm GOARM=5 CGO_ENABLED=0`
- **Packing**: UPX `--best --lzma` (~76% size reduction)

The workflow adds `hostinfo.KernelVersion()` to support legacy kernel detection (though the current build doesn't include the full legacy kernel patches - it's a clean upstream build optimized for size).

## GitHub Actions Workflow

Located at `.github/workflows/build.yml`:
- Triggers on push to `main`
- Manual trigger via `workflow_dispatch`
- Daily scheduled check at 02:00 UTC
- Creates GitHub Release with binary asset
- Uploads artifact for scheduled runs

## License

Tailscale is BSD-3-Clause licensed. This build repository contains only build automation and installation scripts.

## Credits

- Tailscale: https://github.com/tailscale/tailscale
- FreshTomato: https://freshtomato.org
- Built for keeping legacy Broadcom routers alive with modern mesh networking
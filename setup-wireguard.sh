#!/bin/bash
# WireGuard + ProtonVPN setup with kill switch + port forwarding keepalive
#
# - All external traffic must go through VPN
# - LAN traffic (SSH, local web UIs, etc.) is always allowed
# - If VPN drops, external traffic is blocked (no leaks)
# - Port forwarding is acquired via NAT-PMP and refreshed every 45s
# - Forwarded port is written to /run/protonvpn/forwarded-port (KEY=VALUE)
#
# Usage: sudo ./setup-wireguard.sh /path/to/protonvpn.conf [INTERFACE_NAME]
# Example: sudo ./setup-wireguard.sh ~/ProtonVPN-US-1.conf
# Example: sudo ./setup-wireguard.sh ~/ProtonVPN-US-1.conf wg0

set -euo pipefail

# --- Args ---
CONF_SRC="${1:-}"
WG_IFACE="${2:-wg0}"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"

# Port forwarding config
PROTONVPN_GATEWAY="10.2.0.1"       # ProtonVPN WireGuard gateway (standard)
PORT_FILE_DIR="/run/protonvpn"
PORT_FILE="${PORT_FILE_DIR}/forwarded-port"
PORTFORWARD_SCRIPT="/usr/local/bin/protonvpn-portforward.sh"
PORTFORWARD_SERVICE="protonvpn-portforward.service"
REFRESH_INTERVAL=45                 # NAT-PMP lease is 60s; refresh at 45s

# --- Helpers ---
log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

ensure_package() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        log "Already installed: $pkg"
    else
        log "Installing missing package: $pkg"
        apt-get install -y "$pkg"
    fi
}

detect_lan_subnet() {
    # Find directly connected RFC1918 subnets (scope link = on-link, no gateway)
    # Excludes loopback and any existing WireGuard interfaces
    while read -r dest _ rest; do
        local iface
        iface=$(echo "$rest" | grep -oP '(?<=dev\s)\S+' || true)
        [[ -z "$iface" ]] && continue
        [[ "$iface" == "lo" ]] && continue
        [[ "$iface" == wg* ]] && continue

        if [[ "$dest" =~ ^10\. ]] || \
           [[ "$dest" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || \
           [[ "$dest" =~ ^192\.168\. ]]; then
            echo "$dest"
            return 0
        fi
    done < <(ip route show scope link)

    return 1
}

# --- Validate ---
[[ -z "$CONF_SRC" ]]   && die "Usage: sudo $0 /path/to/protonvpn.conf [wg-interface-name]"
[[ ! -f "$CONF_SRC" ]] && die "Config file not found: $CONF_SRC"
[[ "$EUID" -ne 0 ]]    && die "Please run as root (sudo)"

grep -q '^\[Interface\]' "$CONF_SRC" || die "File does not look like a WireGuard config (missing [Interface])"
grep -q '^\[Peer\]'      "$CONF_SRC" || die "File does not look like a WireGuard config (missing [Peer])"

# --- Packages ---
# Suppress interactive prompts during package installation.
# iptables-persistent asks whether to save current rules - we answer no
# here and save explicitly ourselves after setup so we control what's saved.
export DEBIAN_FRONTEND=noninteractive
echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections

log "Updating package lists..."
apt-get update -qq

log "Checking required packages..."

# Check for WireGuard kernel support directly rather than relying on the
# wireguard meta-package, which can be broken on custom/Armbian kernels.
# WireGuard is built into mainline kernels >= 5.6, so the module or
# built-in support should always be present on a modern image.
log "Checking WireGuard kernel support..."
ensure_package kmod  # needed for modprobe/lsmod
if lsmod | grep -q '^wireguard'; then
    log "WireGuard module already loaded."
elif modprobe wireguard 2>/dev/null; then
    log "WireGuard module loaded successfully."
else
    # Could be built-in (=y) rather than a module (=m) - check that too
    if grep -qE '^CONFIG_WIREGUARD=y' /boot/config-"$(uname -r)" 2>/dev/null; then
        log "WireGuard is built into the kernel (=y), no module needed."
    else
        die "WireGuard kernel support not found. Your kernel may not include WireGuard. Check: grep WIREGUARD /boot/config-\$(uname -r)"
    fi
fi

ensure_package wireguard-tools
ensure_package iptables
ensure_package iptables-persistent
ensure_package natpmpc

if ! command -v resolvconf &>/dev/null; then
    ensure_package openresolv
fi

# --- Stop existing services if running ---
if systemctl is-active --quiet "$PORTFORWARD_SERVICE" 2>/dev/null; then
    warn "Stopping existing $PORTFORWARD_SERVICE..."
    systemctl stop "$PORTFORWARD_SERVICE" || true
fi

if systemctl is-active --quiet "wg-quick@${WG_IFACE}" 2>/dev/null; then
    warn "Stopping existing wg-quick@${WG_IFACE} before reconfiguring..."
    systemctl stop "wg-quick@${WG_IFACE}" || true
fi

# --- Detect LAN subnet ---
log "Detecting LAN subnet..."
if LAN_SUBNET=$(detect_lan_subnet); then
    log "LAN subnet detected: $LAN_SUBNET"
else
    die "Could not detect a LAN subnet. Make sure ethernet is connected and has a RFC1918 address."
fi

# --- Build WireGuard config with kill switch injected ---
log "Building WireGuard config at $WG_CONF..."
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Extract [Interface] section, stripping any existing PostUp/PreDown
INTERFACE_BLOCK=$(awk '/^\[Interface\]/,/^\[Peer\]/' "$CONF_SRC" \
    | grep -v '^\[Peer\]' \
    | grep -vE '^\s*(PostUp|PreDown)\s*=')

# Extract [Peer] section(s) unchanged
PEER_BLOCK=$(awk '/^\[Peer\]/,0' "$CONF_SRC")

{
    echo "$INTERFACE_BLOCK"
    echo ""
    echo "# === Kill switch: block external traffic if VPN drops ==="
    echo "# Allow loopback"
    echo "PostUp = iptables -I OUTPUT 1 -o lo -j ACCEPT"
    echo "# Allow all LAN traffic (SSH, local web UIs, etc.)"
    echo "PostUp = iptables -I OUTPUT 2 -d ${LAN_SUBNET} -j ACCEPT"
    echo "# Allow traffic going out through the VPN tunnel"
    echo "PostUp = iptables -I OUTPUT 3 -o ${WG_IFACE} -j ACCEPT"
    echo "# Allow WireGuard's own UDP packets to reach the VPN endpoint"
    echo "PostUp = iptables -I OUTPUT 4 -m mark --mark \$(wg show ${WG_IFACE} fwmark) -j ACCEPT"
    echo "# Block everything else outbound"
    echo "PostUp = iptables -A OUTPUT -j REJECT"
    echo "# IPv6: only allow through tunnel, block all else to prevent leaks"
    echo "PostUp = ip6tables -I OUTPUT 1 -o ${WG_IFACE} -j ACCEPT"
    echo "PostUp = ip6tables -A OUTPUT -j REJECT"
    echo ""
    echo "# Tear down kill switch rules cleanly on VPN stop"
    echo "PreDown = iptables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true"
    echo "PreDown = iptables -D OUTPUT -d ${LAN_SUBNET} -j ACCEPT 2>/dev/null || true"
    echo "PreDown = iptables -D OUTPUT -o ${WG_IFACE} -j ACCEPT 2>/dev/null || true"
    echo "PreDown = iptables -D OUTPUT -m mark --mark \$(wg show ${WG_IFACE} fwmark) -j ACCEPT 2>/dev/null || true"
    echo "PreDown = iptables -D OUTPUT -j REJECT 2>/dev/null || true"
    echo "PreDown = ip6tables -D OUTPUT -o ${WG_IFACE} -j ACCEPT 2>/dev/null || true"
    echo "PreDown = ip6tables -D OUTPUT -j REJECT 2>/dev/null || true"
    echo ""
    echo "$PEER_BLOCK"
} > "$WG_CONF"

chmod 600 "$WG_CONF"
log "WireGuard config written."

# --- Write port forwarding keepalive script ---
log "Writing port forwarding keepalive script to $PORTFORWARD_SCRIPT..."

cat > "$PORTFORWARD_SCRIPT" << PFSCRIPT
#!/bin/bash
# ProtonVPN NAT-PMP port forwarding keepalive
# Requests a forwarded port and refreshes it every ${REFRESH_INTERVAL}s
# before the 60s lease expires.
#
# Port info is written to ${PORT_FILE} in KEY=VALUE format.
#
# Read from another script:
#   source ${PORT_FILE} && echo \$PORT
#   grep '^PORT=' ${PORT_FILE} | cut -d= -f2

set -euo pipefail

GATEWAY="${PROTONVPN_GATEWAY}"
PORT_FILE="${PORT_FILE}"
PORT_FILE_DIR="${PORT_FILE_DIR}"
REFRESH_INTERVAL=${REFRESH_INTERVAL}

log()  { echo "\$(date '+%Y-%m-%dT%H:%M:%S') [portforward] \$*"; }
warn() { echo "\$(date '+%Y-%m-%dT%H:%M:%S') [portforward] WARN: \$*"; }

# Clean up port file on exit so stale port is never read
cleanup() {
    warn "Shutting down - removing port file"
    rm -f "\$PORT_FILE"
}
trap cleanup EXIT

# Ensure output dir exists (/run is tmpfs, won't survive reboot)
mkdir -p "\$PORT_FILE_DIR"
chmod 755 "\$PORT_FILE_DIR"

log "Starting ProtonVPN port forwarding keepalive (gateway: \$GATEWAY)"

CURRENT_PORT=""

while true; do
    # Request UDP and TCP port forwarding via NAT-PMP
    UDP_OUTPUT=\$(natpmpc -a 1 0 udp 60 -g "\$GATEWAY" 2>&1) || true
    TCP_OUTPUT=\$(natpmpc -a 1 0 tcp 60 -g "\$GATEWAY" 2>&1) || true

    # Parse assigned port from UDP response (TCP will match on ProtonVPN)
    NEW_PORT=\$(echo "\$UDP_OUTPUT" | grep -oP '(?<=Mapped public port )\d+' || true)

    if [[ -n "\$NEW_PORT" ]]; then
        if [[ "\$NEW_PORT" != "\$CURRENT_PORT" ]]; then
            log "Port assigned/changed: \$NEW_PORT (was: \${CURRENT_PORT:-none})"
            CURRENT_PORT="\$NEW_PORT"
        else
            log "Port lease refreshed: \$CURRENT_PORT"
        fi

        # Atomic write via temp file so readers never see a partial file
        TMPFILE=\$(mktemp "\$PORT_FILE_DIR/.port.XXXXXX")
        cat > "\$TMPFILE" << EOF
PORT=\$CURRENT_PORT
UPDATED=\$(date '+%Y-%m-%dT%H:%M:%S')
GATEWAY=\$GATEWAY
EOF
        chmod 644 "\$TMPFILE"
        mv "\$TMPFILE" "\$PORT_FILE"

    else
        warn "NAT-PMP request failed. Output:"
        warn "\$UDP_OUTPUT"
        warn "Retrying in \${REFRESH_INTERVAL}s. Last known port: \${CURRENT_PORT:-none}"
        # Don't clear the port file on transient failure - keep last known value
    fi

    sleep "\$REFRESH_INTERVAL"
done
PFSCRIPT

chmod 755 "$PORTFORWARD_SCRIPT"
log "Keepalive script written."

# --- Write systemd service ---
log "Writing systemd service: /etc/systemd/system/${PORTFORWARD_SERVICE}..."

cat > "/etc/systemd/system/${PORTFORWARD_SERVICE}" << SVCFILE
[Unit]
Description=ProtonVPN Port Forwarding Keepalive
Documentation=https://protonvpn.com/support/port-forwarding
# Start after WireGuard is up; if WireGuard stops, we stop too
After=wg-quick@${WG_IFACE}.service
BindsTo=wg-quick@${WG_IFACE}.service

[Service]
Type=simple
# Brief delay to let the VPN tunnel fully establish before NAT-PMP
ExecStartPre=/bin/sleep 3
ExecStart=${PORTFORWARD_SCRIPT}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=protonvpn-portforward

[Install]
WantedBy=multi-user.target
SVCFILE

systemctl daemon-reload
systemctl enable "$PORTFORWARD_SERVICE"
log "Systemd service enabled."

# --- Enable and start WireGuard ---
log "Enabling and starting wg-quick@${WG_IFACE}..."
systemctl enable "wg-quick@${WG_IFACE}"
systemctl start "wg-quick@${WG_IFACE}"

# Wait for WireGuard interface to appear
log "Waiting for ${WG_IFACE} to come up..."
for i in $(seq 1 10); do
    if ip link show "${WG_IFACE}" &>/dev/null 2>&1; then
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

if ! ip link show "${WG_IFACE}" &>/dev/null 2>&1; then
    die "${WG_IFACE} did not come up. Check: journalctl -u wg-quick@${WG_IFACE} -n 50"
fi
log "Interface ${WG_IFACE} is up."

# --- Save iptables rules (kill switch) so they persist across reboot ---
# We do this explicitly now that WireGuard is up and the rules are active,
# rather than letting iptables-persistent prompt during install.
log "Saving iptables rules for persistence across reboots..."
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
log "iptables rules saved."

# --- Start port forwarding service ---
log "Starting port forwarding keepalive..."
systemctl start "$PORTFORWARD_SERVICE"

# Wait up to 15s for port file to appear
log "Waiting for port assignment (up to 15s)..."
for i in $(seq 1 15); do
    if [[ -f "$PORT_FILE" ]]; then
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

if [[ -f "$PORT_FILE" ]]; then
    log "Port file contents:"
    cat "$PORT_FILE"
else
    warn "Port file not yet written - service may still be negotiating."
    warn "Check: journalctl -u $PORTFORWARD_SERVICE -f"
fi

# --- Summary ---
echo ""
log "WireGuard status:"
wg show "${WG_IFACE}"

echo ""
log "Active iptables OUTPUT rules:"
iptables -L OUTPUT -n -v --line-numbers

echo ""
log "=== Setup complete ==="
log "LAN subnet ${LAN_SUBNET} is always reachable (SSH, local web UIs)"
log "All other traffic routes through ProtonVPN via ${WG_IFACE}"
log "Port file: ${PORT_FILE} (refreshed every ${REFRESH_INTERVAL}s)"
echo ""
log "Read the port in a script:  source ${PORT_FILE} && echo \$PORT"
log "Read the port ad-hoc:       grep '^PORT=' ${PORT_FILE} | cut -d= -f2"
echo ""
log "Useful commands:"
log "  VPN status:   systemctl status wg-quick@${WG_IFACE}"
log "  Port status:  systemctl status ${PORTFORWARD_SERVICE}"
log "  Port logs:    journalctl -u ${PORTFORWARD_SERVICE} -f"
log "  Port file:    cat ${PORT_FILE}"
log "  WG info:      wg show ${WG_IFACE}"

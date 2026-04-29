#!/bin/bash
# WiFi setup for Armbian (systemd-networkd + wpa_supplicant)
# Usage: sudo ./setup-wifi.sh <SSID> <PASSWORD> [INTERFACE]
# Example: sudo ./setup-wifi.sh MyNetwork MyPassword wlan0

set -e

# --- Args ---
SSID="${1}"
PASSWORD="${2}"
IFACE="${3:-wlan0}"

if [[ -z "$SSID" || -z "$PASSWORD" ]]; then
    echo "Usage: sudo $0 <SSID> <PASSWORD> [INTERFACE]"
    echo "  INTERFACE defaults to wlan0 if not specified"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# --- Detect interface if not specified ---
if ! ip link show "$IFACE" &>/dev/null; then
    echo "Interface $IFACE not found. Available interfaces:"
    ip -br link show
    echo ""
    echo "Re-run with the correct interface name as the third argument."
    exit 1
fi

echo "==> Setting up WiFi on $IFACE for SSID: $SSID"

# --- wpa_supplicant config ---
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"
echo "==> Writing wpa_supplicant config to $WPA_CONF"

wpa_passphrase "$SSID" "$PASSWORD" > "$WPA_CONF"
chmod 600 "$WPA_CONF"

# --- systemd-networkd config ---
NETWORK_CONF="/etc/systemd/network/25-${IFACE}.network"
echo "==> Writing systemd-networkd config to $NETWORK_CONF"

cat > "$NETWORK_CONF" << EOF
[Match]
Name=${IFACE}

[Network]
DHCP=yes
EOF

# --- Enable and start services ---
echo "==> Enabling wpa_supplicant@${IFACE}"
systemctl enable "wpa_supplicant@${IFACE}"
systemctl restart "wpa_supplicant@${IFACE}"

echo "==> Restarting systemd-networkd"
systemctl restart systemd-networkd

# --- Wait and verify ---
echo "==> Waiting for connection (up to 15s)..."
for i in $(seq 1 15); do
    sleep 1
    IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
    if [[ -n "$IP" ]]; then
        echo ""
        echo "==> Connected! $IFACE got IP: $IP"
        exit 0
    fi
    echo -n "."
done

echo ""
echo "==> No IP after 15s. Check status with:"
echo "    systemctl status wpa_supplicant@${IFACE}"
echo "    journalctl -u wpa_supplicant@${IFACE} -n 30"
echo "    ip addr show ${IFACE}"
exit 1

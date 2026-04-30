#!/bin/bash
# Jellyfin media server setup
#
# - Installs Jellyfin via official apt repository
# - Adds jellyfin user to the media group for shared folder access
# - Configures media library paths
#
# Usage: sudo ./setup-jellyfin.sh /path/to/data/root
# Example: sudo ./setup-jellyfin.sh /srv/media

set -euo pipefail

# --- Args ---
DATA_ROOT="${1:-}"

# --- Config ---
MEDIA_GROUP="media"
JELLYFIN_USER="jellyfin"
JELLYFIN_PORT=8096
JELLYFIN_SERVICE="jellyfin.service"

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

# --- Validate ---
[[ -z "$DATA_ROOT" ]] && die "Usage: sudo $0 /path/to/data/root"
[[ "$EUID" -ne 0 ]]   && die "Please run as root (sudo)"
[[ ! -d "$DATA_ROOT" ]] && die "Data root '$DATA_ROOT' does not exist. Run setup-qbittorrent.sh first."

getent group "$MEDIA_GROUP" &>/dev/null \
    || die "'$MEDIA_GROUP' group not found. Run setup-qbittorrent.sh first."

[[ ! -d "${DATA_ROOT}/media/tv" ]] \
    && die "Media folders not found under $DATA_ROOT. Run setup-qbittorrent.sh first."

# --- Packages ---
export DEBIAN_FRONTEND=noninteractive
log "Updating package lists..."
apt-get update -qq

log "Checking required packages..."
ensure_package curl
ensure_package gnupg
ensure_package apt-transport-https

# --- Add Jellyfin apt repository ---
if [[ ! -f /etc/apt/sources.list.d/jellyfin.list ]]; then
    log "Adding Jellyfin apt repository..."
    curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg
    echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/ubuntu focal main" \
        > /etc/apt/sources.list.d/jellyfin.list
    apt-get update -qq
else
    log "Jellyfin repository already configured."
fi

# --- Install Jellyfin ---
ensure_package jellyfin

# --- Add jellyfin user to media group ---
# This allows Jellyfin to read the shared media folders
log "Adding $JELLYFIN_USER to $MEDIA_GROUP group..."
usermod -aG "$MEDIA_GROUP" "$JELLYFIN_USER"

# --- Enable and start service ---
if systemctl is-active --quiet "$JELLYFIN_SERVICE" 2>/dev/null; then
    log "Restarting Jellyfin to pick up group membership..."
    systemctl restart "$JELLYFIN_SERVICE"
else
    log "Starting Jellyfin..."
    systemctl enable "$JELLYFIN_SERVICE"
    systemctl start "$JELLYFIN_SERVICE"
fi

# --- Wait for web UI ---
log "Waiting for Jellyfin web UI to respond (up to 60s)..."
READY=0
for i in $(seq 1 60); do
    if curl -sf --max-time 2 "http://localhost:${JELLYFIN_PORT}/health" &>/dev/null; then
        READY=1
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

if [[ "$READY" -eq 1 ]]; then
    log "Jellyfin is up."
else
    warn "Jellyfin did not respond after 60s - may still be initializing."
    warn "Check: journalctl -u $JELLYFIN_SERVICE -n 50"
fi

# --- Verify media folder permissions ---
log "Verifying media folder permissions..."
PERM_FAILED=0

for dir in "${DATA_ROOT}/media/tv" "${DATA_ROOT}/media/movies"; do
    if sudo -u "$JELLYFIN_USER" test -r "$dir" 2>/dev/null; then
        log "  [OK] $JELLYFIN_USER can read: $dir"
    else
        warn "  [FAIL] $JELLYFIN_USER cannot read: $dir"
        PERM_FAILED=1
    fi
done

if [[ "$PERM_FAILED" -eq 1 ]]; then
    warn "Permission issues detected. Fixing..."
    chown -R ":${MEDIA_GROUP}" "$DATA_ROOT"
    chmod -R g+rX "$DATA_ROOT"
    log "Permissions fixed. Restarting Jellyfin..."
    systemctl restart "$JELLYFIN_SERVICE"
fi

# --- Summary ---
echo ""
log "=== Setup complete ==="
echo ""
log "Jellyfin web UI: http://<ip>:${JELLYFIN_PORT}"
log "Complete initial setup in the browser:"
log "  1. Create your admin account"
log "  2. Add media libraries:"
log "       Movies: ${DATA_ROOT}/media/movies"
log "       TV:     ${DATA_ROOT}/media/tv"
log "  3. In Seerr (http://<ip>:5055) connect to Jellyfin using:"
log "       URL: http://localhost:${JELLYFIN_PORT}"
log "       API key: (generate in Jellyfin > Dashboard > API Keys)"
echo ""
log "media group members:"
getent group "$MEDIA_GROUP"
echo ""
log "Useful commands:"
log "  Status:  systemctl status $JELLYFIN_SERVICE"
log "  Logs:    journalctl -u $JELLYFIN_SERVICE -f"
log "  Restart: systemctl restart $JELLYFIN_SERVICE"

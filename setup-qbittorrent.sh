#!/bin/bash
# qBittorrent-nox setup script
#
# - Creates a 'media' group shared across all media services (qbt, sonarr, radarr, jellyfin)
# - Creates a 'qbt' user in the media group
# - Sets up the standard torrent/media folder structure
# - Installs and configures qbittorrent-nox as a systemd service
# - Default web UI credentials: admin / adminadmin
#
# Usage: sudo ./setup-qbittorrent.sh /path/to/data/root
# Example: sudo ./setup-qbittorrent.sh /mnt/external
# Example (SD card for now): sudo ./setup-qbittorrent.sh /data

set -euo pipefail

# --- Args ---
DATA_ROOT="${1:-}"

# --- Config ---
QBT_USER="qbt"
MEDIA_GROUP="media"
WEBUI_PORT=8080
QBT_SERVICE="qbittorrent-nox.service"
QBT_CONFIG_DIR="/home/${QBT_USER}/.config/qBittorrent"
QBT_CONFIG="${QBT_CONFIG_DIR}/qBittorrent.conf"

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

# Warn if the data root doesn't exist yet (e.g. external drive not mounted)
if [[ ! -d "$DATA_ROOT" ]]; then
    warn "Data root '$DATA_ROOT' does not exist - creating it."
    warn "If this is an external drive, make sure it's mounted first."
    mkdir -p "$DATA_ROOT"
fi

# --- Packages ---
export DEBIAN_FRONTEND=noninteractive
log "Updating package lists..."
apt-get update -qq

log "Checking required packages..."
ensure_package qbittorrent-nox
ensure_package curl

# --- Create media group ---
# Shared group for all media services so they can all read/write the same folders.
# Sonarr, Radarr, Jellyfin will all be added to this group when set up.
if getent group "$MEDIA_GROUP" &>/dev/null; then
    log "Group '$MEDIA_GROUP' already exists."
else
    log "Creating group: $MEDIA_GROUP"
    groupadd "$MEDIA_GROUP"
fi

# --- Create qbt user ---
if id "$QBT_USER" &>/dev/null; then
    log "User '$QBT_USER' already exists."
else
    log "Creating user: $QBT_USER"
    useradd \
        --system \
        --gid "$MEDIA_GROUP" \
        --home-dir "/home/${QBT_USER}" \
        --create-home \
        --shell /usr/sbin/nologin \
        --comment "qBittorrent service user" \
        "$QBT_USER"
fi

# Ensure qbt is in the media group even if user pre-existed
usermod -aG "$MEDIA_GROUP" "$QBT_USER"

# --- Create folder structure ---
# torrents/ and media/ must be on the same filesystem for hardlinks to work.
# Sonarr/Radarr hardlink completed downloads from torrents/ into media/ -
# no copying, instant, no extra disk space used.
log "Creating folder structure under $DATA_ROOT..."

FOLDERS=(
    "${DATA_ROOT}/torrents/tv"
    "${DATA_ROOT}/torrents/movies"
    "${DATA_ROOT}/torrents/other"
    "${DATA_ROOT}/media/tv"
    "${DATA_ROOT}/media/movies"
)

for folder in "${FOLDERS[@]}"; do
    if [[ -d "$folder" ]]; then
        log "Already exists: $folder"
    else
        mkdir -p "$folder"
        log "Created: $folder"
    fi
done

# Set ownership and permissions
# media group gets read/write so all services can access
chown -R "${QBT_USER}:${MEDIA_GROUP}" "$DATA_ROOT"
chmod -R 775 "$DATA_ROOT"
# Setgid bit so new files inherit the media group automatically
find "$DATA_ROOT" -type d -exec chmod g+s {} \;

log "Folder structure ready."

# --- Write qBittorrent config ---
log "Writing qBittorrent config..."
mkdir -p "$QBT_CONFIG_DIR"

cat > "$QBT_CONFIG" << EOF
[BitTorrent]
Session\DefaultSavePath=${DATA_ROOT}/torrents/
Session\TempPath=${DATA_ROOT}/torrents/incomplete/
Session\TempPathEnabled=true

[Preferences]
WebUI\Port=${WEBUI_PORT}
WebUI\Address=0.0.0.0
WebUI\LocalHostAuth=false
WebUI\Username=admin
EOF

# Set ownership of config so qbt user can write to it
chown -R "${QBT_USER}:${MEDIA_GROUP}" "/home/${QBT_USER}/.config"

log "qBittorrent config written."

# --- Write systemd service ---
log "Writing systemd service..."

cat > "/etc/systemd/system/${QBT_SERVICE}" << SVCFILE
[Unit]
Description=qBittorrent-nox
Documentation=https://github.com/qbittorrent/qBittorrent
After=network.target wg-quick@wg0.service
# Optional: if WireGuard is not running, qbt still starts but
# the kill switch will block its external traffic anyway.

[Service]
Type=simple
User=${QBT_USER}
Group=${MEDIA_GROUP}
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure
RestartSec=5

# Give it a data dir it can always find
Environment="HOME=/home/${QBT_USER}"

StandardOutput=journal
StandardError=journal
SyslogIdentifier=qbittorrent-nox

[Install]
WantedBy=multi-user.target
SVCFILE

systemctl daemon-reload
systemctl enable "$QBT_SERVICE"

# --- Stop existing instance if running ---
if systemctl is-active --quiet "$QBT_SERVICE" 2>/dev/null; then
    warn "Stopping existing qbittorrent-nox instance..."
    systemctl stop "$QBT_SERVICE"
fi

systemctl start "$QBT_SERVICE"

# --- Verify ---
log "Waiting for qBittorrent web UI to respond (up to 60s)..."
QBT_READY=0
for i in $(seq 1 60); do
    if curl -sf --max-time 2 "http://localhost:${WEBUI_PORT}/api/v2/app/version" &>/dev/null; then
        QBT_READY=1
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

if [[ "$QBT_READY" -eq 1 ]]; then
    QBT_VERSION=$(curl -sf --max-time 2 "http://localhost:${WEBUI_PORT}/api/v2/app/version" 2>/dev/null || true)
    log "Web UI is up. qBittorrent version: $QBT_VERSION"
else
    die "qBittorrent did not respond after 60s. Check: journalctl -u $QBT_SERVICE -n 50"
fi

# --- Set web UI password ---
# qBittorrent 5.x generates a random temporary password on first run.
# Sniff it from the journal, use it to authenticate, then set our own password.
log "Looking for temporary password in journal..."
TEMP_PASS=""
for i in $(seq 1 10); do
    TEMP_PASS=$(journalctl -u "$QBT_SERVICE" -n 50 --no-pager 2>/dev/null         | grep -oP '(?<=temporary password is provided for this session: )\S+'         | tail -1 || true)
    [[ -n "$TEMP_PASS" ]] && break
    sleep 1
done

if [[ -z "$TEMP_PASS" ]]; then
    warn "Could not find temporary password in journal."
    warn "qBittorrent may have already been initialized with a password."
    warn "If login fails, check: journalctl -u $QBT_SERVICE -n 50 | grep -i password"
else
    log "Temporary password found. Authenticating..."
    COOKIE_JAR=$(mktemp /tmp/qbt-setup-cookies.XXXXXX)

    LOGIN_RESULT=$(curl -sf --max-time 5         --cookie-jar "$COOKIE_JAR"         --data "username=admin&password=${TEMP_PASS}"         "http://localhost:${WEBUI_PORT}/api/v2/auth/login" 2>/dev/null || true)

    if [[ "$LOGIN_RESULT" == "Ok." ]]; then
        log "Authenticated. Setting permanent password..."
        curl -sf --max-time 5             --cookie "$COOKIE_JAR"             --data 'json={"web_ui_password":"adminadmin"}'             "http://localhost:${WEBUI_PORT}/api/v2/app/setPreferences" &>/dev/null             && log "Password set to: adminadmin"             || warn "Failed to set password via API."
    else
        warn "Login with temporary password failed: $LOGIN_RESULT"
        warn "Manual login may be required. Check journal for the temp password."
    fi

    rm -f "$COOKIE_JAR"
fi


# --- Write port forwarding sync script ---
# Polls /run/protonvpn/forwarded-port and updates qBittorrent's listen port
# via the Web API whenever it changes. Runs as a systemd service.
QBT_PORTSYNC_SCRIPT="/usr/local/bin/qbt-port-sync.sh"
QBT_PORTSYNC_SERVICE="qbt-port-sync.service"

log "Writing port sync script to $QBT_PORTSYNC_SCRIPT..."

cat > "$QBT_PORTSYNC_SCRIPT" << 'PSCRIPT'
#!/bin/bash
# Watches /run/protonvpn/forwarded-port and keeps qBittorrent's
# listen port in sync via the Web API.

set -euo pipefail

QBT_URL="http://localhost:8080"
QBT_USER="admin"
QBT_PASS="adminadmin"
PORT_FILE="/run/protonvpn/forwarded-port"
COOKIE_JAR="/tmp/qbt-port-sync-cookies.txt"
POLL_INTERVAL=60   # check every 60s; port file refreshes every 45s

log()  { echo "$(date '+%Y-%m-%dT%H:%M:%S') [qbt-port-sync] $*"; }
warn() { echo "$(date '+%Y-%m-%dT%H:%M:%S') [qbt-port-sync] WARN: $*"; }

qbt_login() {
    rm -f "$COOKIE_JAR"
    local result
    result=$(curl -sf \
        --cookie-jar "$COOKIE_JAR" \
        --data "username=${QBT_USER}&password=${QBT_PASS}" \
        "${QBT_URL}/api/v2/auth/login" 2>&1) || true

    if [[ "$result" == "Ok." ]]; then
        return 0
    else
        warn "Login failed: $result"
        return 1
    fi
}

qbt_set_port() {
    local port="$1"
    curl -sf \
        --cookie "$COOKIE_JAR" \
        --data "json={\"listen_port\":${port},\"random_port\":false}" \
        "${QBT_URL}/api/v2/app/setPreferences" &>/dev/null || return 1
}

qbt_get_port() {
    curl -sf \
        --cookie "$COOKIE_JAR" \
        "${QBT_URL}/api/v2/app/preferences" \
        | grep -oP '(?<="listen_port":)\d+' || echo "0"
}

log "Starting qBittorrent port sync (polling every ${POLL_INTERVAL}s)"

LAST_PORT=""

while true; do
    # Wait for port file to exist (protonvpn-portforward may not be up yet)
    if [[ ! -f "$PORT_FILE" ]]; then
        warn "Port file not found at $PORT_FILE - waiting..."
        sleep 10
        continue
    fi

    # Read the current port from port file
    source "$PORT_FILE"
    CURRENT_PORT="${PORT:-}"

    if [[ -z "$CURRENT_PORT" ]]; then
        warn "PORT not set in $PORT_FILE - waiting..."
        sleep 10
        continue
    fi

    # Only update qBittorrent if the port has changed
    if [[ "$CURRENT_PORT" != "$LAST_PORT" ]]; then
        log "Port changed: ${LAST_PORT:-none} -> $CURRENT_PORT - updating qBittorrent..."

        # Login to get a fresh session cookie
        if qbt_login; then
            if qbt_set_port "$CURRENT_PORT"; then
                ACTIVE_PORT=$(qbt_get_port)
                log "qBittorrent listen port updated to: $ACTIVE_PORT"
                LAST_PORT="$CURRENT_PORT"
            else
                warn "Failed to set port - will retry next poll"
            fi
        else
            warn "Could not authenticate with qBittorrent - is it running?"
        fi
    fi

    # Interruptible sleep - signals (e.g. systemd stop) wake it immediately
    # rather than waiting up to POLL_INTERVAL seconds to exit cleanly
    sleep "$POLL_INTERVAL" & wait $!
done
PSCRIPT

chmod 755 "$QBT_PORTSYNC_SCRIPT"
log "Port sync script written."

# --- Write port sync systemd service ---
log "Writing port sync service: /etc/systemd/system/${QBT_PORTSYNC_SERVICE}..."

cat > "/etc/systemd/system/${QBT_PORTSYNC_SERVICE}" << SVCFILE
[Unit]
Description=qBittorrent Port Forwarding Sync
After=${QBT_SERVICE} protonvpn-portforward.service
BindsTo=${QBT_SERVICE}

[Service]
Type=simple
# Run at low CPU and I/O priority - this is a background polling loop
ExecStart=/usr/bin/nice -n 15 /usr/bin/ionice -c3 ${QBT_PORTSYNC_SCRIPT}
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=qbt-port-sync

[Install]
WantedBy=multi-user.target
SVCFILE

systemctl daemon-reload
systemctl enable "$QBT_PORTSYNC_SERVICE"

if systemctl is-active --quiet "$QBT_PORTSYNC_SERVICE" 2>/dev/null; then
    systemctl restart "$QBT_PORTSYNC_SERVICE"
else
    systemctl start "$QBT_PORTSYNC_SERVICE"
fi

log "Port sync service started."

# --- Summary ---
echo ""
log "=== Setup complete ==="
log "Folder structure:"
log "  Downloads:  ${DATA_ROOT}/torrents/"
log "  Media:      ${DATA_ROOT}/media/"
log "  Incomplete: ${DATA_ROOT}/torrents/incomplete/"
echo ""
log "Web UI:       http://<this-machine-ip>:${WEBUI_PORT}"
log "Credentials:  admin / adminadmin"
echo ""
log "media group members (will grow as services are added):"
getent group "$MEDIA_GROUP"
echo ""
log "Useful commands:"
log "  qBittorrent:  systemctl status $QBT_SERVICE"
log "  Port sync:    systemctl status $QBT_PORTSYNC_SERVICE"
log "  Port sync log: journalctl -u $QBT_PORTSYNC_SERVICE -f"
log "  qBT logs:     journalctl -u $QBT_SERVICE -f"
echo ""
warn "Remember: when moving to external storage, re-run this script"
warn "with the new mount path to update all folder references."

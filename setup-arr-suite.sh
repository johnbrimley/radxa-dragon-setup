#!/bin/bash
# arr stack setup: Prowlarr + Sonarr + Radarr + Jellyseerr
#
# All services run as dedicated users in the 'media' group so they can
# read/write the shared data folders set up by setup-qbittorrent.sh.
#
# Ports:
#   Prowlarr:   http://<ip>:9696
#   Radarr:     http://<ip>:7878
#   Sonarr:     http://<ip>:8989
#   Jellyseerr: http://<ip>:5055
#
# Usage: sudo ./setup-arr.sh /path/to/data/root
# Example: sudo ./setup-arr.sh /srv/media

set -euo pipefail

# --- Args ---
DATA_ROOT="${1:-}"

# --- Config ---
MEDIA_GROUP="media"
INSTALL_BASE="/opt"
CONFIG_BASE="/var/lib"
ARCH="linux-arm64"

# App definitions: name, github repo, port, binary name
declare -A APP_REPOS=(
    [prowlarr]="Prowlarr/Prowlarr"
    [sonarr]="Sonarr/Sonarr"
    [radarr]="Radarr/Radarr"
    [jellyseerr]="Fallenbagel/jellyseerr"
)

declare -A APP_PORTS=(
    [prowlarr]="9696"
    [sonarr]="8989"
    [radarr]="7878"
    [jellyseerr]="5055"
)

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

get_latest_release_url() {
    local repo="$1"
    local pattern="$2"
    curl -sf "https://api.github.com/repos/${repo}/releases/latest" \
        | grep browser_download_url \
        | grep -i "$pattern" \
        | grep -v sha256 \
        | grep -v blockmap \
        | head -1 \
        | cut -d'"' -f4
}

wait_for_port() {
    local name="$1"
    local port="$2"
    local timeout="${3:-30}"
    log "Waiting for $name to respond on port $port (up to ${timeout}s)..."
    for i in $(seq 1 "$timeout"); do
        if curl -sf --max-time 2 "http://localhost:${port}" &>/dev/null; then
            log "$name is up."
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo ""
    warn "$name did not respond after ${timeout}s. It may still be initializing."
    warn "Check: journalctl -u $name -n 50"
    return 1
}

install_arr_app() {
    local name="$1"        # e.g. prowlarr
    local repo="$2"        # e.g. Prowlarr/Prowlarr
    local port="$3"        # e.g. 9696
    local url_pattern="$4" # grep pattern for release asset
    local binary="$5"      # binary name inside tarball
    local data_arg="$6"    # data directory CLI arg format

    local install_dir="${INSTALL_BASE}/${name}"
    local config_dir="${CONFIG_BASE}/${name}"
    local service_name="${name}.service"
    local app_user="${name}"

    log "=== Installing ${name^} ==="

    # --- Create user ---
    if id "$app_user" &>/dev/null; then
        log "User '$app_user' already exists."
    else
        log "Creating user: $app_user"
        useradd \
            --system \
            --gid "$MEDIA_GROUP" \
            --home-dir "$config_dir" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "${name^} service user" \
            "$app_user"
    fi
    usermod -aG "$MEDIA_GROUP" "$app_user"

    # --- Create config dir ---
    mkdir -p "$config_dir"
    chown -R "${app_user}:${MEDIA_GROUP}" "$config_dir"

    # --- Download and install binary ---
    log "Fetching latest ${name^} release URL..."
    local download_url
    download_url=$(get_latest_release_url "$repo" "$url_pattern")
    [[ -z "$download_url" ]] && die "Could not find release URL for ${name^}. Check GitHub API rate limits."
    log "Downloading: $download_url"

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/${name}-install.XXXXXX)
    curl -L --progress-bar "$download_url" -o "${tmp_dir}/${name}.tar.gz"

    # Stop service before replacing binary
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log "Stopping ${name^} for update..."
        systemctl stop "$service_name"
    fi

    log "Extracting to ${install_dir}..."
    rm -rf "$install_dir"
    mkdir -p "$install_dir"
    tar -xzf "${tmp_dir}/${name}.tar.gz" -C "$install_dir" --strip-components=1
    rm -rf "$tmp_dir"

    chown -R "${app_user}:${MEDIA_GROUP}" "$install_dir"
    chmod +x "${install_dir}/${binary}"

    # --- Write systemd service ---
    log "Writing systemd service: /etc/systemd/system/${service_name}..."
    cat > "/etc/systemd/system/${service_name}" << SVCFILE
[Unit]
Description=${name^}
After=network.target

[Service]
Type=simple
User=${app_user}
Group=${MEDIA_GROUP}
ExecStart=${install_dir}/${binary} ${data_arg}${config_dir}
Restart=on-failure
RestartSec=10
TimeoutStopSec=20
KillMode=process
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${name}

[Install]
WantedBy=multi-user.target
SVCFILE

    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl start "$service_name"

    log "${name^} installed and started."
}

install_jellyseerr() {
    local name="jellyseerr"
    local port="${APP_PORTS[$name]}"
    local install_dir="${INSTALL_BASE}/${name}"
    local config_dir="${CONFIG_BASE}/${name}"
    local service_name="${name}.service"
    local app_user="${name}"

    log "=== Installing Jellyseerr ==="

    # Jellyseerr needs Node.js
    if ! command -v node &>/dev/null; then
        log "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    else
        log "Node.js already installed: $(node --version)"
    fi

    # --- Create user ---
    if id "$app_user" &>/dev/null; then
        log "User '$app_user' already exists."
    else
        log "Creating user: $app_user"
        useradd \
            --system \
            --gid "$MEDIA_GROUP" \
            --home-dir "$config_dir" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "Jellyseerr service user" \
            "$app_user"
    fi
    usermod -aG "$MEDIA_GROUP" "$app_user"

    mkdir -p "$config_dir"
    chown -R "${app_user}:${MEDIA_GROUP}" "$config_dir"

    # --- Download latest release ---
    log "Fetching latest Jellyseerr release..."
    local download_url
    download_url=$(get_latest_release_url "Fallenbagel/jellyseerr" "linux-arm64.tar.gz")
    [[ -z "$download_url" ]] && die "Could not find Jellyseerr release URL."
    log "Downloading: $download_url"

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/jellyseerr-install.XXXXXX)
    curl -L --progress-bar "$download_url" -o "${tmp_dir}/jellyseerr.tar.gz"

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log "Stopping Jellyseerr for update..."
        systemctl stop "$service_name"
    fi

    log "Extracting to ${install_dir}..."
    rm -rf "$install_dir"
    mkdir -p "$install_dir"
    tar -xzf "${tmp_dir}/jellyseerr.tar.gz" -C "$install_dir" --strip-components=1
    rm -rf "$tmp_dir"

    chown -R "${app_user}:${MEDIA_GROUP}" "$install_dir"

    # --- Write systemd service ---
    cat > "/etc/systemd/system/${service_name}" << SVCFILE
[Unit]
Description=Jellyseerr
After=network.target

[Service]
Type=simple
User=${app_user}
Group=${MEDIA_GROUP}
WorkingDirectory=${install_dir}
ExecStart=/usr/bin/node ${install_dir}/dist/index.js
Restart=on-failure
RestartSec=10
TimeoutStopSec=20
Environment="NODE_ENV=production"
Environment="CONFIG_DIRECTORY=${config_dir}"
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jellyseerr

[Install]
WantedBy=multi-user.target
SVCFILE

    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl start "$service_name"

    log "Jellyseerr installed and started."
}

# --- Validate ---
[[ -z "$DATA_ROOT" ]] && die "Usage: sudo $0 /path/to/data/root"
[[ "$EUID" -ne 0 ]]   && die "Please run as root (sudo)"
[[ ! -d "$DATA_ROOT" ]] && die "Data root '$DATA_ROOT' does not exist. Run setup-qbittorrent.sh first."

# media group must exist (created by setup-qbittorrent.sh)
getent group "$MEDIA_GROUP" &>/dev/null || die "'$MEDIA_GROUP' group not found. Run setup-qbittorrent.sh first."

# --- Packages ---
export DEBIAN_FRONTEND=noninteractive
log "Updating package lists..."
apt-get update -qq

log "Checking required packages..."
ensure_package curl
ensure_package tar
ensure_package sqlite3  # used by all arr apps

# --- Install arr apps ---
# Pattern matches arm64 tarballs from each app's GitHub releases

install_arr_app \
    "prowlarr" \
    "Prowlarr/Prowlarr" \
    "${APP_PORTS[prowlarr]}" \
    "linux-arm64.tar.gz" \
    "Prowlarr" \
    "--data="

install_arr_app \
    "sonarr" \
    "Sonarr/Sonarr" \
    "${APP_PORTS[sonarr]}" \
    "linux-arm64.tar.gz" \
    "Sonarr" \
    "-data="

install_arr_app \
    "radarr" \
    "Radarr/Radarr" \
    "${APP_PORTS[radarr]}" \
    "linux-arm64.tar.gz" \
    "Radarr" \
    "-data="

install_jellyseerr

# --- Configure media folders in Sonarr and Radarr ---
# These apps need a moment to initialize their databases before we can
# configure them via API. We'll wait and then set the root folders.
log "Waiting for apps to initialize before configuring media folders..."
sleep 15

configure_root_folder() {
    local name="$1"
    local port="$2"
    local path="$3"

    # Get API key from config
    local config_file="${CONFIG_BASE}/${name}/config.xml"
    local api_key=""
    for i in $(seq 1 30); do
        if [[ -f "$config_file" ]]; then
            api_key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$config_file" || true)
            [[ -n "$api_key" ]] && break
        fi
        sleep 2
        echo -n "."
    done
    echo ""

    if [[ -z "$api_key" ]]; then
        warn "Could not read API key for ${name^}. Set root folder manually in the UI."
        return
    fi

    log "Configuring ${name^} root folder: $path"
    curl -sf --max-time 5 \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"${path}\"}" \
        "http://localhost:${port}/api/v3/rootfolder" &>/dev/null \
        && log "${name^} root folder set to: $path" \
        || warn "Could not set ${name^} root folder via API. Set it manually in the UI."
}

configure_root_folder "sonarr" "${APP_PORTS[sonarr]}" "${DATA_ROOT}/media/tv"
configure_root_folder "radarr" "${APP_PORTS[radarr]}" "${DATA_ROOT}/media/movies"

# --- Verify all services ---
echo ""
log "Verifying all services..."
FAILED_SERVICES=()

for app in prowlarr sonarr radarr jellyseerr; do
    port="${APP_PORTS[$app]}"
    if systemctl is-active --quiet "${app}.service" 2>/dev/null; then
        log "  [OK] ${app^}: running (port ${port})"
    else
        warn "  [FAIL] ${app^}: not running"
        FAILED_SERVICES+=("$app")
    fi
done

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
    warn "The following services failed to start: ${FAILED_SERVICES[*]}"
    warn "Check logs: journalctl -u <service> -n 50"
else
    log "All services running."
fi

# --- Summary ---
echo ""
log "=== Setup complete ==="
echo ""
log "Service URLs (replace <ip> with your machine's LAN IP):"
log "  Prowlarr:   http://<ip>:9696  — add indexers here first"
log "  Radarr:     http://<ip>:7878  — movies"
log "  Sonarr:     http://<ip>:8989  — TV shows"
log "  Jellyseerr: http://<ip>:5055  — request UI"
echo ""
log "Next steps:"
log "  1. Prowlarr: add your indexers"
log "  2. Prowlarr: add Sonarr and Radarr as apps (Settings > Apps)"
log "  3. Radarr/Sonarr: add qBittorrent as download client (Settings > Download Clients)"
log "     Host: localhost, Port: 8080, no auth needed from localhost"
log "  4. Jellyseerr: connect to Jellyfin, then Radarr and Sonarr"
echo ""
log "media group members:"
getent group "$MEDIA_GROUP"

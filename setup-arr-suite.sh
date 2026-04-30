#!/bin/bash
# arr stack setup: Prowlarr + Sonarr + Radarr + Seerr + FlareSolverr (via Docker)
#
# All arr services run as dedicated users in the 'media' group.
# Seerr and FlareSolverr run as Docker containers.
#
# Ports:
#   Prowlarr:     http://<ip>:9696
#   Radarr:       http://<ip>:7878
#   Sonarr:       http://<ip>:8989
#   Seerr:        http://<ip>:5055
#   FlareSolverr: http://localhost:8191 (localhost only)
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
SEERR_CONFIG="/var/lib/seerr"
SEERR_PORT=5055
FLARESOLVERR_PORT=8191

declare -A APP_PORTS=(
    [prowlarr]="9696"
    [sonarr]="8989"
    [radarr]="7878"
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
        | grep -v musl \
        | head -1 \
        | cut -d'"' -f4
}

wait_for_service() {
    local name="$1"
    local port="$2"
    local timeout="${3:-45}"
    log "Waiting for ${name} on port ${port} (up to ${timeout}s)..."
    for i in $(seq 1 "$timeout"); do
        if curl -sf --max-time 2 "http://localhost:${port}" &>/dev/null; then
            log "${name} is up."
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo ""
    warn "${name} did not respond after ${timeout}s - may still be initializing."
    warn "Check: journalctl -u ${name} -n 50"
    return 1
}

install_docker() {
    if ! command -v docker &>/dev/null; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    else
        log "Docker already installed: $(docker --version)"
    fi
}

install_arr_app() {
    local name="$1"
    local repo="$2"
    local port="$3"
    local url_pattern="$4"
    local binary="$5"
    local data_flag="$6"

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

    # --- Config dir ---
    mkdir -p "$config_dir"
    chown -R "${app_user}:${MEDIA_GROUP}" "$config_dir"

    # --- Download ---
    log "Fetching latest ${name^} release..."
    local url
    url=$(get_latest_release_url "$repo" "$url_pattern")
    [[ -z "$url" ]] && die "Could not find ${name^} ARM64 release. Check: https://github.com/${repo}/releases"
    log "Downloading: $url"

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/${name}-XXXXXX)

    curl -L --progress-bar "$url" -o "${tmp_dir}/${name}.tar.gz"

    # Stop before replacing binary
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

    # --- Systemd service ---
    cat > "/etc/systemd/system/${service_name}" << SVCFILE
[Unit]
Description=${name^}
After=network.target

[Service]
Type=simple
User=${app_user}
Group=${MEDIA_GROUP}
ExecStart=${install_dir}/${binary} ${data_flag}${config_dir}
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

install_seerr_docker() {
    log "=== Installing Seerr (Docker) ==="

    install_docker

    # --- Config dir ---
    mkdir -p "$SEERR_CONFIG"
    # Seerr container runs as node user (UID 1000)
    chown -R 1000:1000 "$SEERR_CONFIG"

    # --- Pull image ---
    log "Pulling Seerr image..."
    docker pull ghcr.io/seerr-team/seerr:latest

    # --- Remove existing container if present ---
    if docker ps -a --format '{{.Names}}' | grep -q '^seerr$'; then
        log "Removing existing Seerr container..."
        docker rm -f seerr
    fi

    cat > "/etc/systemd/system/seerr.service" << SVCFILE
[Unit]
Description=Seerr
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f seerr
ExecStart=/usr/bin/docker run --rm \
    --name seerr \
    --init \
    -e LOG_LEVEL=info \
    -e PORT=${SEERR_PORT} \
    -p ${SEERR_PORT}:${SEERR_PORT} \
    -v ${SEERR_CONFIG}:/app/config \
    --restart no \
    ghcr.io/seerr-team/seerr:latest
ExecStop=/usr/bin/docker stop seerr
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=seerr

[Install]
WantedBy=multi-user.target
SVCFILE

    systemctl daemon-reload
    systemctl enable seerr.service
    systemctl start seerr.service

    log "Seerr container started."
}

install_flaresolverr_docker() {
    log "=== Installing FlareSolverr (Docker) ==="

    install_docker

    # --- Pull image ---
    log "Pulling FlareSolverr image..."
    docker pull ghcr.io/flaresolverr/flaresolverr:latest

    # --- Remove existing container if present ---
    if docker ps -a --format '{{.Names}}' | grep -q '^flaresolverr$'; then
        log "Removing existing FlareSolverr container..."
        docker rm -f flaresolverr
    fi

    # Bound to localhost only - Prowlarr talks to it internally,
    # no reason to expose it on the LAN
    cat > "/etc/systemd/system/flaresolverr.service" << SVCFILE
[Unit]
Description=FlareSolverr
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f flaresolverr
ExecStart=/usr/bin/docker run --rm \
    --name flaresolverr \
    -e LOG_LEVEL=info \
    -p 127.0.0.1:${FLARESOLVERR_PORT}:${FLARESOLVERR_PORT} \
    --restart no \
    ghcr.io/flaresolverr/flaresolverr:latest
ExecStop=/usr/bin/docker stop flaresolverr
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=flaresolverr

[Install]
WantedBy=multi-user.target
SVCFILE

    systemctl daemon-reload
    systemctl enable flaresolverr.service
    systemctl start flaresolverr.service

    log "FlareSolverr started on localhost:${FLARESOLVERR_PORT}."
}

configure_root_folder() {
    local name="$1"
    local port="$2"
    local path="$3"
    local config_file="${CONFIG_BASE}/${name}/config.xml"
    local api_key=""

    log "Waiting for ${name^} config to initialize..."
    for i in $(seq 1 30); do
        if [[ -f "$config_file" ]]; then
            api_key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$config_file" 2>/dev/null || true)
            [[ -n "$api_key" ]] && break
        fi
        sleep 2
        echo -n "."
    done
    echo ""

    if [[ -z "$api_key" ]]; then
        warn "Could not read ${name^} API key. Set root folder manually: http://<ip>:${port}"
        return
    fi

    log "Setting ${name^} root folder: $path"
    curl -sf --max-time 5 \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"${path}\"}" \
        "http://localhost:${port}/api/v3/rootfolder" &>/dev/null \
        && log "${name^} root folder set to: $path" \
        || warn "Could not set ${name^} root folder via API — set it manually in the UI."
}

# --- Validate ---
[[ -z "$DATA_ROOT" ]] && die "Usage: sudo $0 /path/to/data/root"
[[ "$EUID" -ne 0 ]]   && die "Please run as root (sudo)"
[[ ! -d "$DATA_ROOT" ]] && die "Data root '$DATA_ROOT' does not exist. Run setup-qbittorrent.sh first."
getent group "$MEDIA_GROUP" &>/dev/null || die "'$MEDIA_GROUP' group not found. Run setup-qbittorrent.sh first."

# --- Packages ---
export DEBIAN_FRONTEND=noninteractive
log "Updating package lists..."
apt-get update -qq

log "Checking required packages..."
ensure_package curl
ensure_package tar
ensure_package sqlite3

# --- Install arr apps ---
install_arr_app \
    "prowlarr" \
    "Prowlarr/Prowlarr" \
    "${APP_PORTS[prowlarr]}" \
    "linux-core-arm64.tar.gz" \
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
    "linux-core-arm64.tar.gz" \
    "Radarr" \
    "-data="

install_seerr_docker
install_flaresolverr_docker

# --- Configure media root folders ---
log "Waiting for apps to initialize before configuring media folders..."
sleep 15

configure_root_folder "sonarr" "${APP_PORTS[sonarr]}" "${DATA_ROOT}/media/tv"
configure_root_folder "radarr" "${APP_PORTS[radarr]}" "${DATA_ROOT}/media/movies"

# --- Verify all services ---
echo ""
log "Verifying all services..."
FAILED=()

for app in prowlarr sonarr radarr; do
    if systemctl is-active --quiet "${app}.service" 2>/dev/null; then
        log "  [OK] ${app^} (port ${APP_PORTS[$app]})"
    else
        warn "  [FAIL] ${app^} not running"
        FAILED+=("$app")
    fi
done

if systemctl is-active --quiet "seerr.service" 2>/dev/null; then
    log "  [OK] Seerr (port ${SEERR_PORT})"
else
    warn "  [FAIL] Seerr not running"
    FAILED+=("seerr")
fi

if systemctl is-active --quiet "flaresolverr.service" 2>/dev/null; then
    log "  [OK] FlareSolverr (localhost:${FLARESOLVERR_PORT})"
else
    warn "  [FAIL] FlareSolverr not running"
    FAILED+=("flaresolverr")
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    warn "Failed services: ${FAILED[*]}"
    warn "Check logs: journalctl -u <service> -n 50"
else
    log "All services running."
fi

# --- Summary ---
echo ""
log "=== Setup complete ==="
echo ""
log "Service URLs (replace <ip> with your LAN IP):"
log "  Prowlarr:     http://<ip>:9696  — add indexers here first"
log "  Radarr:       http://<ip>:7878  — movies"
log "  Sonarr:       http://<ip>:8989  — TV shows"
log "  Seerr:        http://<ip>:5055  — request UI"
log "  FlareSolverr: localhost:8191    — Cloudflare bypass (Prowlarr only)"
echo ""
log "Wiring order:"
log "  1. Prowlarr: add FlareSolverr (Settings > Indexers > Proxies > Add > FlareSolverr)"
log "     URL: http://localhost:8191"
log "  2. Prowlarr: add your indexers, assign FlareSolverr proxy to Cloudflare-protected ones"
log "  3. Prowlarr: connect to Sonarr + Radarr (Settings > Apps)"
log "  4. Sonarr + Radarr: add qBittorrent (Settings > Download Clients)"
log "     Host: localhost  Port: 8080  No auth needed"
log "  5. Seerr: connect to Jellyfin, then Sonarr + Radarr"
echo ""
log "media group:"
getent group "$MEDIA_GROUP"

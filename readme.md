# Radxa Dragon Q6A — Media Server Setup

A complete setup guide for a privacy-focused media server running qBittorrent, Prowlarr, Sonarr, Radarr, Seerr, and Jellyfin behind a ProtonVPN WireGuard kill switch.

---

## Script Ordering

Run scripts in this exact order. Each script validates that the previous one has been run.

| Order | Script | Purpose |
|-------|--------|---------|
| 1 | `setup-wifi.sh` | Connect to WiFi via wpa_supplicant + systemd-networkd |
| 2 | `setup-wireguard.sh` | Install WireGuard, configure ProtonVPN kill switch, start port forwarding keepalive |
| 3 | `setup-qbittorrent.sh` | Install qBittorrent-nox, create media folder structure, port sync service |
| 4 | `setup-arr.sh` | Install Prowlarr, Sonarr, Radarr, Seerr (Docker) |
| 5 | `setup-jellyfin.sh` | Install Jellyfin media server |

---

## Prerequisites

- Armbian `current` image for the Radxa Dragon Q6A (non-UFS variant)
- Ethernet connection for initial setup
- A ProtonVPN WireGuard `.conf` file (download from ProtonVPN dashboard — must be a port-forwarding capable server)
- An external drive or mount point for media storage (SD card is fine for initial setup)

---

## 1. WiFi Setup

```bash
chmod +x setup-wifi.sh
sudo ./setup-wifi.sh "YOUR_SSID" "YOUR_PASSWORD"
# Optional — specify interface explicitly if not wlan0:
sudo ./setup-wifi.sh "YOUR_SSID" "YOUR_PASSWORD" wlan0
```

**Verify:**
```bash
ip addr show wlan0
```

You should see an IP address assigned. Once confirmed, ethernet can be unplugged.

---

## 2. WireGuard + ProtonVPN

```bash
chmod +x setup-wireguard.sh
sudo ./setup-wireguard.sh /path/to/protonvpn.conf
```

**What this does:**
- Installs WireGuard and wireguard-tools
- Injects kill switch iptables rules into the WireGuard config:
  - LAN traffic always allowed (SSH, local web UIs)
  - All external traffic must go through `wg0`
  - If VPN drops, external traffic is blocked — no leaks
- Installs and starts `protonvpn-portforward.service` which maintains a NAT-PMP port lease with ProtonVPN, refreshing every 45 seconds
- Port info is written to `/run/protonvpn/forwarded-port`

**Reading the forwarded port:**
```bash
cat /run/protonvpn/forwarded-port
# or in a script:
source /run/protonvpn/forwarded-port && echo $PORT
```

**Verify:**
```bash
wg show wg0
systemctl status protonvpn-portforward
curl https://api.ipify.org   # should return a ProtonVPN IP
```

**Note:** Delete the `.conf` file after running — it contains your private key and is no longer needed.

```bash
rm /path/to/protonvpn.conf
```

---

## 3. qBittorrent

```bash
chmod +x setup-qbittorrent.sh
sudo ./setup-qbittorrent.sh /srv/media
```

**What this does:**
- Creates the `media` group (shared across all services)
- Creates the `qbt` user
- Creates folder structure:
  ```
  /srv/media/
    torrents/
      tv/
      movies/
      other/
      incomplete/
    media/
      tv/
      movies/
  ```
- Installs qBittorrent-nox as a systemd service
- Configures privacy settings via API:
  - Network interface locked to `wg0`
  - UPnP disabled
  - DHT, PEX, LSD disabled
  - Forced encryption
  - Anonymous mode enabled
  - Upload capped at 1 KiB/s
- Installs `qbt-port-sync.service` which watches `/run/protonvpn/forwarded-port` and keeps qBittorrent's listen port in sync

**Web UI:** `http://<ip>:8080`
**Credentials:** `admin` / `adminadmin`

---

## 4. arr Stack

```bash
chmod +x setup-arr.sh
sudo ./setup-arr.sh /srv/media
```

**What this does:**
- Installs Prowlarr, Sonarr, Radarr as native systemd services
- Installs Docker and runs Seerr as a container
- Each arr app runs as its own user in the `media` group
- Automatically configures Sonarr and Radarr root folders via API

**Service URLs:**

| App | URL | Purpose |
|-----|-----|---------|
| Prowlarr | `http://<ip>:9696` | Indexer manager — configure first |
| Radarr | `http://<ip>:7878` | Movies |
| Sonarr | `http://<ip>:8989` | TV shows |
| Seerr | `http://<ip>:5055` | Request UI |

**Wiring order after install:**

1. **Prowlarr** — add your indexers (Settings > Indexers)
2. **Prowlarr** — connect to Sonarr and Radarr (Settings > Apps)
3. **Radarr** — add qBittorrent as download client (Settings > Download Clients)
   - Host: `localhost`
   - Port: `8080`
   - No username/password needed (localhost auth bypass)
   - Set category: `movies`
4. **Sonarr** — same as Radarr but category: `tv`
5. **Seerr** — connect to Jellyfin first, then Radarr and Sonarr

---

## 5. Jellyfin

```bash
chmod +x setup-jellyfin.sh
sudo ./setup-jellyfin.sh /srv/media
```

**What this does:**
- Adds the official Jellyfin Debian repository
- Detects the OS version and installs the correct package variant
- Adds the `jellyfin` user to the `media` group
- Starts Jellyfin as a systemd service

**Web UI:** `http://<ip>:8096`

**Initial browser setup:**
1. Create your admin account
2. Add media libraries:
   - **Movies:** `/srv/media/media/movies`
   - **TV Shows:** `/srv/media/media/tv`
3. Complete the setup wizard

**Generate API key for Seerr:**
- Dashboard > API Keys > Add
- Use this key when connecting Seerr to Jellyfin

---

## Wiring the Stack Together

All configuration below is done in the browser. Do it in this order — each app depends on the one before it.

### Step 1 — Prowlarr: Add FlareSolverr

FlareSolverr lets Prowlarr bypass Cloudflare protection on indexers that use it (including 1337x and EZTV). It runs locally and Prowlarr is the only thing that talks to it.

1. Browse to `http://<ip>:9696`
2. Go to **Settings > Indexers > Proxies > Add Proxy**
3. Select **FlareSolverr**
   - Name: `FlareSolverr`
   - Host: `http://localhost:8191`
4. Click **Test** then **Save**

### Step 2 — Prowlarr: Add Indexers

Indexers are the torrent sites Prowlarr searches on behalf of Sonarr and Radarr. Good starting points for TV and movies:

**Public (no account needed):**
- **1337x** — well organized, broad coverage
- **EZTV** — TV focused
- **YTS** — movies, small file sizes

**Private (invite only, better quality):**
- **BTN (BroadcasTheNet)** — TV, ratio-less
- **MoreThan.TV** — TV, ratio-less
- **PTP (PassThePopcorn)** — movies

To add an indexer:
1. Go to **Settings > Indexers > Add Indexer**
2. Search by name and select it
3. For private trackers, enter your account credentials or passkey
4. Assign the FlareSolverr proxy to indexers that need it (most public ones)
5. Test each one after adding — green means working

### Step 3 — Prowlarr: Connect to Sonarr and Radarr

This syncs your indexers to both apps automatically so you don't have to configure them separately.

1. Go to **Settings > Apps**
2. Add **Sonarr:**
   - Prowlarr Server: `http://localhost:9696`
   - Sonarr Server: `http://localhost:8989`
   - API Key: copy from Sonarr under **Settings > General > API Key**
3. Add **Radarr** the same way using port `7878`
4. Click **Sync App Indexers** — Prowlarr pushes all indexers to both apps

### Step 4 — Radarr: Add qBittorrent as Download Client

1. Browse to `http://<ip>:7878`
2. Go to **Settings > Download Clients > Add**
3. Select **qBittorrent:**
   - Host: `localhost`
   - Port: `8080`
   - Username/Password: leave blank (localhost auth bypass is enabled)
   - Category: `movies`
4. Click **Test** — should show a green checkmark

### Step 5 — Sonarr: Add qBittorrent as Download Client

Same as Radarr but at `http://<ip>:8989` with category: `tv`

### Step 6 — Jellyfin: Initial Setup

1. Browse to `http://<ip>:8096`
2. Create your admin account
3. Add media libraries when prompted:
   - **Movies:** `/srv/media/media/movies`
   - **TV Shows:** `/srv/media/media/tv`
4. Complete the wizard and let the initial library scan finish
5. Generate an API key: **Dashboard > API Keys > +** — copy it for the next step

### Step 7 — Seerr: Connect Everything

1. Browse to `http://<ip>:5055`
2. Connect to **Jellyfin:**
   - URL: `http://localhost:8096`
   - API Key: paste from Step 5
   - Click **Sign In** and select your admin user
3. Connect to **Radarr:**
   - Default Server: yes
   - Host: `localhost`, Port: `7878`
   - API Key: from Radarr under **Settings > General > API Key**
   - Quality Profile: pick your preference
   - Root Folder: `/srv/media/media/movies`
4. Connect to **Sonarr** the same way using port `8989` and root `/srv/media/media/tv`
5. Complete the Seerr setup wizard

---

## Basic Usage

### Requesting Content via Seerr

Seerr is the main interface for day-to-day use — you shouldn't need to touch Radarr or Sonarr directly for normal requests.

1. Browse to `http://<ip>:5055`
2. Search for a movie or TV show
3. Click **Request**
4. For TV shows, select specific seasons or request all
5. The request flows automatically: Seerr → Radarr/Sonarr → Prowlarr finds a release → qBittorrent downloads → files land in `/srv/media/media/` → Jellyfin picks them up on its next scan

Jellyfin scans libraries periodically, but you can trigger an immediate scan: **Dashboard > Libraries > Scan All Libraries**

### Watching Content via Jellyfin

- **Browser:** `http://<ip>:8096`
- **Shield Pro:** Install the Jellyfin app from the Play Store, or use **Streamyfin** for a more polished experience with built-in Seerr request support
- **Mobile:** Jellyfin has official iOS and Android apps

### Monitoring Downloads

qBittorrent web UI at `http://<ip>:8080` — useful for checking download progress and managing the queue directly. You shouldn't need it often since Sonarr/Radarr manage qBittorrent automatically.

### Adding Content Directly in Radarr/Sonarr

For cases where Seerr isn't finding something or you want more control:

**Radarr** — `http://<ip>:7878`
1. Click **+ Add Movie**, search, select quality profile and root folder
2. Radarr searches indexers automatically, or click **Search** manually on the movie page

**Sonarr** — `http://<ip>:8989`
1. Click **+ Add Series**, search, configure, add
2. Select which seasons to monitor

---

## Service Overview

| Service | Type | Port | Manages |
|---------|------|------|---------|
| `wg-quick@wg0` | systemd | — | WireGuard VPN tunnel |
| `protonvpn-portforward` | systemd | — | NAT-PMP port lease keepalive |
| `qbittorrent-nox` | systemd | 8080 | Torrent downloads |
| `qbt-port-sync` | systemd | — | Syncs forwarded port to qBittorrent |
| `prowlarr` | systemd | 9696 | Indexer management |
| `sonarr` | systemd | 8989 | TV show automation |
| `radarr` | systemd | 7878 | Movie automation |
| `seerr` | Docker / systemd | 5055 | Media request UI |
| `flaresolverr` | Docker / systemd | 8191 (localhost only) | Cloudflare bypass for indexers |
| `jellyfin` | systemd | 8096 | Media streaming |

---

## Useful Commands

**Check VPN status:**
```bash
wg show wg0
systemctl status protonvpn-portforward
cat /run/protonvpn/forwarded-port
```

**Check all media services:**
```bash
systemctl status qbittorrent-nox prowlarr sonarr radarr seerr jellyfin
```

**Follow logs:**
```bash
journalctl -u <service-name> -f
```

**Check kill switch rules:**
```bash
iptables -L OUTPUT -n -v --line-numbers
```

**Verify external IP is ProtonVPN:**
```bash
curl https://api.ipify.org
```

---

## Moving to External Storage

When you move from SD card to an external drive, run `setup-qbittorrent.sh` and `setup-arr.sh` again with the new mount path. The scripts are idempotent — they'll update folder references and permissions without breaking existing config.

```bash
sudo ./setup-qbittorrent.sh /mnt/external
sudo ./setup-arr.sh /mnt/external
sudo ./setup-jellyfin.sh /mnt/external
```

Update your Jellyfin library paths manually in the web UI after moving.

---

## Media Group Members

All services share the `media` group for folder access. Check current members:
```bash
getent group media
```

Expected members: `qbt`, `prowlarr`, `sonarr`, `radarr`, `jellyfin`

Seerr runs in Docker as UID 1000 with direct ownership of `/var/lib/seerr`.

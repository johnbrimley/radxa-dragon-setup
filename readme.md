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

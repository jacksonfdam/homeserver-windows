# Self-hosted media server on Windows

A Windows port of the Docker Compose home server described in Fabio Akita's
[Meu "Netflix Pessoal" com Docker Compose](https://akitaonrails.com/2024/04/03/meu-netflix-pessoal-com-docker-compose/)
and published at [akitaonrails/plex_home_server_docker](https://github.com/akitaonrails/plex_home_server_docker),
plus [Komga](https://komga.org/docs/introduction) and [Kavita](https://www.kavitareader.com/)
for comics, manga and ebooks.

The original runs on Ubuntu on an Intel NUC with a Synology NAS mounted at
`/mnt/terachad`. That setup does not translate line by line to Docker Desktop on
Windows, and most of the work here is in the parts that differ.

```
scripts/Setup-HomeServer.ps1    preflight -> folders -> .env -> compose up -> wiring
scripts/Wire-Services.ps1       connects the services to each other via their APIs
scripts/New-Dashboard.ps1       generates the Homepage dashboard config
scripts/Import-MangaLists.ps1   MangaDex / MangaFire lists -> Komga or Kavita
scripts/Clear-StalledQueue.ps1  daily cleanup of dead downloads (Scheduled Task)
scripts/_Common.ps1             shared helpers
docker-compose.yml              the stack
.env.example                    paths, ports, timezone
docs/services.md                every service: ports, access, integration
docs/manga-lists.md             importing reading lists
```

## Prerequisites

- Windows 10 21H2 / Windows 11
- [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/) with
  the **WSL2 backend** and Linux containers (all images here are Linux-only)
- PowerShell 5.1 (built in) or PowerShell 7+
- A drive with room for the library. Put `DATA_ROOT` on the big disk and
  `CACHE_ROOT` on an SSD if you can.

## Quick start

```powershell
git clone <this repo> homeserver-windows
cd homeserver-windows

# Unblock local scripts for this session only
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\scripts\Setup-HomeServer.ps1 -DataRoot C:\media -ConfigRoot C:\homeserver\config
```

qBittorrent 4.6.1 and newer no longer ship with a default password — they
generate a random one on first start and write it to the log. To log in the
first time, read it out:

```powershell
docker logs qbittorrent | Select-String -Pattern "password"
```

Automation does not need it: `WebUI\AuthSubnetWhitelist` is set to the Docker
bridge range, so the *arr containers reach the API without credentials while LAN
clients still get a prompt.

Optional service groups are Compose profiles:

```powershell
# Plex instead of / alongside Jellyfin, SABnzbd for Usenet, Portainer + Watchtower
.\scripts\Setup-HomeServer.ps1 -Profiles plex,usenet,utils
```

Re-running is safe. Every step checks before it writes, and the wiring script
skips anything already registered.

## The seven things that are different on Windows

| Linux original | On Docker Desktop for Windows |
| --- | --- |
| `- /downloads`, `- /movies`, `- /tv` as separate mounts | one `- ${DATA_ROOT}:/data` mount per container |
| hardlinks on ext4 | usually unavailable on NTFS bind mounts, so imports become copies |
| `devices: - /dev/dri` for QSV/VAAPI | no `/dev/dri` at all; NVENC only, through WSL2 GPU support |
| `network_mode: host` for Plex | not supported; explicit port maps + `ADVERTISE_IP` |
| `PUID=1000` / `PGID=1000` mean something | mostly ignored on bind mounts; harmless, kept for the config dirs |
| `/mnt/terachad/Videos` | `C:/media` — forward slashes, always |
| cron / systemd timers | Windows Scheduled Tasks |

### One root path, and why it matters

Every container that moves files gets exactly one mount:

```
C:\media\                     ->  /data
├── torrents\                 ->  /data/torrents        (qBittorrent writes here)
│   ├── incomplete\
│   ├── movies\  tv\  music\  manga\
├── usenet\                   ->  /data/usenet          (SABnzbd, usenet profile)
└── media\                    ->  /data/media           (the library)
    ├── movies\  tv\  anime\  music\
    └── manga\  comics\  books\
```

The article maps `/downloads`, `/movies` and `/tv` separately. Inside the
container those are three different filesystems, so every import turns into a
full copy across a mount boundary — slow, and it doubles the space while both
copies exist. With a single `/data` mount, `torrents` and `media` are siblings on
one filesystem, and Sonarr/Radarr can hardlink or instantly move instead.

That is the theory. In practice, hardlinks on a bind-mounted NTFS drive normally
fail under Docker Desktop, so the setup script **probes it for real** — it
creates a hardlink inside a throwaway container and tells you the result. If it
fails you have three options: accept the copies and keep free space, disable
seeding retention, or move `DATA_ROOT` into the WSL2 filesystem
(`\\wsl$\docker-desktop-data\...`) where hardlinks do work at the cost of
awkward access from Windows.

### Hardware transcoding

`devices: - /dev/dri:/dev/dri` cannot work here: WSL2 does not expose Intel
QuickSync or a VAAPI render node to containers. Your options, in order of how
well they work:

1. **Install Plex or Jellyfin natively on Windows** and point it at `C:\media`.
   This is the only way to get QuickSync, and it is what I would do on a machine
   with an Intel iGPU. Leave the rest of the stack in Docker.
2. **NVENC in the container**, if you have an NVIDIA GPU: a current Windows
   driver plus the commented-out `deploy.resources.reservations.devices` block in
   `docker-compose.yml`.
3. **CPU transcoding**, which is fine if your clients direct play. Which brings up
   the article's best debugging story: playback stuttering that was not the CPU
   at all, but PGS subtitles being rasterised and burned into the video stream.
   If a file stutters, check the subtitle format before you blame the hardware.

### Plex without host networking

Docker Desktop has no `network_mode: host`, so Plex loses GDM auto-discovery on
the LAN. The compose file maps the ports explicitly and sets `ADVERTISE_IP` from
`HOST_IP` (auto-detected by the setup script). For the first start, get a token
from [plex.tv/claim](https://plex.tv/claim) and put it in `.env` as
`PLEX_CLAIM` — it expires after four minutes, so do it right before starting.

Jellyfin has none of this friction, which is why it is in the default profile.

## Ports

| Service | URL | Role |
| --- | --- | --- |
| qBittorrent | http://localhost:8080 | download client |
| Prowlarr | http://localhost:9696 | indexer manager, feeds the others |
| Sonarr | http://localhost:8989 | TV |
| Radarr | http://localhost:7878 | movies |
| Lidarr | http://localhost:8686 | music |
| Bazarr | http://localhost:6767 | subtitles |
| Jellyfin | http://localhost:8096 | player |
| Jellyseerr | http://localhost:5055 | requests |
| Komga | http://localhost:25600 | comics / manga / ebooks |
| Kavita | http://localhost:5001 | comics / manga / ebooks |
| Plex | http://localhost:32400/web | player (`plex` profile) |
| SABnzbd | http://localhost:8085 | usenet (`usenet` profile) |
| Portainer | http://localhost:9000 | container UI (`utils` profile) |
| Homepage | http://localhost:3000 | dashboard, start here |

All overridable in `.env`. Kavita is on 5001 rather than its default 5000
because Windows services and dev servers fight over that port constantly.

Two readers are included on purpose — they overlap almost entirely, and it is
worth running both against the same folders for a week before picking. Komga has
the better library management and OPDS support; Kavita has the nicer reader and
built-in progress sync.

## What the wiring script does

`Wire-Services.ps1` runs automatically at the end of setup and is idempotent:

1. Reads each app's API key straight from `/config/config.xml` inside the
   container.
2. Registers qBittorrent as the download client in Sonarr, Radarr and Lidarr,
   each with its own category (`tv-sonarr`, `radarr`, `lidarr`) so the queues
   never get mixed.
3. Creates the root folders under `/data/media`.
4. Registers the three apps in Prowlarr with `fullSync`, so Prowlarr is the
   single place indexers are managed — the article is emphatic about this, and it
   is right: indexers added by hand inside Sonarr/Radarr are where the bad
   releases came from.
5. Points Bazarr at Sonarr and Radarr.
6. With `-ApplyQualityFloors`: sets a minimum size per quality definition (they
   all ship at zero, which lets a 600 MB file pass as 2160p) and rejects three
   kinds of release that are never worth the bandwidth — an executable payload
   dressed up as a movie, a whole-disc rip most players will not play, and
   stereoscopic 3D. Sonarr gets a release profile for the first; Radarr has no
   such endpoint, so all three become custom formats scored at -10000, far under
   the default minimum of 0, which refuses the release just the same.

7. With `-ApplyNaming`: sets file and folder naming in Sonarr and Radarr, stops
   PROPER releases from jumping ahead of your scoring, and points both at a
   recycle bin under `/data/recycle`. Folders carry the IMDb id so the player
   matches on the id rather than the title, and the anime format carries
   absolute episode numbering — without which an anime library does not sort
   correctly. Off by default because it enables renaming on import, which on an
   existing library means a bulk rename on the next refresh.

Instead of hardcoding provider field lists, it fetches each app's
`/schema` endpoint and overrides only the fields it cares about. That is the
difference between a script that works this month and one that works next year.

The qBittorrent config is seeded before first start with the save paths, a fixed
torrent port, and the excluded-filename list from the article
(`*.exe`, `*.scr`, `*.bat`, …). That last one is the single most useful setting
in the whole stack: a "complete" torrent whose only payload is a renamed
executable never reaches disk, the import fails, and the release gets
blocklisted automatically.

Automation reaches the qBittorrent API without a password because
`WebUI\AuthSubnetWhitelist` is set to `172.16.0.0/12` — the Docker bridge range
only. LAN clients still get a login prompt.

## What the script cannot do

- **Jellyfin / Plex / Komga / Kavita first-run wizards.** Admin account creation
  and library paths are interactive by design. Libraries point at
  `/data/media/movies`, `/data/media/tv`, `/manga`, `/comics`, `/books`.
- **Jellyseerr** needs you to sign in to your Plex or Jellyfin server first, then
  it picks up Sonarr and Radarr in its own setup wizard.
- **Indexers.** Not automated, deliberately. Prowlarr is installed and wired, but
  which indexers you enable — and whether you are entitled to what you pull from
  them — is yours to decide.
- **FlareSolverr** from the original stack is not here. Its whole job is
  defeating bot protection, and I would rather not ship that as a default.
- **Bazarr language profiles.** Bazarr silently ignores any item without one, and
  making one the default only affects items added afterwards, so assign it in
  bulk to the existing library.

## Day 2

```powershell
# status / logs
docker compose ps
docker compose logs -f sonarr

# stop, keeping data
docker compose down

# update everything
docker compose pull; docker compose up -d

# clean dead downloads (dry run, then for real)
.\scripts\Clear-StalledQueue.ps1
.\scripts\Clear-StalledQueue.ps1 -Apply
```

Two Windows-specific things that will bite eventually:

- **WSL2 memory.** Docker Desktop will happily take most of your RAM. Cap it in
  `%UserProfile%\.wslconfig` with `[wsl2]` / `memory=8GB`.
- **Drive sleep.** If `DATA_ROOT` is on an external or spun-down disk, containers
  come back before the disk does after a reboot. Disable sleep for that drive.

## Backup

The only thing worth backing up is `CONFIG_ROOT`. It holds every app database,
API key and setting, and it is small. Media is replaceable; two years of
correctly organised metadata is not.

```powershell
docker compose down
Compress-Archive -Path C:\homeserver\config\* -DestinationPath "C:\backups\homeserver-$(Get-Date -f yyyy-MM-dd).zip"
docker compose up -d
```

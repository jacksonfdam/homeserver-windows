# What Docker Desktop for Windows changes

The stack this is ported from runs on Ubuntu on an Intel NUC with a Synology NAS
mounted at `/mnt/terachad`. Most of the compose file survives the move. The
parts that do not are where all the work in this repository went, and they are
here.

| Linux original | On Docker Desktop for Windows |
| --- | --- |
| `- /downloads`, `- /movies`, `- /tv` as separate mounts | one `- ${DATA_ROOT}:/data` mount per container |
| hardlinks on ext4 | usually unavailable on NTFS bind mounts, so imports become copies |
| `devices: - /dev/dri` for QSV/VAAPI | no `/dev/dri` at all; NVENC only, through WSL2 GPU support |
| `network_mode: host` for Plex | not supported; explicit port maps + `ADVERTISE_IP` |
| `PUID=1000` / `PGID=1000` mean something | mostly ignored on bind mounts; harmless, kept for the config dirs |
| `/mnt/terachad/Videos` | `C:/media` — forward slashes, always |
| cron / systemd timers | Windows Scheduled Tasks |

## One root path, and why it matters

Every container that moves files gets exactly one mount:

```
C:\media\                     ->  /data
├── torrents\                 ->  /data/torrents        (qBittorrent writes here)
│   ├── incomplete\
│   ├── movies\  tv\  music\  manga\
├── usenet\                   ->  /data/usenet          (SABnzbd, usenet profile)
├── recycle\                  ->  /data/recycle         (what imports discard)
└── media\                    ->  /data/media           (the library)
    ├── movies\  tv\  anime\  music\
    └── manga\  comics\  books\
```

The article maps `/downloads`, `/movies` and `/tv` separately. Inside the
container those are three different filesystems, so every import turns into a
full copy across a mount boundary — slow, and it doubles the space while both
copies exist. With a single `/data` mount, `torrents` and `media` are siblings
on one filesystem, and Sonarr/Radarr can hardlink or instantly move instead.

That is the theory. In practice, hardlinks on a bind-mounted NTFS drive normally
fail under Docker Desktop, so the setup script **probes it for real** — it
creates a hardlink inside a throwaway container and tells you the result. If it
fails you have three options: accept the copies and keep free space, disable
seeding retention, or move `DATA_ROOT` into the WSL2 filesystem
(`\\wsl$\docker-desktop-data\...`) where hardlinks do work at the cost of
awkward access from Windows.

**Paths in `.env` use forward slashes** — `D:/media`, never `D:\media`. Compose
mishandles backslashes in volume definitions. `Setup-HomeServer.ps1` rewrites
hand-edited values.

## Hardware transcoding

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

## Plex without host networking

Docker Desktop has no `network_mode: host`, so Plex loses GDM auto-discovery on
the LAN. The compose file maps the ports explicitly and sets `ADVERTISE_IP` from
`HOST_IP` (auto-detected by the setup script). For the first start, get a token
from [plex.tv/claim](https://plex.tv/claim) and put it in `.env` as
`PLEX_CLAIM` — it expires after four minutes, so do it right before starting.

Jellyfin has none of this friction, which is why it is in the default profile.

## Three things that will bite eventually

### Reserved port ranges

Compose fails with *"an attempt was made to access a socket in a way forbidden
by its access permissions"* — which is **not** the port being in use. Hyper-V and
WSL2 reserve blocks of dynamic ports and Windows refuses to bind inside them,
with nothing listening. Port 9000 lands in one often enough that Portainer hits
it. See which ranges are taken:

```powershell
netsh interface ipv4 show excludedportrange protocol=tcp
```

Then pick a port outside them — every port in this stack is a variable in
`.env`, so `PORTAINER_PORT=9001` and re-running is the whole fix.
`net stop winnat` and `net start winnat` clears the reservations instead, but
needs admin and they come back after a reboot.

### WSL2 memory

Docker Desktop will happily take most of your RAM. Cap it in
`%UserProfile%\.wslconfig` with `[wsl2]` / `memory=8GB`.

### Drive sleep

If `DATA_ROOT` is on an external or spun-down disk, containers come back before
the disk does after a reboot. Disable sleep for that drive.

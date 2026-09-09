# Self-hosted media server on Windows

A Windows port of the Docker Compose home server described in Fabio Akita's
[Meu "Netflix Pessoal" com Docker Compose](https://akitaonrails.com/2024/04/03/meu-netflix-pessoal-com-docker-compose/)
and published at [akitaonrails/plex_home_server_docker](https://github.com/akitaonrails/plex_home_server_docker),
plus [Komga](https://komga.org/docs/introduction) and [Kavita](https://www.kavitareader.com/)
for comics, manga and ebooks.

The original runs on Ubuntu on an Intel NUC with a Synology NAS mounted at
`/mnt/terachad`. That does not translate line by line to Docker Desktop on
Windows, and most of the work here is in the parts that differ —
see [docs/windows.md](docs/windows.md).

Manga metadata and the cross-tracker ID map come from
[MangaBaka](https://mangabaka.org/), whose database is licensed
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/).

```
scripts/Setup-HomeServer.ps1         preflight -> folders -> .env -> compose up -> wiring
scripts/Wire-Services.ps1            connects the services to each other via their APIs
scripts/New-Dashboard.ps1            generates the Homepage dashboard config
scripts/Import-MangaLists.ps1        MangaDex / MangaFire lists -> Komga or Kavita
scripts/Update-MangaBaka.ps1         mirrors the MangaBaka series database (Scheduled Task)
scripts/Get-HomeServerStatus.ps1     what is configured, what is not, what to run next
scripts/Start-HomeServerConsole.ps1  interactive console: the same state, plus acting on it
scripts/Clear-StalledQueue.ps1       daily cleanup of dead downloads (Scheduled Task)
scripts/Test-Common.ps1              parse check + smoke test for the shared helpers
scripts/_Common.ps1                  shared helpers
docker-compose.yml                   the stack
.env.example                         paths, ports, timezone
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

Optional service groups are Compose profiles — Plex alongside Jellyfin, SABnzbd
for Usenet, Portainer and Watchtower:

```powershell
.\scripts\Setup-HomeServer.ps1 -Profiles plex,usenet,utils
```

Re-running is safe. Every step checks before it writes, and the wiring script
skips anything already registered.

qBittorrent 4.6.1 and newer no longer ship with a default password — they
generate a random one on first start and write it to the log:

```powershell
docker logs qbittorrent | Select-String -Pattern "password"
```

The automation does not need it: `WebUI\AuthSubnetWhitelist` is set to the
Docker bridge range, so the *arr containers reach the API without credentials
while LAN clients still get a prompt.

Then open the dashboard on `http://localhost:3000`, and use
`.\scripts\Start-HomeServerConsole.ps1` for everything afterwards.

## Where to go next

| | |
| --- | --- |
| [docs/services.md](docs/services.md) | every service: ports, access, first-run wizards, and a symptom-to-cause table |
| [docs/windows.md](docs/windows.md) | what Docker Desktop changes: one root mount, hardlinks, transcoding, reserved ports |
| [docs/tuning.md](docs/tuning.md) | what is configured for you, what is not, and why |
| [docs/guide-parity.md](docs/guide-parity.md) | the two source guides walked step by step, every deviation marked |
| [docs/day-2.md](docs/day-2.md) | the console, maintenance commands, scheduled tasks, backup |
| [docs/manga-lists.md](docs/manga-lists.md) | importing reading lists into Komga or Kavita |
| [docs/manga-anime-sync.md](docs/manga-anime-sync.md) | the list-driven manga pipeline, still being built |

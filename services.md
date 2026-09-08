# Services reference

Every service in the stack: what it does, how to reach it, what it talks to, and
what you have to do by hand. Ports are the defaults from `.env`.

## The dashboard

**Homepage** — `http://<host>:3000` — is the front door. It groups everything by
what you actually want to do:

```
Watch       Jellyfin · Plex
Read        Komga · Kavita
Discover    Jellyseerr
Automation  Sonarr · Radarr · Lidarr · Bazarr
Downloads   qBittorrent · Prowlarr
```

Generate its config with `.\scripts\New-Dashboard.ps1`, which fills in the
Sonarr/Radarr/Lidarr/Prowlarr/Bazarr API keys by reading them out of the running
containers. Credentials it cannot read (Jellyfin key, Komga/Kavita/qBittorrent
logins) go in `.env` as `HOMEPAGE_VAR_*` and are referenced as
`{{HOMEPAGE_VAR_X}}` in the config, so no secrets end up in the YAML files.

Two things worth knowing before you build expectations around it:

- **`HOMEPAGE_ALLOWED_HOSTS` is mandatory** since v1.0. If the page comes up
  blank or complains about the host, that variable does not list the address you
  are using. `New-Dashboard.ps1` sets it from `HOST_IP`.
- **It is a launcher, not a unified player.** Clicking *Anime* opens Jellyfin;
  clicking *Manga* opens Komga. Nothing renders video and manga in one UI,
  because no such thing exists in this space — video servers and comic servers
  have completely different clients. Homepage gives you one URL to remember, one
  page with live queue counts and what is currently playing, and one click into
  the right app.

If you specifically want everything inside a single tabbed window, **Organizr**
(in Akita's original `utils` compose) iframes each service into one shell. It
looks more like "one app", but iframing modern SPAs is fragile and it is a
maintenance tax. I would rather have the launcher.

## Flow

```
                 you ──► Jellyseerr ──► Sonarr / Radarr / Lidarr
                                              │
                              Prowlarr ───────┤  (indexers, synced one way)
                                              ▼
                                        qBittorrent
                                              │  /data/torrents
                                              ▼
                                   import (move or hardlink)
                                              │  /data/media
                              ┌───────────────┼───────────────┐
                              ▼               ▼               ▼
                           Bazarr        Jellyfin/Plex   Komga / Kavita
                        (subtitles)      (watch video)   (read comics)
```

The single rule that keeps this healthy: **Prowlarr is the only place indexers
are managed.** It pushes them into the three apps. Never add an indexer directly
inside Sonarr or Radarr — it will not be tracked, will not be removed when it
dies, and hand-added indexers are the usual source of bad releases.

---

## Watch

### Jellyfin — 8096

Open-source media server. Default player in this stack because it needs no
account, no claim token and no host networking.

**First run:** wizard at `http://<host>:8096` — create the admin user, then add
libraries pointing at `/data/media/movies`, `/data/media/tv` and
`/data/media/anime`. Set the content type correctly per library (Movies / Shows);
that decides which metadata provider is used.

**Anime tip:** make anime its own library with content type *Shows*. Mixed
libraries produce bad matches because the metadata sources differ.

**API key:** Dashboard → Advanced → API Keys. Needed by the Homepage widget and
by Jellyseerr.

**Transcoding:** CPU only unless you have NVIDIA. See the README — there is no
`/dev/dri` on Windows. If playback stutters, check whether the file has PGS
subtitles before blaming hardware; PGS is rendered onto the video and is far
heavier than SRT.

### Plex — 32400 (profile `plex`)

More polished clients and much better smart TV coverage. Costs you a Plex
account and a claim token.

**First run:** get a token from plex.tv/claim (4 minute expiry), put it in `.env`
as `PLEX_CLAIM`, then `docker compose --profile plex up -d plex`. Open
`http://<host>:32400/web`. Libraries live under `/data/media`.

No GDM auto-discovery here — `network_mode: host` does not exist on Docker
Desktop, so `ADVERTISE_IP` does the job instead. Clients on the LAN find the
server through your Plex account rather than broadcast.

---

## Read

Two readers pointed at the same folders, on purpose. Run both for a week and
keep the one you like.

### Komga — 25600

**Strengths:** library management, OPDS, an official Mihon/Tachiyomi
integration, a clean REST API (this is what `Import-MangaLists.ps1` targets by
default).

**First run:** it asks you to create the first account. Add libraries pointing at
`/data/comics`, `/data/manga`, `/data/books`.

**API key:** Account settings → API keys. The ADMIN role is needed to create
collections.

**Organize files as** `Series Name/Series Name - Vol.01.cbz`. Komga derives the
series from the folder, so one folder per series is not optional.

### Kavita — 5001

**Strengths:** the reader itself, progress sync, Want-to-read lists, EPUB
handling.

**First run:** create the admin account, then add libraries for `/manga`,
`/comics`, `/books` — note Kavita mounts these at the root, not under `/data`.

**API key:** Settings → Account → API Key. For the Homepage widget the account
needs the Admin role, otherwise the stats endpoint returns 403.

Port 5001 on the host maps to 5000 in the container, because Windows dev servers
fight over 5000 constantly.

---

## Discover

### Jellyseerr — 5055

Request front-end. Browse what is trending, click Request, and it lands in Sonarr
or Radarr without you opening either.

**First run:** sign in with your Jellyfin or Plex server, then add Sonarr and
Radarr in its settings — it needs the internal URLs `http://sonarr:8989` and
`http://radarr:7878` plus their API keys, a quality profile and a root folder.
This one is not automated because the wizard requires the media-server login
first.

The upstream project merged with Overseerr into **Seerr**. The image here is
still `fallenbagel/jellyseerr`; if you see Seerr referenced elsewhere, it is the
same lineage.

---

## Automation

All three share the same shape: Settings → Download Clients, Media Management,
Profiles, and a v3 REST API (`/api/v3`, Lidarr uses `/api/v1`). `Wire-Services.ps1`
sets up the download client and root folders for you.

### Sonarr — 8989 (TV and anime)

Root folders `/data/media/tv` and `/data/media/anime`. For anime series, set the
series type to *Anime* on the series page — it changes episode numbering from
season/episode to absolute, which is how anime releases are named.

Recommended by hand: Settings → Profiles → Release Profiles, a "Must Not Contain"
list. `Wire-Services.ps1 -ApplyQualityFloors` creates one for executables.

### Radarr — 7878 (movies)

Root folder `/data/media/movies`. Same quality-floor problem as Sonarr: every
quality definition ships with a minimum size of zero, which lets a 600 MB file
claim to be 2160p. `-ApplyQualityFloors` fixes that. Radarr has no release
profile endpoint, so the executable filter there stays a manual custom format.

### Lidarr — 8686 (music)

Root folder `/data/media/music`. Quality profile *Lossless* if you only want
FLAC, *Any* otherwise. Prowlarr syncs music-capable indexers to it automatically.

### Bazarr — 6767 (subtitles)

Watches Sonarr and Radarr and fetches subtitles for new files.

**Two things that make it useless if you skip them:**

1. **Providers.** Nothing works until you add some. OpenSubtitles.com wants your
   *username*, not your email — using the email gets you a 12-hour lockout even
   after you fix it.
2. **Language profiles.** Bazarr silently ignores any item without one. Setting a
   profile as default only affects items added afterwards, so assign it in bulk
   to the existing library. A profile of `pt-BR` then `en` with the cutoff on
   `pt-BR` means it takes Portuguese when it exists and falls back to English.

---

## Downloads

### qBittorrent — 8080

Seeded with save paths, a fixed listening port and the excluded-filename list
before it ever starts. That list is the most valuable setting in the stack: a
torrent whose real payload is a renamed executable never reaches disk, the import
fails, and the release gets blocklisted automatically.

Automation reaches the API without a password because
`WebUI\AuthSubnetWhitelist` covers `172.16.0.0/12` — the Docker bridge range
only. From a LAN device you still get the login prompt, so set a real password in
Options → Web UI before exposing it anywhere.

Categories are set by the wiring script: `tv-sonarr`, `radarr`, `lidarr`.

### SABnzbd — 8085 (profile `usenet`)

Usenet client, useful as a second source for things torrents do not carry. If you
use it, apply the same protection: in `sabnzbd.ini` under `[misc]`, set
`unwanted_extensions` to the same list and `action_on_unwanted_extensions = 2` so
the whole download aborts.

### Prowlarr — 9696

Indexer manager and the only place indexers should exist. It registers itself
with Sonarr, Radarr and Lidarr (done by the wiring script) and pushes its indexer
list into all three on every sync.

**Not automated on purpose:** which indexers you enable. Fewer good ones beat a
long list of bad ones. FlareSolverr, which the original stack used to get past
bot protection, is not included.

---

## Utilities (profile `utils`)

- **Portainer — 9000.** Visual container management. Good for a quick "is
  anything unhealthy" glance and for reading logs without the CLI.
- **Watchtower.** Pulls new images at 04:00 daily and restarts containers. Useful
  and occasionally terrifying; if you would rather control updates, drop the
  `utils` profile and run `docker compose pull; docker compose up -d` yourself.

---

## Port map

| Port | Service | Notes |
| --- | --- | --- |
| 3000 | Homepage | dashboard, start here |
| 5055 | Jellyseerr | requests |
| 5001 | Kavita | container listens on 5000 |
| 6767 | Bazarr | subtitles |
| 6881 | qBittorrent | torrent traffic, TCP + UDP |
| 7878 | Radarr | movies |
| 8080 | qBittorrent | web UI |
| 8085 | SABnzbd | `usenet` profile |
| 8096 | Jellyfin | player |
| 8686 | Lidarr | music |
| 8989 | Sonarr | TV and anime |
| 9000 | Portainer | `utils` profile |
| 9696 | Prowlarr | indexers |
| 25600 | Komga | comics |
| 32400 | Plex | `plex` profile |

## Order of setup

1. `.\scripts\Setup-HomeServer.ps1` — brings everything up and wires the *arr
   apps to each other.
2. `.\scripts\New-Dashboard.ps1` — generates the Homepage config, then
   `docker compose up -d homepage`.
3. First-run wizards: Jellyfin, Komga, Kavita, Jellyseerr. Each needs an admin
   account and library paths; these cannot be automated.
4. Prowlarr: add indexers, then *Sync App Indexers*.
5. Bazarr: providers and a language profile, applied in bulk to the library.
6. `.\scripts\Import-MangaLists.ps1` — bring your MangaDex/MangaFire lists in.
   See [manga-lists.md](manga-lists.md).
7. Optional: register `Clear-StalledQueue.ps1` as a daily Scheduled Task.

## When something does not work

| Symptom | Usual cause |
| --- | --- |
| dashboard blank or host error | `HOMEPAGE_ALLOWED_HOSTS` missing your address |
| widget shows "API Error" | widget `url` must be the container name (`http://sonarr:8989`), not `localhost` |
| Kavita widget 403 | the account needs the Admin role |
| imports are slow, disk fills up | hardlinks unavailable on the NTFS mount, so imports copy |
| Sonarr/Radarr download nothing | no indexers in Prowlarr, or *Sync App Indexers* never run |
| Bazarr finds no subtitles | no providers, or items have no language profile |
| playback stutters on good hardware | PGS subtitles being burned in; switch to an SRT track |
| a service is unreachable after reboot | the data drive spun up after the containers started |

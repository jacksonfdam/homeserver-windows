# Services reference

Every service: where it is, what it needs from you, and what breaks. Ports are
the defaults from `.env` and all of them are overridable there.

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

The rule that keeps it healthy: **Prowlarr is the only place indexers are
managed**, and it pushes them into the other three.

## The stack

| Port | Service | What you have to do |
| --- | --- | --- |
| 3000 | Homepage | dashboard, start here. `.\scripts\New-Dashboard.ps1` generates it |
| 8096 | Jellyfin | wizard: admin user, then libraries on `/data/media/movies`, `/tv`, `/anime`. API key under Dashboard → Advanced. Plugins and theming: [jellyfin-plugins.md](jellyfin-plugins.md) |
| 32400 | Plex | `plex` profile. Claim token in `.env` first, then `docker compose --profile plex up -d plex` |
| 25600 | Komga | wizard: first account, then libraries on `/data/comics`, `/data/manga`, `/data/books`. API key under Account settings |
| 5001 | Kavita | wizard: admin account, then libraries on `/manga`, `/comics`, `/books` — **at the root, not under `/data`** |
| 5055 | Jellyseerr | wizard: sign in to Jellyfin or Plex *first*, then add `http://sonarr:8989` and `http://radarr:7878` with their keys |
| 5056 | Seerr | `ghcr.io/seerr-team/seerr`, the successor. Running alongside Jellyseerr for now, same manual first run |
| 8989 | Sonarr | TV and anime. Set series type *Anime* per anime series |
| 7878 | Radarr | movies |
| 8686 | Lidarr | music. Quality profile *Lossless* for FLAC only, *Any* otherwise |
| 6767 | Bazarr | subtitles. Needs a provider account and a language profile, or it fetches nothing |
| 8080 | qBittorrent | web UI. Set a password before exposing it |
| 6881 | qBittorrent | torrent traffic, TCP + UDP |
| 9696 | Prowlarr | indexers. Add them here, then *Sync App Indexers* |
| 8191 | FlareSolverr | `flaresolverr` profile. Solves Cloudflare challenges for indexers that need it |
| 8085 | SABnzbd | `usenet` profile |
| 9000 | Portainer | `utils` profile. Container UI |
| — | Watchtower | `utils` profile. Pulls new images at 04:00 daily and restarts |

Everything the wiring script sets up for you — download clients, root folders,
Prowlarr registration, Bazarr — is in [tuning.md](tuning.md). First-run wizards
are interactive by design and none of them can be automated.

## The parts that catch people

**Homepage credentials.** `New-Dashboard.ps1` reads the Sonarr/Radarr/Lidarr/
Prowlarr/Bazarr keys out of the running containers. The rest — Jellyfin, Komga,
Kavita, qBittorrent — go in `.env` as `HOMEPAGE_VAR_*` and are referenced as
`{{HOMEPAGE_VAR_X}}`, so no secret lands in a YAML file. A widget it cannot
credential is omitted rather than written broken: Homepage runs `JSON.parse`
over the app's plain-text 401 and the whole page then fails to render, naming no
widget.

**The Jellyfin widget needs `version: 2` against Jellyfin 12.** Homepage still
defaults the widget to version 1, which calls `/emby/Sessions?api_key=...` — the
Emby-compatible alias Jellyfin 12 dropped. The server answers 404 with a
zero-byte body, `JSON.parse` chokes on the empty string, and the widget shows
*Unexpected end of JSON input*, which reads like a bad API key and is not one.
Version 2 calls the native paths and sends the token in an `Authorization`
header. `New-Dashboard.ps1` writes it; a `services.yaml` generated before this
change has to be regenerated, or the line added by hand.

`HOMEPAGE_ALLOWED_HOSTS` is mandatory since v1.0 — without your address in it
the page is blank. `New-Dashboard.ps1` sets it from `HOST_IP`.

It is a launcher, not a unified player. Nothing renders video and manga in one
UI; video servers and comic servers have completely different clients.

**Jellyfin is the default player** because it needs no account, no claim token
and no host networking. Give anime its own library with content type *Shows* —
mixed libraries match badly, because the metadata sources differ.

**Komga derives the series from the folder**, so one folder per series is not
optional: `Series Name/Series Name - Vol.01.cbz`.

**Kavita is on 5001**, mapped to 5000 in the container, because Windows dev
servers fight over 5000 constantly. Its Homepage widget needs an account with
the Admin role or the stats endpoint answers 403 — the same is true of Komga's
collection API.

**Jellyseerr** merged upstream with Overseerr into Seerr; the image here is
still `fallenbagel/jellyseerr`, same lineage. Its Sonarr/Radarr settings cannot
be scripted because the wizard demands the media-server login first.

**qBittorrent** is seeded with save paths, a fixed listening port and the
excluded-filename list before it ever starts, and automation reaches it without
a password because `WebUI\AuthSubnetWhitelist` covers `172.16.0.0/12` — the
Docker bridge range only.

**FlareSolverr is opt-in and tag-driven.** Start it with the `flaresolverr`
profile; the wiring script then registers it in Prowlarr as an indexer proxy and
creates a `flaresolverr` tag. Prowlarr routes an indexer through the proxy only
when the two share that tag, so nothing changes until you tag an indexer — which
is the right default, because each proxied request launches a real browser and
costs seconds and hundreds of MB. Tag only the indexers that actually fail
without it.

**Prowlarr already ships the whole `Prowlarr/Indexers` catalogue** inside its
image, so there is nothing to import for the 500+ definitions in it — they are
in *Add Indexer* already, and they update with the image. `prowlarr/definitions/`
in this repository is only for what is *not* in that catalogue; Setup copies it
into `CONFIG_ROOT/prowlarr/Definitions/Custom/` and restarts Prowlarr, because
definitions are cached at startup. An installed copy that differs is kept as
`.bak` rather than overwritten silently — the Torrentio options string is meant
to be edited.

Shipping a definition is not the same as adding an indexer. Torrentio still has
to be added and configured in Prowlarr like any other.

**Two request front ends are running on purpose, and temporarily.** Seerr is the
successor to Overseerr and Jellyseerr, and it is up *alongside* Jellyseerr so the
two can be compared before one is dropped — they share a lineage, a config layout
(`/app/config`) and a container port, hence 5056 on the host. Both write to the
same Sonarr and Radarr, which duplicates requests and splits approvals, so this
is a state to leave rather than settle into: pick one, then delete the other's
service block and config directory.

Seerr also takes no `PUID`/`PGID` — it runs as its own `node` user and wants the
config directory owned by it, which a Docker Desktop bind mount largely ignores.
Nothing here chowns anything; it is only why that service block looks different
from the rest. Migrating an existing Jellyseerr config is documented upstream but
untried here, so treat Seerr as a fresh install.

**SABnzbd** needs the same payload protection applied by hand: in `sabnzbd.ini`
under `[misc]`, set `unwanted_extensions` to the same list and
`action_on_unwanted_extensions = 2` so the whole download aborts.

## Order of setup

1. `.\scripts\Setup-HomeServer.ps1` — brings everything up and wires the *arr
   apps to each other.
2. `.\scripts\New-Dashboard.ps1`, then `docker compose up -d homepage`.
3. First-run wizards: Jellyfin, Komga, Kavita, Jellyseerr.
4. Prowlarr: add indexers, then *Sync App Indexers*.
5. Bazarr: providers and a language profile, applied in bulk to the library.
6. `.\scripts\Import-MangaLists.ps1` — see [manga-lists.md](manga-lists.md).
7. Optional: `Setup-HomeServer.ps1 -RegisterTasks` for the two daily jobs.

## From a title to a playable file

The thing that trips people first: **you never search in qBittorrent.** It has a
search tab and it is not part of this. qBittorrent only ever receives a magnet
and downloads it. The searching is done by Radarr and Sonarr, against the
indexers Prowlarr manages.

### Three things have to be done by hand first

None of these can be automated, and until all three are done the flow looks
broken rather than unconfigured.

1. **Indexers in Prowlarr.** *Indexers > Add Indexer*, filter by privacy Public
   and the categories you care about, add what looks useful, then **Sync App
   Indexers**. With none, a search returns nothing at all — which reads exactly
   like a bug. Prowlarr showing `0 QUERIES` on the dashboard is this.
2. **Libraries in Jellyfin.** Its first-run wizard wants an admin account and
   paths: `/data/media/movies`, `/data/media/tv`, `/data/media/anime`. A Jellyfin
   reporting zero of everything has no libraries, not no files.
3. **A Jellyseerr login,** if you want it. It is the nice front door for
   requesting, and it needs to sign in to Jellyfin before it will accept Sonarr
   and Radarr. Skipping it costs nothing — searching directly in Radarr and
   Sonarr does the same work.

### Asking for a film

*Radarr > Movies > Add New*, type the title, pick it from the list. Then choose a
quality profile, set the root folder to `/data/media/movies`, and tick **Start
search for missing movie** before adding — without that it is monitored but
nothing happens until the next scheduled search.

### Asking for a series, and the one anime detail

*Sonarr > Series > Add New*, same idea, root folder `/data/media/tv` — or
`/data/media/anime`, which exists as a separate root folder on purpose.

For anime, set **Series Type: Anime** on the series. Anime releases are numbered
absolutely rather than by season and episode, and without this the release names
do not match what Sonarr is looking for, so it finds nothing and looks like an
indexer problem.

### What happens next, and where the file is at each point

1. Radarr or Sonarr queries every indexer Prowlarr synced to it.
2. It picks a release, in this order: quality, then custom format score, then
   protocol, indexer priority, indexer flags, seeds and peers, size. Quality
   wins first — see [tuning.md](tuning.md) if a release you expected loses.
3. The magnet goes to qBittorrent under the category for that app: `radarr`,
   `tv-sonarr` or `lidarr`, so the queues never mix.
4. qBittorrent downloads into `/data/torrents/movies`, `/tv` or `/music`. It is
   visible in its own UI at this stage, and in the *arr app's Activity > Queue.
5. On completion the *arr app imports it: renames it and moves it into
   `/data/media/...`. On this stack that is a copy rather than a hardlink, so the
   file briefly exists twice — see [windows.md](windows.md#one-root-path-and-why-it-matters).
6. Jellyfin picks it up on its next scan. If it does not, the library path is
   wrong or the file name is unparseable.

Nothing here needs babysitting. If it stalls, `Clear-StalledQueue.ps1` clears
dead entries and blocklists the release so the app looks for another source.

### Manga does not work this way yet

Komga and Kavita display what is in `/data/media/manga`, but **nothing in this
stack searches for or downloads manga.** `Import-MangaLists.ps1` compares a
MangaDex or MangaFire list against what is already in your library and writes a
CSV of what is missing — a shopping list, not a queue.

The design for closing that is in [manga-anime-sync.md](manga-anime-sync.md).
Komga and Kavita still need their libraries created in their own first-run
wizards, pointed at `/data/media/manga`, `/data/media/comics` and
`/data/media/books`.

## When something does not work

| Symptom | Usual cause |
| --- | --- |
| dashboard blank or host error | `HOMEPAGE_ALLOWED_HOSTS` missing your address |
| widget shows "API Error" | widget `url` must be the container name (`http://sonarr:8989`), not `localhost` |
| Jellyfin widget: "Unexpected end of JSON input" | the widget is on version 1 and the server is Jellyfin 12+; it needs `version: 2` |
| Kavita widget 403 | the account needs the Admin role |
| imports are slow, disk fills up | hardlinks unavailable on the NTFS mount, so imports copy ([windows.md](windows.md)) |
| Sonarr/Radarr download nothing | no indexers in Prowlarr, or *Sync App Indexers* never run |
| Bazarr finds no subtitles | no providers, or items have no language profile |
| an indexer keeps failing a Cloudflare check | it needs the `flaresolverr` tag, and the profile has to be running |
| playback stutters on good hardware | PGS subtitles being burned in; switch to an SRT track |
| a service is unreachable after reboot | the data drive spun up after the containers started |
| a container will not bind its port | not a conflict — a range Windows reserves ([windows.md](windows.md#reserved-port-ranges)) |

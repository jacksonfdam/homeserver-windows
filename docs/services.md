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
| 8096 | Jellyfin | wizard: admin user, then libraries on `/data/media/movies`, `/tv`, `/anime`. API key under Dashboard → Advanced |
| 32400 | Plex | `plex` profile. Claim token in `.env` first, then `docker compose --profile plex up -d plex` |
| 25600 | Komga | wizard: first account, then libraries on `/data/comics`, `/data/manga`, `/data/books`. API key under Account settings |
| 5001 | Kavita | wizard: admin account, then libraries on `/manga`, `/comics`, `/books` — **at the root, not under `/data`** |
| 5055 | Jellyseerr | wizard: sign in to Jellyfin or Plex *first*, then add `http://sonarr:8989` and `http://radarr:7878` with their keys |
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

## When something does not work

| Symptom | Usual cause |
| --- | --- |
| dashboard blank or host error | `HOMEPAGE_ALLOWED_HOSTS` missing your address |
| widget shows "API Error" | widget `url` must be the container name (`http://sonarr:8989`), not `localhost` |
| Kavita widget 403 | the account needs the Admin role |
| imports are slow, disk fills up | hardlinks unavailable on the NTFS mount, so imports copy ([windows.md](windows.md)) |
| Sonarr/Radarr download nothing | no indexers in Prowlarr, or *Sync App Indexers* never run |
| Bazarr finds no subtitles | no providers, or items have no language profile |
| an indexer keeps failing a Cloudflare check | it needs the `flaresolverr` tag, and the profile has to be running |
| playback stutters on good hardware | PGS subtitles being burned in; switch to an SRT track |
| a service is unreachable after reboot | the data drive spun up after the containers started |
| a container will not bind its port | not a conflict — a range Windows reserves ([windows.md](windows.md#reserved-port-ranges)) |

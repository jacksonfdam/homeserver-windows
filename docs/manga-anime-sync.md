# Manga and anime list sync — design

**Status: decided 2026-09-09.** Manga acquisition goes through AIO Webtoon
Downloader driven by a script in this repository, with MangaBaka as the metadata
and cross-ID source. Nothing is implemented yet; this is the shape to build.

Goal: read reading and watching lists from AniList and MyAnimeList, and have the
stack acquire what is on them — manga into Komga and Kavita, anime into Jellyfin
— reusing the Prowlarr / qBittorrent / Sonarr infrastructure that already exists.

## Three subsystems, not one

The work splits into three pipelines that share almost nothing:

| | list source | acquisition | reader/player |
| --- | --- | --- | --- |
| **A** manga | AniList + MAL | AIO, driven from here | Komga / Kavita |
| **B** anime list sync | AniList + MAL | — bridge to Sonarr — | — |
| **C** anime download | Sonarr | Prowlarr + qBittorrent | Jellyfin |

**C already works.** Sonarr, Prowlarr, qBittorrent and the `/data/media/anime`
root folder are wired by `Wire-Services.ps1`. Nothing to build.

**B is a bridge that does not exist yet.** It is independent of A and can be
built in either order.

## Reference data: MangaBaka

MangaBaka publishes a nightly dump (00:00 UTC, weekly full refresh) as JSON,
JSONL or **SQLite**, in tar.gz or zst, roughly 3 GB uncompressed. It cross-maps
AniList, MyAnimeList, MangaUpdates, Kitsu, Anime-Planet and Shikimori IDs.

That cross-map is the reason it is here: one list on AniList and another on MAL
have to resolve to a single series, and title matching alone will not do it
reliably. The SQLite build can be queried straight from a script with no server,
so it costs one download and a scheduled refresh, not a running service.

Licence: CC BY-NC-SA 4.0 for MangaBaka's own data, personal use, attribution
required. Third-party fields keep their own provider's terms.

## A — manga

AIO Webtoon Downloader is Python 3.8+, GPLv3, CLI plus GUI plus an Electron app,
with no Docker image. It covers 25+ sources and writes CBZ, PDF or EPUB. It is
not a one-shot downloader: `--save-params` records a series and `--update-all`
fetches new chapters later, so the update loop already exists. It also does
cross-site fuzzy search (RapidFuzz) with fallback when a source is missing
chapters, and exposes a FastAPI REST interface.

```
   AniList GraphQL ──┐
                     ├──►  sync script (this repo, PowerShell)
   MAL API v2 ───────┘         │
                               ├──► MangaBaka SQLite ──► cross-ID + metadata
                               │
                               ├──► AIO  (REST or CLI, --update-all)
                               │        cross-site fuzzy search, 25+ sources
                               │              │
                               │              ▼
                               │       CBZ in /data/media/manga
                               │
                               └──► ComicInfo.xml written from MangaBaka
                                              │
                                              ▼
                                      Komga / Kavita
```

### Why this shape

`Import-MangaLists.ps1` already does list export, title normalisation,
Levenshtein matching and CSV reporting. This turns its `missing.csv` from a
backlog into a queue, which is a change of purpose rather than a new subsystem.
No new long-running service, and the result reads like the rest of the repo:
Docker for anything that listens on a port, PowerShell for anything that
orchestrates.

### What has to be built

1. **MangaBaka mirror.** Download and unpack the SQLite dump, refreshed on a
   schedule. A daily Scheduled Task alongside `Clear-StalledQueue.ps1` is the
   obvious home. `.gitignore` already excludes the dump and its archives.
2. **List readers.** AniList over GraphQL, MyAnimeList over API v2. Both need an
   application registration; MAL's is the more awkward of the two.
3. **Resolution.** List entry → MangaBaka row → the identity used everywhere
   downstream. This is what makes "the same series on both lists" one item
   instead of two.
4. **Acquisition.** Hand the resolved series to AIO, preferring its REST
   interface over shelling out so failures come back as data.
5. **ComicInfo.xml.** AIO does not write it, so the script does, from the
   MangaBaka row it already has open. Without this, Komga and Kavita fall back to
   filename parsing and the library metadata is poor.

### What it costs

Recorded here so the trade-off is not rediscovered later as a surprise:

- **No Docker image, so this repository owns one.** Decided rather than left
  open: a Dockerfile here, not Python plus `patchright install chromium` on the
  Windows host. It is the only option that keeps the property the rest of the
  stack has — everything that listens on a port is a container on the
  `homeserver` network, reachable by service name. The cost is an image we build
  and keep working.
- **Cloudflare bypass is internalised.** AIO uses Patchright and cloudscraper
  directly. `CLAUDE.md` records FlareSolverr as a deliberate omission; this does
  not avoid that decision so much as move it inside a dependency.
- **Widevine support ships with it.** `pywidevine` installs along with
  everything else. No part of this design uses that path.
- **The sources are aggregator sites.** Same category as the downloader left out
  of the original stack. Chosen knowingly.
- **The orchestration is ours.** AIO covers the update loop, search and retry;
  everything in "What has to be built" is this repository's to maintain.

## B and C — anime

C is unchanged and already working:

```
   Sonarr ──► Prowlarr ──► qBittorrent   category: tv-sonarr
                                │  /data/torrents/tv
                                ▼
                        import (move or copy)
                                │  /data/media/anime
                                ▼
                            Jellyfin
```

B is the missing bridge, and it has one hard problem worth knowing before
starting: **AniList and MAL are keyed per anime entry, Sonarr is keyed by TVDB
series.** One TVDB series is often several AniList entries — season 1, season 2,
a cour split, a recap — so the mapping is not one-to-one and cannot be derived
from titles reliably.

To verify before designing B:

- whether Sonarr's Import List still offers a generic "Custom List" that takes a
  URL returning JSON, which would let a script here publish the list instead of
  writing to Sonarr's API directly
- which anime ID mapping dataset to use. `Fribb/anime-lists` and
  `manami-project/anime-offline-database` are the usual candidates for
  AniList/MAL to TVDB; both need checking for current coverage

## Open questions

- Does AIO's FastAPI interface cover the whole flow (search, queue, status), or
  only part of it, with the rest CLI-only?
- Hardlinks are expected to fail on the NTFS bind mount. CBZs are small enough
  that copies are cheap, so this matters far less here than for video — but it is
  the same probe result either way.

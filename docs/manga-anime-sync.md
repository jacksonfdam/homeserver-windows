# Manga and anime list sync — design notes

**Status: undecided.** This documents the candidate flows so the trade-offs are
visible before anything is built. Nothing here is implemented yet. Once an option
is picked, the chosen flow becomes the spec and the rest of this file becomes
history.

Goal: read reading/watching lists from AniList and MyAnimeList, and have the
stack acquire what is on them — manga into Komga/Kavita, anime into Jellyfin —
reusing the Prowlarr / qBittorrent / Sonarr infrastructure that already exists.

## Three subsystems, not one

The request splits into three pipelines that share almost nothing:

| | list source | acquisition | reader/player |
| --- | --- | --- | --- |
| **A** manga | AniList + MAL | see options below | Komga / Kavita |
| **B** anime list sync | AniList + MAL | — bridge to Sonarr — | — |
| **C** anime download | Sonarr | Prowlarr + qBittorrent | Jellyfin |

**C already works.** Sonarr, Prowlarr, qBittorrent and the `/data/media/anime`
root folder are wired by `Wire-Services.ps1`. Nothing to build.

**B is a bridge that does not exist yet** and is unrelated to any manga tool.

**A is where the real decision is.**

## Reference data: MangaBaka

Common to every option in A. MangaBaka publishes a nightly dump (00:00 UTC,
weekly full refresh) as JSON, JSONL or **SQLite**, in tar.gz or zst, roughly 3 GB
uncompressed. It cross-maps AniList, MyAnimeList, MangaUpdates, Kitsu,
Anime-Planet and Shikimori IDs.

That cross-map is what makes "one list on AniList, another on MAL" resolvable to
a single series. The SQLite build can be queried directly from a script with no
server, which is why it appears in every flow below.

Licence: CC BY-NC-SA 4.0 for MangaBaka's own data, personal use, attribution
required. Third-party fields keep their own provider's terms.

## Option A1 — Maki, complete

Maki is ASP.NET Core 10 + SQLite, shipped as Docker, web UI on 8990. It is a
Sonarr-for-manga: monitors series, downloads chapters, writes CBZ with
ComicInfo.xml. It syncs with AniList, MAL, Kitsu and MangaBaka as trackers, keeps
a local MangaBaka mirror for metadata, and integrates Kavita, Prowlarr and
qBittorrent. Its own scrapers cover MangaDex, MangaPill, Weeb Central, MangaFire,
MangaPlus, Asura, WEBTOON and more.

```
      AniList ──┐
      MAL ──────┼──►  Maki  ◄── MangaBaka dump (local mirror, ~3 GB)
      Kitsu ────┘      │
                       ├──► built-in scrapers ──► CBZ + ComicInfo.xml
                       └──► Prowlarr ──► qBittorrent ──► import ──► CBZ
                                                             │
                                                    /data/media/manga
                                                             ▼
                                                     Komga / Kavita
```

Everything works out of the box. Two costs, both of which contradict decisions
recorded in `CLAUDE.md`:

- the quick start asks for `FLARESOLVERR_URL`; FlareSolverr is what gets the
  scrapers past Cloudflare, and it was deliberately excluded from this stack
- the scrapers pull from aggregator sites, the same reason Kaizoku was excluded

## Option A2 — Maki as catalogue only

Same container, scrapers left unconfigured, no FlareSolverr. Maki is used for
what it does that nothing else here does: tracker sync, the MangaBaka mirror,
CBZ packaging with ComicInfo.xml, and Kavita integration. Acquisition goes
through the existing Prowlarr → qBittorrent path.

```
      AniList ──┐
      MAL ──────┴──►  Maki (catalogue + metadata)
                        │  MangaBaka mirror resolves cross-IDs
                        ▼
                    Prowlarr  ──► indexers (Nyaa and whatever else is enabled)
                        │
                        ▼
                   qBittorrent   category: manga-maki
                        │  /data/torrents/manga
                        ▼
                    Maki import ──► CBZ + ComicInfo.xml
                        │  /data/media/manga
                        ▼
                  Komga / Kavita   (already mount that path)
```

What it costs in the repo:

- `docker-compose.yml`: one service, port 8990, `${CONFIG_ROOT}/maki:/config` and
  the single `${DATA_ROOT}:/data` mount, behind a new profile
- `.env.example`: `MAKI_PORT=8990`
- `Setup-HomeServer.ps1`: add `maki` to `$configDirs`. The data directories it
  needs — `torrents/manga` and `media/manga` — are already created.
- `Wire-Services.ps1`: register qBittorrent (category `manga-maki`) and Prowlarr
  inside Maki. **To verify: whether Maki exposes a REST API for this, or whether
  it is web-UI only.** If it is UI-only, this step stays manual and belongs in
  the "not done yet" list rather than in the wiring script.
- `New-Dashboard.ps1`: a Maki tile in the Read group

The honest limitation, and it is the deciding one: **torrent indexers carry manga
badly.** Nyaa and friends have completed volumes and archive packs; they do not
have this week's chapter the day it drops. A2 builds a good back catalogue and a
poor ongoing feed. If most of what is on your lists is ongoing series, A2 will
mostly return nothing, and the failure looks like Prowlarr working correctly.

## Option A3 — AIO Webtoon Downloader plus a script here

AIO is Python 3.8+, GPLv3, CLI plus GUI plus an Electron app, no Docker image.
25+ aggregator sites, output as CBZ/PDF/EPUB. Unlike a plain downloader it keeps
state: `--save-params` records a series and `--update-all` fetches new chapters
later. It also does cross-site fuzzy search (RapidFuzz) with fallback when a
source is missing chapters, exposes a FastAPI REST interface, and enriches
metadata from AniList.

```
   AniList GraphQL ──┐
                     ├──►  script (this repo, PowerShell)
   MAL API v2 ───────┘         │
                               ├──► MangaBaka SQLite ──► cross-ID + metadata
                               │
                               ├──► AIO  (REST or CLI, --update-all)
                               │        cross-site fuzzy search, 25+ sources
                               │              │
                               │              ▼
                               │       CBZ in /data/media/manga
                               │
                               └──► generate ComicInfo.xml from MangaBaka
                                              │
                                              ▼
                                      Komga / Kavita
```

Why this one fits the repo: `Import-MangaLists.ps1` already does list export,
title normalisation, Levenshtein matching and CSV reporting. A3 turns its
`missing.csv` from a backlog into a queue. No new long-running service, no
FlareSolverr container, and the shape matches the existing PowerShell + Docker
pattern.

What it costs:

- AIO has no Docker image. Either a Python runtime plus `patchright install
  chromium` on the Windows host, or a Dockerfile this repo owns and maintains.
- AIO does Cloudflare bypass internally (Patchright / cloudscraper). This does
  not avoid the FlareSolverr decision, it relocates it into a dependency.
- It ships `pywidevine` and Widevine DRM support. Nothing in this design needs
  that path, but it installs with everything else.
- No ComicInfo.xml. The script has to generate it — which is tractable, since
  MangaBaka is already open for the ID lookup.
- AniList is metadata only here; there is no MAL support at all. Reading both
  lists stays the script's job either way.

## Options compared

| | A1 Maki full | A2 Maki catalogue | A3 AIO + script |
| --- | --- | --- | --- |
| update loop | service | service | `--update-all` |
| cross-site fuzzy search | — | — | yes |
| reads AniList list | yes | yes | script |
| reads MAL list | yes | yes | script |
| ComicInfo.xml | yes | yes | script generates |
| ongoing chapters | good | **poor** | good |
| back catalogue | good | good | good |
| new service to run | yes | yes | no |
| FlareSolverr | required | not needed | internalised |
| new code to maintain | little | little | the orchestration |
| source of files | aggregators | torrent indexers | aggregators |

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
series.** One TVDB series is often several AniList entries (season 1, season 2,
a cour split, a recap), so the mapping is not one-to-one and cannot be derived
from titles reliably.

To verify before designing B:

- whether Sonarr's Import List still offers a generic "Custom List" that takes a
  URL returning JSON, which would let a script here publish the list instead of
  writing to Sonarr's API directly
- which anime ID mapping dataset to use — `Fribb/anime-lists` and
  `manami-project/anime-offline-database` are the usual candidates for
  AniList/MAL → TVDB, both need checking for current coverage

B does not block A. It should be its own design pass once A is settled.

## Open questions

- Does Maki expose a configuration REST API, or is setup web-UI only? Decides
  whether A1/A2 wiring can join `Wire-Services.ps1` or stays manual.
- Where does the 3 GB MangaBaka dump live, and what refreshes it? A nightly
  Scheduled Task alongside `Clear-StalledQueue.ps1` is the obvious home.
- Hardlinks are expected to fail on the NTFS bind mount. Manga CBZs are small
  enough that copies are cheap, so this matters far less here than for video —
  but it is the same probe result either way.

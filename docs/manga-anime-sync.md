# Manga and anime list sync — design

**Status: decided 2026-09-09. Nothing is implemented yet**, apart from the
MangaBaka mirror. This is the shape to build.

Goal: read reading and watching lists from AniList and MyAnimeList and have the
stack acquire what is on them — manga into Komga and Kavita, anime into Jellyfin
— reusing the Prowlarr / qBittorrent / Sonarr infrastructure that exists.

The work splits into three pipelines that share almost nothing:

| | list source | acquisition | reader/player | state |
| --- | --- | --- | --- | --- |
| **A** manga | AniList + MAL | AIO Webtoon Downloader | Komga / Kavita | to build |
| **B** anime list sync | AniList + MAL | bridge into Sonarr | — | to build |
| **C** anime download | Sonarr | Prowlarr + qBittorrent | Jellyfin | **works** |

C is already wired by `Wire-Services.ps1`. A and B are independent and can be
built in either order.

## Reference data: MangaBaka

A nightly dump (00:00 UTC, weekly full refresh) as JSON, JSONL or **SQLite**,
roughly 3 GB uncompressed, cross-mapping AniList, MyAnimeList, MangaUpdates,
Kitsu, Anime-Planet and Shikimori IDs.

That cross-map is the reason it is here: one list on AniList and another on MAL
have to resolve to a single series, and title matching alone will not do it.
SQLite can be queried from a script with no server, so it costs a download and a
scheduled refresh rather than a running service.

Licence CC BY-NC-SA 4.0, personal use, attribution required. Third-party fields
keep their own provider's terms.

## A — manga

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

AIO Webtoon Downloader is Python 3.8+, GPLv3, and not a one-shot downloader:
`--save-params` records a series and `--update-all` fetches new chapters later,
so the update loop already exists. It also does cross-site fuzzy search with
fallback when a source is missing chapters, and exposes a FastAPI interface.

`Import-MangaLists.ps1` already does list export, normalisation, Levenshtein
matching and CSV reporting, so this turns its `missing.csv` from a backlog into
a queue — a change of purpose rather than a new subsystem.

**To build:**

1. **MangaBaka mirror** — done. `Update-MangaBaka.ps1` downloads the dump,
   verifies the published SHA1 and indexes it.
2. **List readers.** Partly done, and not the way this planned it. Both APIs
   turned out to be blocked rather than awkward: AniList's is switched off by
   its own maintainers, and MAL's API v2 needs a registered client id. So the
   first reader takes the list as text — `-Source MyAnimeList` in
   `Import-MangaLists.ps1` reads either the official gzipped XML export or a
   copy-pasted list page ([manga-lists.md](manga-lists.md)). The export carries
   `manga_mangadb_id`, which is the id step 3 needs; the paste carries titles
   only. The GraphQL and API v2 readers are still worth having when they become
   reachable, because a paste is a snapshot and an API is a sync.
3. **Resolution.** List entry → MangaBaka row → the identity used downstream.
   This is what makes the same series on both lists one item instead of two.
4. **Acquisition.** Hand the resolved series to AIO, preferring REST over
   shelling out so failures come back as data.
5. **ComicInfo.xml.** AIO does not write it, so the script does, from the
   MangaBaka row it already has open. Without it, Komga and Kavita fall back to
   filename parsing.

**What it costs**, recorded so it is not rediscovered as a surprise:

- **No Docker image, so this repository owns one.** A Dockerfile here, not
  Python plus `patchright install chromium` on the Windows host — it is the only
  option that keeps everything that listens on a port a container on the
  `homeserver` network.
- **Cloudflare bypass is internalised.** AIO uses Patchright and cloudscraper
  directly, rather than going through the FlareSolverr container the rest of the
  stack now has. One more bypass path to keep working, not one shared one.
- **`pywidevine` ships with it.** No part of this design uses that path.
- **The sources are aggregator sites**, the same category as the downloader left
  out of the original stack. Chosen knowingly.

## B — the anime bridge

One hard problem, worth knowing before starting: **AniList and MAL are keyed per
anime entry, Sonarr is keyed by TVDB series.** One TVDB series is often several
AniList entries — season 1, season 2, a cour split, a recap — so the mapping is
not one-to-one and cannot be derived from titles.

To verify before designing it:

- whether Sonarr's Import List still offers a generic "Custom List" taking a URL
  that returns JSON, which would let a script publish the list instead of
  writing to Sonarr's API
- which ID mapping dataset to use. `Fribb/anime-lists` and
  `manami-project/anime-offline-database` are the candidates; both need checking
  for current coverage

## Open question

Does AIO's FastAPI interface cover the whole flow — search, queue, status — or
only part of it, with the rest CLI-only?

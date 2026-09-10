# Manga and anime list sync — design

**Status: pipeline A works end to end as of 2026-09-10.** B is still to build.
Steps below are marked as they land, and two of them turned out to be already
done by AIO rather than by this repository.

Goal: read reading and watching lists from AniList and MyAnimeList and have the
stack acquire what is on them — manga into Komga and Kavita, anime into Jellyfin
— reusing the Prowlarr / qBittorrent / Sonarr infrastructure that exists.

The work splits into three pipelines that share almost nothing:

| | list source | acquisition | reader/player | state |
| --- | --- | --- | --- | --- |
| **A** manga | MAL (export or paste) | AIO Webtoon Downloader | Komga / Kavita | **works** |
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
3. **Resolution.** Still to do, and now the weakest link. A list entry goes to
   AIO as a *title*, and AIO's own fuzzy search picks the series — so the same
   manga on two lists is still two items, and a spin-off can win the match.
   `-MinMatch 0.80` and the dry run are the current mitigation, not a fix. The
   MangaBaka row is what would replace the guess.
4. **Acquisition.** Done — `Get-MangaChapters.ps1` and the `aio` service.
   Not over REST, though: **AIO's FastAPI interface does not download.** It
   serves `/api/handlers`, `/api/info`, `/api/chapters`, `/api/chapter_images`
   and `/api/download_image` — metadata and single images, no queue and no job
   status. So the driver runs the CLI, and the container has no port and is run
   one command at a time instead of left running.
5. **ComicInfo.xml.** Already done, by AIO, not by this repository:
   `--metadata-source anilist` writes tags, a description, `<AnilistId>` and
   `<MalId>`, and caches the matched ids so `--update-all` skips the fuzzy
   title match. The compose service turns it on by default. MangaBaka is still
   the better source for step 3, but it is no longer needed to keep Komga off
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

## Answered

**Does AIO's FastAPI interface cover the whole flow?** No — only metadata.
Download, search-and-pick, and `--update-all` are CLI. See step 4.

## Still open

**Whether `--update-all` needs one `--output-dir` per series.** The flag scans
`--output-dir` for saved parameters; whether that scan is recursive is not
documented, and this layout puts each series in its own folder. So
`Get-MangaChapters.ps1 -Update` walks the library itself and runs the flag once
per series. That is correct either way, and wasteful if the scan turns out to
recurse — worth one measurement on a live library.

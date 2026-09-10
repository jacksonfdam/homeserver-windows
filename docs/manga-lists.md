# Importing reading lists from MyAnimeList, MangaDex and MangaFire

Get this straight first: **a list is a set of titles, not files.** Komga and
Kavita only index what exists on disk, so `Import-MangaLists.ps1` reports two
outcomes.

| outcome | what happens |
| --- | --- |
| title already in your library | goes into a Komga collection / Kavita list |
| title not in your library | lands in `lists/missing-<date>.csv`, your backlog |

**This script downloads nothing.** That is a separate command, on purpose, and
it takes `missing.csv` as its input — see
[Downloading the backlog](#downloading-the-backlog) at the end.

## Getting the list out

**A public MangaDex list** needs no auth — the UUID is in its URL:

```powershell
.\scripts\Import-MangaLists.ps1 -Source MangaDex -ListId 1b8e5d1a-... -Target Komga
```

If your follows are private, the least painful route is to dump them into an
MDList, make it public, and use its UUID.

**Your MangaDex follows** need a personal API client: mangadex.org → Settings →
API Clients. The legacy `/auth/login` is gone, and approval is a manual review
that takes a day or two.

```powershell
.\scripts\Import-MangaLists.ps1 -Source MangaDex -Follows -Target Kavita
```

It prompts for the client id/secret, exchanges them at `auth.mangadex.org` for a
short-lived token and keeps it in memory only. Pass `-AccessToken` to skip the
prompts. Requests are spaced 250 ms apart, because MangaDex rate limits at
roughly 5/second.

**MyAnimeList** has two routes, and the first one is better.

The official export is under mal.net → Profile → Lists → *Export*, which mails
you a gzipped XML. Pass it as-is; it does not need unpacking, and MAL does not
always name it `.gz`.

```powershell
.\scripts\Import-MangaLists.ps1 -Source MyAnimeList -Path .\lists\mal.xml.gz -Status Reading
```

Prefer it because it carries `manga_mangadb_id` — the MAL id, which is what
[MangaBaka](manga-anime-sync.md) cross-maps to AniList and MangaUpdates. Titles
are the fuzzy part of this whole script; an id is not.

The second route needs nothing at all: open your manga list in the browser,
select the table, copy, paste into a `.txt` and pass that.

```powershell
.\scripts\Import-MangaLists.ps1 -Source MyAnimeList -Path .\lists\mal.txt -Status Reading
```

It exists because MAL's API needs a registered client id, and a copy always
works. What you lose is the id, so everything falls back to title matching.

Two things about that paste, both of which the parser handles and neither of
which is obvious:

- **MAL omits the Score cell rather than emptying it.** A row you have not
  scored has one fewer cell than a row you have, so anything counting columns
  reads `0/232` as a score of 232. The parser classifies each cell instead —
  status header, column header, media type, progress, or a title.
- **A title that is *entirely* a progress cell would be misread.** `Kaiju No.8`
  and `20th Century Boys` are safe; a manga titled exactly `86` would attach
  itself to the row above.

`-Status` takes any of `Reading`, `Completed`, `Paused`, `Dropped`, `Planning`
and defaults to all of them. Worth being deliberate: `Planning` is a wishlist
and `Paused` is usually a much larger backlog than `Reading`. It also names the
collection, so `-Status Reading` lands in a Komga collection called
`MyAnimeList Reading`.

**AniList is not a source yet.** Its API is switched off by its own maintainers,
and until it returns the way in is the same paste.

**MangaFire has no API** and the bookmark page is behind your session. Scroll to
the bottom first — only what is in the DOM gets exported — then in the DevTools
console:

```js
copy(JSON.stringify([...document.querySelectorAll('a[href*="/manga/"]')]
  .map(a => ({
    title: (a.getAttribute('title') || a.textContent).trim(),
    slug:  a.getAttribute('href').split('/manga/')[1].split(/[?#]/)[0],
    url:   new URL(a.getAttribute('href'), location.origin).href
  }))
  .filter(x => x.title.length > 1)
  .filter((x, i, arr) => arr.findIndex(y => y.slug === x.slug) === i), null, 2));
```

Paste into `mangafire.json` and pass `-Source MangaFire -Path .\mangafire.json`.
If the markup changes and the selector stops working, save the page with Ctrl+S
and pass the `.html` instead — there is a regex fallback that pulls every
`/manga/<slug>` anchor.

## Matching

This is the part that needs care, because the same series is
`Kaguya-sama: Love is War`, `Kaguya-sama wa Kokurasetai` or
`かぐや様は告らせたい` depending on who tagged it.

Both sides are normalised (lowercase, punctuation and articles stripped, CJK
ranges kept), searched with up to three title variants, and scored with a
Levenshtein ratio:

- **≥ 0.85** → used automatically
- **0.60 – 0.85** → printed for review, not used
- **< 0.60** → missing

Tune with `-AutoThreshold` and `-ReviewThreshold`. **The first run is always a
dry run**; read `lists/match-report-<date>.csv` before adding `-Apply`.

## Where it lands

**Komga** gets a series-level collection, merged rather than duplicated on a
re-run. **Kavita** gets your *Want to read* list, which maps to "titles I
follow" better than anything else there; `-KavitaReadingList` creates a proper
reading list instead, but Kavita reading lists are chapter-level, so that
expands every chapter of every matched series.

Both need an API key with the Admin role, from `.env` (`KOMGA_API_KEY`,
`KAVITA_API_KEY`) or `-KomgaApiKey` / `-KavitaApiKey`.

```powershell
.\scripts\Import-MangaLists.ps1 -Source MangaDex -ListId <uuid> -Target Komga `
    -CollectionName 'MangaDex follows' -Apply
```

Re-run it after adding files. Titles that were missing last month match once the
files exist, and the collection merge makes re-running cheap.

If you also use Mihon/Tachiyomi, Komga speaks its integration protocol directly
— syncing progress that way is less work than converting backups.

## Downloading the backlog

`Get-MangaChapters.ps1` takes the `missing.csv` this script wrote and fetches
it, through the `aio` container ([AIO Webtoon
Downloader](https://github.com/zzyil/AIO-Webtoon-Downloader)). It is a separate
command because it is a separate decision: matching a list against your library
is bookkeeping, and pulling chapters off aggregator sites is not.

The container has no port and nothing listening — AIO's REST API turned out to
serve metadata only, so acquisition is its CLI. Compose builds the image the
first time you run it, which takes several minutes and about 2 GB, most of it
Chromium: MangaFire hides its image URLs behind a token generated by page
script, and a few Cloudflare-protected sources are solved the same way.

```powershell
# what would be fetched, and from which site - downloads nothing
.\scripts\Get-MangaChapters.ps1 -Title 'Dandadan'

# the backlog, ten titles at a time
.\scripts\Get-MangaChapters.ps1 -FromCsv .\lists\missing-2026-09-10.csv -Limit 10 -Apply

# new chapters for everything already fetched
.\scripts\Get-MangaChapters.ps1 -Update -Apply
```

**Read the dry run.** It prints the ranked candidates per title with the source
site and the match score, and it exists because the failure mode is not a
missing download — it is the wrong series sitting in a folder named after the
right one. `-MinMatch` defaults to `0.80`; AIO's own default is `0.55`, which is
loose enough to pick a spin-off over the series you meant, and `-Apply` acts on
the top hit.

Each series gets its own folder under `DATA_ROOT/media/manga`, which is the
directory Komga already mounts as `/data/manga` and Kavita as `/manga` — so a
finished CBZ is in the library with no move and no second copy. This matters
more than it sounds: AIO names its output `<Title>_Ch_1-5.cbz` and writes it
flat, and both readers treat a *directory* as a series, so one shared output
directory would make every file its own series.

CBZ rather than AIO's default EPUB, and `--metadata-source anilist` on by
default — that is what makes AIO write `ComicInfo.xml`, with tags, a
description and the AniList and MAL ids, which is the difference between a
properly identified series and one parsed out of a filename.

Rescan the library in Komga or Kavita afterwards. Both poll on their own, so
this is only about not waiting out the interval.

Useful flags: `-Chapters "50-"` for everything from 50 onwards, `-Language`,
`-Jobs` for parallel series (each one may run a browser, so it costs memory
rather than CPU), and `-Format epub|pdf` if it is not going into a comic reader
at all.

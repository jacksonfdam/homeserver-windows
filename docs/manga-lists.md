# Importing reading lists from MyAnimeList, MangaDex and MangaFire

Get this straight first: **a list is a set of titles, not files.** Komga and
Kavita only index what exists on disk, so `Import-MangaLists.ps1` reports two
outcomes.

| outcome | what happens |
| --- | --- |
| title already in your library | goes into a Komga collection / Kavita list |
| title not in your library | lands in `lists/missing-<date>.csv`, your backlog |

Nothing here auto-downloads that backlog — Kaizoku, the downloader in the
original setup, pulls from aggregator sites and is deliberately absent. The
`missing.csv` is a shopping list.

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

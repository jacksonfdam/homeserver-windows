# Importing reading lists from MangaDex and MangaFire

The thing to get straight first: **a list is a set of titles, not files.** Komga
and Kavita only index what exists on disk. So importing a list splits into two
outcomes, and `Import-MangaLists.ps1` reports both:

| outcome | what happens |
| --- | --- |
| title already in your library | goes into a Komga collection / Kavita list |
| title not in your library | lands in `lists/missing-<date>.csv`, your backlog |

Nothing in this stack auto-downloads the backlog. Kaizoku, the downloader in the
original setup, pulls from aggregator sites, so it is not included here — the
`missing.csv` is a shopping list, and what you do with it is your call.

## 1. Get the list out

### MangaDex — a public list (easiest, no auth)

Every MDList has a UUID in its URL: `mangadex.org/list/<uuid>`. That is all you
need:

```powershell
.\scripts\Import-MangaLists.ps1 -Source MangaDex -ListId 1b8e5d1a-... -Target Komga
```

If your follows are private, the least painful route is to create an MDList,
dump your follows into it, make it public, and use its UUID.

### MangaDex — your follows (needs a personal API client)

MangaDex moved to OAuth2. The legacy `/auth/login` is gone, so you need a
**personal API client**: mangadex.org → Settings → API Clients → create one, and
wait for approval (it is a manual review, usually a day or two).

```powershell
.\scripts\Import-MangaLists.ps1 -Source MangaDex -Follows -Target Kavita
```

It prompts for the client id/secret and your credentials, exchanges them at
`auth.mangadex.org` for a short-lived access token, and keeps it in memory only.
If you already have a token from somewhere else, pass `-AccessToken` and skip the
prompts entirely.

The script paginates `/user/follows/manga` at 100 per page, hydrates titles via
`/manga?ids[]=`, and sleeps 250 ms between calls — MangaDex rate limits around 5
requests/second and will start returning 429s if you ignore that.

### MangaFire — no API, so dump the DOM

MangaFire has no public API and the bookmark page is behind your session. Open
your folder page while logged in, then in DevTools console:

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

`copy()` puts it on the clipboard. Paste into `mangafire.json` and:

```powershell
.\scripts\Import-MangaLists.ps1 -Source MangaFire -Path .\mangafire.json -Target Komga
```

If the site's markup changes and the selector stops working, save the page with
Ctrl+S and pass the `.html` instead — the script has a regex fallback that pulls
every `/manga/<slug>` anchor and de-duplicates by slug.

Scroll to the bottom of the page first if the list is lazy-loaded. Only what is
in the DOM gets exported.

## 2. Matching

Matching is the part that actually needs care, because the same series shows up
as `Kaguya-sama: Love is War`, `Kaguya-sama wa Kokurasetai`, and
`かぐや様は告らせたい` depending on who tagged it.

The script normalises both sides (lowercase, strip punctuation and articles,
keep CJK ranges), searches the library with up to three of the title variants,
and scores every candidate against every variant with a Levenshtein ratio:

- **≥ 0.85** → `matched`, used automatically
- **0.60 – 0.85** → `review`, printed and written to the report, not used
- **< 0.60** → `missing`

Tune with `-AutoThreshold` and `-ReviewThreshold`. The first run is always a dry
run; `lists/match-report-<date>.csv` is what you should read before adding
`-Apply`.

## 3. Where it lands

**Komga** gets a collection (series-level, which is what you want for a list of
manga). Re-running merges into the existing collection instead of duplicating
it. Needs an API key with the ADMIN role — Komga UI → Account settings → API
keys — as `KOMGA_API_KEY` in `.env` or `-KomgaApiKey`.

**Kavita** gets your *Want to read* list by default, which maps to "titles I
follow" better than anything else there. Pass `-KavitaReadingList` to create a
proper reading list instead — note that Kavita reading lists are chapter-level,
so it expands every chapter of every matched series. Needs the API key from
Kavita → Settings → Account, as `KAVITA_API_KEY` in `.env` or `-KavitaApiKey`.

```powershell
.\scripts\Import-MangaLists.ps1 -Source MangaDex -ListId <uuid> -Target Komga `
    -CollectionName 'MangaDex follows' -Apply
```

## Notes

- Both API keys can live in `.env` (`KOMGA_API_KEY`, `KAVITA_API_KEY`); it is
  already gitignored.
- Komga's `GET /api/v1/series?search=` is deprecated. The script uses
  `POST /api/v1/series/list` with a `fullTextSearch` body, which is the current
  search endpoint.
- Kavita authenticates via `POST /api/Plugin/authenticate` — the API key is
  exchanged for a JWT per run rather than sent on every call.
- If you also use Mihon/Tachiyomi, its backup file is a third possible source.
  Komga speaks the Mihon integration protocol directly, so syncing progress that
  way is usually less work than converting backups.
- Re-run the whole thing after adding files. Titles that were `missing` last
  month will match once the files are there, and the collection merge means
  re-running is cheap.

# CLAUDE.md

Context for whoever picks this up next, human or agent. Read this before changing
anything — several choices here look wrong until you know why they were made, and
a well-intentioned "fix" will undo them.

## What this is

A Windows port of a self-hosted media server stack, adapted from
[akitaonrails/plex_home_server_docker](https://github.com/akitaonrails/plex_home_server_docker)
and the article [Meu "Netflix Pessoal" com Docker Compose](https://akitaonrails.com/2024/04/03/meu-netflix-pessoal-com-docker-compose/),
plus Komga and Kavita for comics/manga.

The repo lives on macOS (`/Volumes/Projects/homeserver`) but the target is a
Windows PC running Docker Desktop with the WSL2 backend. Nothing here can be
tested on the Mac. Do not "simplify" the Windows-specific handling just because
it looks redundant from a Unix shell.

## Layout

```
docker-compose.yml                   the whole stack, one file, Compose profiles
.env.example                         paths, ports, TZ, dashboard vars
scripts/_Common.ps1                  shared helpers, dot-sourced by everything else
scripts/Setup-HomeServer.ps1         entry point: preflight -> folders -> .env -> up -> wiring
scripts/Wire-Services.ps1            connects services to each other via REST APIs
scripts/New-Dashboard.ps1            generates Homepage YAML config
scripts/Import-MangaLists.ps1        MangaDex/MangaFire lists -> Komga/Kavita
scripts/Update-MangaBaka.ps1         mirrors the MangaBaka SQLite dump locally
scripts/Get-HomeServerStatus.ps1     read-only report of what is configured and running
scripts/Start-HomeServerConsole.ps1  interactive console: same state, plus acting on it
scripts/Clear-StalledQueue.ps1       removes dead downloads, meant as a Scheduled Task
scripts/Test-Common.ps1              parses every script, smoke-tests the pure helpers
docs/services.md                     per-service reference: ports, access, integration
docs/tuning.md                       automated vs manual vs deliberately-not-done settings
docs/manga-lists.md                  the list import flow
```

## Decisions that must not be reverted casually

**One `/data` mount per container.** The upstream repo maps `/downloads`,
`/movies` and `/tv` separately. Inside the container those are separate
filesystems, so every import is a cross-device copy. Everything here mounts
`${DATA_ROOT}:/data` with `torrents/` and `media/` as siblings. If you split
these again, imports get slow and double the disk usage.

**Forward slashes in `.env` paths.** `D:/media`, never `D:\media`. Compose
mishandles backslashes in volume definitions. `Convert-ToDockerPath` normalises
this and `Setup-HomeServer.ps1` rewrites hand-edited values.

**No `/dev/dri`, no `network_mode: host`.** Neither exists on Docker Desktop for
Windows. The NVENC block in the compose file is commented out on purpose — it
only works with an NVIDIA GPU plus WSL2 GPU support. Intel QuickSync is
impossible in a container here; the documented answer is to run Plex/Jellyfin
natively on Windows.

**Provider registration is schema-driven.** `New-ProviderFromSchema` in
`_Common.ps1` fetches each app's `/schema` endpoint and overrides only the fields
it cares about, instead of hardcoding a field list. This is what makes the wiring
survive *arr version bumps. Do not replace it with a literal JSON body.

**PowerShell 5.1 compatibility.** No `?.`, no `??`, no ternaries, no
`-SkipHttpErrorCheck`, no `Set-StrictMode` (it makes the defensive property
checks throw). Windows PowerShell 5.1 is what ships on the box; PS7 is not
assumed.

**Everything is idempotent.** Re-running any script must be safe. Existing
providers are detected by name and skipped; the Komga collection merges rather
than duplicating; config files are backed up before being rewritten.

**Two deliberate omissions.** FlareSolverr is not in the stack (its purpose is
defeating bot protection) and no indexers are preconfigured in Prowlarr. Both
were left out on purpose, not forgotten. Kaizoku (the manga downloader from the
original repo) is out for the same reason — `missing.csv` from the list import is
a backlog, not a download queue.

## API facts verified against source, not memory

These were checked against the actual specs while building. If something breaks,
re-verify rather than guessing:

- **Komga** `GET /api/v1/series?search=` is marked `deprecated: true` in
  `komga/docs/openapi.json`. Use `POST /api/v1/series/list` with a
  `{ "fullTextSearch": "..." }` body. Auth is `X-API-Key` header or basic.
  `POST /api/v1/collections` requires `{name, ordered, seriesIds}` — all three,
  `seriesIds` with `minItems: 1`, ADMIN role.
- **Kavita** exchanges the API key for a JWT:
  `POST /api/Plugin/authenticate?apiKey=...&pluginName=...`. Search is
  `GET /api/Search/search?queryString=` returning `series[]` with `seriesId`.
  Want-to-read is `POST /api/want-to-read/add-series` with `{seriesIds}`. Reading
  lists are chapter-level: `POST /api/ReadingList/create` with `{title}` then
  `POST /api/ReadingList/update-by-multiple-series` with
  `{readingListId, seriesIds}`.
- **MangaDex** legacy `/auth/login` is gone. Follows need a personal API client
  (manual approval) and the password grant at
  `auth.mangadex.org/realms/mangadex/protocol/openid-connect/token`. Public
  MDLists need no auth: `GET /list/{uuid}` then `GET /manga?ids[]=` in batches of
  100. Rate limit is roughly 5 req/s, hence the 250 ms sleep.
- **Homepage** requires `HOMEPAGE_ALLOWED_HOSTS` since v1.0 or it renders blank.
  Widget `url` must be the container name; `href` must be the host address.
  Komga and Kavita widgets each take **either** an API key or username+password,
  and the key is what their UIs actually hand you - Kavita shows it inside the
  OPDS URL, Komga under Account settings. Jellyfin takes an API key. The Kavita
  account needs the Admin role either way, or the stats endpoint refuses.
  A widget whose credential is missing or wrong does not degrade: Homepage
  proxies the call, the app answers 401 in plain text, Homepage runs JSON.parse
  over it and throws, and the whole page then fails to render with a client-side
  error naming no widget. New-Dashboard.ps1 therefore omits a widget rather than
  writing one it cannot credential.
- **qBittorrent** 4.6.1+ generates a random temporary WebUI password on first
  start and logs it. `admin`/`adminadmin` is no longer the default. The seed
  config relies on `WebUI\AuthSubnetWhitelist=172.16.0.0/12` (Docker bridge only)
  so automation works without credentials.

## Not done yet

- **Jellyseerr wiring is manual.** It needs a Jellyfin/Plex login before it will
  accept Sonarr/Radarr settings, so the wizard cannot be skipped.
- **Bazarr's settings endpoint has three traps**, all established against a live
  instance. Booleans must be lower case: `'True'` is rejected with 406 and the
  whole form is discarded with it, which is why this wiring silently did nothing
  for a long time. A 204 is not proof of anything - field names missing the
  `settings-` prefix are also accepted, write the wrong type into config, and
  take Bazarr down on its next read, so values are read back rather than
  trusted. And changing `use_sonarr` restarts Bazarr, so the connection drops
  before the response arrives even though the write applied - which is why the
  connection settings are sent last. Confusingly, the profile JSON wants the
  string `'False'` where the form wants `false`.
- **First-run wizards** for Jellyfin, Komga and Kavita are interactive by design.
  Do not try to automate account creation.
- **Radarr has no release-profile endpoint**, so the executable filter exists only
  in Sonarr. The Radarr equivalent would be a custom format.
- **Scheduled tasks are opt-in.** `Setup-HomeServer.ps1 -RegisterTasks`
  registers the two daily jobs; without the switch nothing is scheduled, because
  creating scheduled work on someone's machine unasked is intrusive. Both run as
  the invoking user and only while logged on — changing that needs a stored
  password, which the script will not prompt for.
- **Hardlinks almost certainly fail on the NTFS bind mount.**
  `Setup-HomeServer.ps1` probes this at runtime with a throwaway container rather
  than assuming. If someone reports slow imports, that probe result is the first
  thing to check.

## Working on this

Nothing can be run from macOS. Before shipping a change:

```bash
python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"   # compose parses
docker compose config                                                  # interpolation resolves
```

For PowerShell, run the smoke test on the Windows box before shipping:

```powershell
.\scripts\Test-Common.ps1
```

It parses every script and exercises the pure helpers, and exits 1 on failure.
It covers the two classes that have actually broken here and that reading cannot
catch: parse errors, and parameter binding. Everything needing Docker or HTTP is
still verified by running the real scripts against a live stack.
`Invoke-ScriptAnalyzer` remains worth a pass.

From a machine with no PowerShell, brace and paren balance is the floor, plus one
check worth running every time because it is a parse error rather than a runtime
one:

```bash
grep -nE '"[^"]*\$[A-Za-z_][A-Za-z0-9_]*:' scripts/*.ps1
```

`"$Name:"` inside a double-quoted string is read as a drive-qualified variable,
the way `$env:PATH` is, and fails to parse. Write `"${Name}:"` or escape the
colon with a backtick. This is not theoretical: it shipped once, in
`_Common.ps1`, and because every script dot-sources that file it broke all of
them at once.

Style: comments explain why, not what. The scripts are meant to be read as much
as run — this started as a portfolio lab, and the Windows-specific gotchas are the
actual content. Keep prose in English.

## Where to look first

`docs/services.md` has the port map, the flow diagram, the setup order and a
symptom-to-cause table. That table is the accumulated debugging, and it is the
most useful thing in the repo.

## Known issues in the current tree

- **A case-insensitive `d:` -> `C:` replace once corrupted this tree**, turning
  `PUID` into `PUIC` and the `sabnzbd` image into one that does not exist. It is
  repaired. Worth remembering only because YAML validation caught none of it —
  the file parsed fine, it just named a missing image.

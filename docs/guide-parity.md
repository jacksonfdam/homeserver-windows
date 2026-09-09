# The r/pirataria guides, step by step against this stack

Both guides this repository draws its settings from are written for **native
Windows installs** — one `.exe` per app, folders anywhere on `C:`, everything
talking to `localhost`. This stack is the same seven applications in containers
behind one bridge network and one `/data` mount, driven by scripts.

Most of the advice survives that move unchanged. Some of it cannot, and a few
steps are refused here on purpose. This page walks the guides in their own
order and marks every step as one of:

| Mark | Meaning |
| --- | --- |
| **script** | a script already does it; re-running is safe |
| **by hand** | do it in the app's UI, and why it was left that way |
| **differs** | done here, but not the way the guide says, and why |
| **not possible** | the guide's mechanism does not exist in this arrangement |
| **refused** | could be done, deliberately is not |

For the same material organised by content type rather than by guide, see
[tuning.md](tuning.md). For ports and first-run wizards, see
[services.md](services.md).

Sources:

- *Guia do Streaming Doméstico Automatizado (Sonarr, Radarr e Plex)* — r/pirataria
- *[GUIA] Filmes dublados automáticos no Radarr e Sonarr* — r/pirataria
- [TRaSH Guides](https://trash-guides.info/), which both draw their custom formats from

---

## Guide 1 — the automated streaming server

### Folders: `qBitTorrent`, `Filmes`, `Séries` — **differs**

The guide creates three sibling folders and points each app at one of them.
Do not reproduce that here.

Everything mounts a single `${DATA_ROOT}:/data`, with downloads and library as
siblings inside it:

```
DATA_ROOT/
  torrents/            what qBittorrent writes
    incomplete/
  media/               what Sonarr and Radarr import into
    movies/  tv/  anime/  music/  manga/  comics/  books/
  recycle/             where imports send the junk in a torrent
```

The reason is invisible from a native install: three separate bind mounts are
three separate filesystems *inside the container*, so every import is a
cross-device copy — slow, and double the disk while it runs. One mount makes an
import a rename.

`Setup-HomeServer.ps1` creates this tree. Paths in `.env` use forward slashes
(`D:/media`, never `D:\media`) because Compose mishandles backslashes in volume
definitions.

### qBittorrent — pre-allocate disk space — **script**

Seeded before the container's first start: `Downloads\PreAllocation=true`.

The guide's reasoning is that nobody is watching, so a download must not start
and then run out of space. That argument is stronger here, not weaker:
hardlinks usually fail on an NTFS bind mount, so an import is a full copy and
peak usage is roughly double the finished file.

This only applies to a **fresh** install. `Setup-HomeServer.ps1` writes
`qBittorrent.conf` when the file is absent and never touches it afterwards.

### qBittorrent — Automatic Torrent Management — **by hand**

The guide is right that this matters — it is the mechanism that makes a
category decide the save path — and the seed config does **not** set it. Turn
it on once, in Options > Downloads > *Default Torrent Management Mode:
Automatic*.

The wiring script creates one category per app (`tv-sonarr`, `radarr`,
`lidarr`) so the queues never mix. With Automatic mode off, those categories
label the download but do not place it.

### qBittorrent — default save path — **script**

`/data/torrents`, with incomplete downloads in `/data/torrents/incomplete`.
Container paths, not Windows paths: `D:/media/torrents` on the host *is*
`/data/torrents` in every container that needs it.

### qBittorrent — Web UI username and password — **differs**

The guide sets credentials so the *arr apps can log in. Here the automation
does not log in at all: `WebUI\AuthSubnetWhitelist=172.16.0.0/12` exempts the
Docker bridge range, so the containers and the wiring script reach the API
without a password. A LAN device still gets the login prompt.

qBittorrent 4.6.1+ generates a random temporary password on first start and
writes it to the log — `admin`/`adminadmin` has not been the default for years:

```powershell
docker logs qbittorrent | Select-String "temporary password"
```

Set a real password in Options > Web UI before exposing port 8080 anywhere.

### Radarr and Prowlarr — switch the UI to Portuguese (Brazil) — **by hand**

Cosmetic, per app, and never automated. Settings > UI > Language.

Nothing in the scripts reads the UI language, so switching it is free.

### Radarr — movie naming and folder format — **script, differs**

`Wire-Services.ps1 -ApplyNaming` sets it. The format is the guide's, extended:

```
{Movie CleanTitle} ({Release Year}) {imdb-{ImdbId}} [{Quality Full}]{[MediaInfo VideoDynamicRangeType]}[{Mediainfo AudioCodec} {Mediainfo AudioChannels}][{MediaInfo VideoCodec}]{-Release Group}
```

The guide's core insight is the IMDb id in the name, so the player matches on
the id instead of guessing from the title. The extra tokens carry quality,
dynamic range and codecs, which is what lets you tell two files apart without
opening them.

Rename on import, replace illegal characters, and colon replacement *delete*
are all set. One trap if this is ever edited: `colonReplacementFormat` is an
**integer** in Sonarr (`0` = delete) and a **string** in Radarr (`"delete"`).

`-ApplyNaming` is off by default because it enables renaming on import: on a
fresh install that is the point, on an existing library it renames everything
on the next refresh.

### Radarr — "Ignore free space check" — **refused**

The guide turns this on. Do not.

It disables the check that stops an import from filling the disk. On a mount
where hardlinks fail every import is a full copy, which is exactly the
situation where that check earns its place. `skipFreeSpaceCheckWhenImporting`
is deliberately left at its default.

### Radarr and Sonarr — "Use hardlinks instead of copy" — **by hand, will probably not work**

Leave it enabled. It falls back to copying when hardlinks are unavailable, so
enabling it costs nothing and pays off if `DATA_ROOT` ever moves into the WSL2
filesystem.

`Setup-HomeServer.ps1` probes this at runtime with a throwaway container rather
than assuming, and tells you the answer. If someone reports slow imports and a
filling disk, that probe result is the first thing to check.

### Radarr and Sonarr — propers and repacks: do not prefer — **script**

Set by `-ApplyNaming`, for the guide's reason: a PROPER should not jump ahead
of scoring you set up deliberately.

### Radarr and Sonarr — recycle bin — **script, differs**

The guide points the recycle bin at the Windows Recycle Bin. A container cannot
see it. Both apps are pointed at `/data/recycle` instead, cleaned out after 14
days, and `Setup-HomeServer.ps1` creates the folder because it has to: both
apps validate the path for existence and write access **inside the container**
and reject the entire settings object otherwise.

It sits beside `media/` and `torrents/` so deleting into it is a move.

### Radarr and Sonarr — root folders — **script**

`/data/media/movies`, `/data/media/tv`, `/data/media/anime`,
`/data/media/music`. Anime gets its own root folder, which the guide does not
cover; mixed libraries produce bad metadata matches.

### Settings > Quality — minimum and maximum sizes — **script**

Run `Wire-Services.ps1 -ApplyQualityFloors`.

The guide describes tuning these by hand. The reason it matters is that every
quality definition ships with a minimum size of **zero**, which lets a 600 MB
file pass as 2160p. The script sets a floor per definition in MB per minute of
runtime — 3 for 720p, 5–8 for 1080p, 25 for Remux-1080p, 10–15 for 2160p, 50
for Remux-2160p. Raise them by hand if you want a stricter library.

### Custom formats: BR-DISK and 3D — **script, differs**

Both are created by `-ApplyQualityFloors`, scored `-10000`, and — the part that
matters — **scored into every quality profile**, because a custom format that
exists at score 0 rejects nothing. The default `minFormatScore` is 0, so
anything matching lands below the floor and is refused.

What differs is provenance. The guide imports TRaSH Guides JSON by `trash_id`.
This stack writes its own release-title patterns through
`/api/v3/customformat/schema`, so Radarr compiles them at creation and a bad
pattern fails loudly instead of silently matching nothing. Importing the TRaSH
JSON by hand on top of this also works — you would then have two formats doing
the same job, so score one of them 0.

There is a third format the guide does not have: **`block-executables`**,
rejecting releases advertising `.exe`, `.scr`, `.bat` and friends. In Sonarr it
is a release profile; Radarr has no release-profile endpoint, so there it is a
custom format. qBittorrent also refuses to write those files at all. It is the
single most useful setting in the stack and it comes from the article this port
is based on, not from these guides.

### Custom format: Open Matte, and other preferences — **by hand**

The guide's example of a *preferred* format rather than a rejected one. Nothing
here creates it, because which release shapes you prefer is taste. Import the
TRaSH JSON in Settings > Custom Formats > **+** > Import, then give it a
positive score in each quality profile.

Worth internalising before tuning anything, because it explains why a score
sometimes loses. Release selection order:

1. quality
2. custom format score
3. protocol
4. indexer priority
5. indexer flags
6. seeds and peers
7. size

Quality wins first. A custom format cannot rescue a release the quality profile
already rejected.

### Settings > Profiles — quality profile and upgrades — **by hand**

The guide's recommendation stands: pick *Any*, tick every quality, allow
upgrades, and set the cutoff to the best quality you actually want to keep.
Radarr then takes a cinema recording today and replaces it with the Bluray when
one appears.

Left manual because the cutoff is the one setting that is purely about your
disk and your taste, and because `-ApplyQualityFloors` already writes scores
into these profiles — the script touches the format scores, not the qualities.

### Settings > Download Clients — **script**

qBittorrent is registered in Sonarr, Radarr and Lidarr, one category each, with
completed and failed downloads removed from the client's history after import.
The host is the container name `qbittorrent`, not `localhost`.

### Settings > Lists — Letterboxd — **not done**

The guide's trick still works: take a Letterboxd list URL and swap
`letterboxd.com` for `letterboxd-list-radarr.onrender.com` to get an RSS feed
Radarr can poll every 12 hours. Add it under Settings > Lists > Advanced Lists
> Custom Lists, root folder `/data/media/movies`.

Nothing here automates it, and one option deserves a warning before you copy
the guide's setting:

> **Clean Library Level = "Remove Movie and Delete Files"** means removing a
> film from the Letterboxd list **permanently deletes the file from disk**, with
> no confirmation, on the next poll. Useful on a small disk, alarming on a large
> one. Start with *Disabled* or *Logging Only*.

### Settings > General — automatic updates — **refused**

Do not enable in-app updates in a container. The application directory belongs
to the image; an in-app update either fails or produces a container that no
longer matches its tag.

Updates come from the image instead: `docker compose pull; docker compose up -d`,
or enable the `utils` profile and let Watchtower do it at 04:00.

### Sonarr — episode naming — **script**

`-ApplyNaming` sets the standard, daily and anime formats. The anime one is the
case that actually breaks without it — it carries absolute episode numbering
and audio languages, which is how anime releases are numbered:

```
The Series Title's! (2010) - S01E01 - 001 - Episode Title 1 [WEBDL-1080p v2][10bit][AVC][DTS 5.1][JA]-RlsGrp
```

Series folders carry the IMDb id, same as movies.

### Sonarr — Language Profiles — **not possible**

The guide is Sonarr v3. **Language profiles were removed in Sonarr v4**, which
is what this stack runs. There is no such page.

Language preference is now expressed as custom formats scored inside a quality
profile — the same mechanism guide 2 uses for Radarr, below.

### Sonarr — series type Anime — **by hand**

Per series, on the series page. It switches episode numbering from
season/episode to absolute, and without it anime releases fail to match. There
is no global setting to do it once.

### Prowlarr — register Radarr and Sonarr — **script**

The guide's copy-the-API-key-between-tabs dance is not needed.
`Wire-Services.ps1` reads each app's key straight out of `config.xml` inside the
running container and registers Sonarr, Radarr and Lidarr in Prowlarr with
`fullSync`.

Registration is one-way on purpose: **Prowlarr is the only place indexers
live.** An indexer added directly inside an *arr app is not tracked, not removed
when it dies, and is the usual source of bad releases.

### Prowlarr — add indexers, then *Sync App Indexers* — **refused**

No indexers are preconfigured, and none will be. Which ones you enable, and
whether you are entitled to what you pull from them, is your call.

The guide's own method is a reasonable one: filter by *Public* and the
categories you care about, add what looks useful, then *Sync App Indexers*.
Fewer good indexers beat a long list of dead ones.

FlareSolverr is also absent from this stack, on purpose — its job is defeating
bot protection.

### Bazarr — point it at Sonarr and Radarr — **script**

Done, over container names. Three traps in that endpoint were found by running
it rather than reading about it, and they are why this is worth having scripted:

- booleans must be lower case — `True` is refused with 406 **and the whole form
  is discarded with it**, which is how this wiring silently did nothing for a
  long time while reporting success
- a `204` proves only that the request was accepted; field names missing the
  `settings-` prefix are also accepted, write the wrong type into the config,
  and take Bazarr down on its next read
- changing `use_sonarr` restarts Bazarr, so the connection drops before the
  reply arrives even though the write landed

### Bazarr — language profile — **script, with a switch**

`Wire-Services.ps1 -SubtitleLanguage pb` creates the profile, sets it as the
default for series and movies, and turns on automatic synchronisation and
subtitle upgrades. Use `en` for English.

This is not a nicety: **Bazarr silently ignores any item that has no language
profile**, so without it the integration fetches nothing while looking
correctly configured.

Two pieces stay yours:

- **applying the profile in bulk** to what is already in the library. A default
  applies to items added *after* it is set, never retrospectively.
- a provider account, below.

### Bazarr — providers (OpenSubtitles) — **by hand**

Nothing can be downloaded without an account, and credentials are yours to
enter.

One thing the guide does not warn about: OpenSubtitles.com wants your
**username**, not your email address. Using the email earns a 12-hour lockout
that persists after you fix it.

The guide is right that `.org` is dead — use `.com`.

### Plex — **by hand, and optional here**

Plex is behind the `plex` Compose profile and is not started by default;
Jellyfin is, because it needs no account and no claim token.

To use Plex: get a token from [plex.tv/claim](https://plex.tv/claim) (4 minute
expiry), put it in `.env` as `PLEX_CLAIM`, then
`docker compose --profile plex up -d plex`.

Every setting in the guide's Plex section — the scanner and agent per library,
*Scan my library automatically*, *Empty trash automatically after every scan*,
disabling periodic scans, hiding collections — is worth applying as written.
None of it is automated: Plex's settings live behind an account-bound API and
the first-run flow is interactive.

Two container-specific differences:

- **No GDM auto-discovery.** `network_mode: host` does not exist on Docker
  Desktop for Windows, so `ADVERTISE_IP` does the job and LAN clients find the
  server through your Plex account instead of broadcast.
- **No hardware transcoding**, unless you have an NVIDIA GPU with WSL2 GPU
  support — the NVENC block in the compose file is commented out for that
  reason. There is no `/dev/dri`, so Intel QuickSync is impossible in a
  container here. If you need it, run Plex natively on Windows against the same
  folders.

Libraries point at `/data/media/movies`, `/data/media/tv` and
`/data/media/anime` — container paths, not `D:\...`.

---

## Guide 2 — automatic Brazilian Portuguese dubbing

This guide builds the feature out of four pieces. **Piece 1 is an indexer**, so
it lands on the one thing this stack refuses to configure, and without it the
other three have nothing to score. The whole chain is therefore a documented
manual exception.

### 1. The Torrentio Cardigann definition — **refused**

The guide drops a custom `torrentio.yml` into Prowlarr's
`Definitions/Custom/` and raises its indexer priority to 1, because that is
what surfaces releases from the Brazilian sites.

This stack configures no indexers. If you add it yourself, the container path
differs from both paths the guide gives:

```
${CONFIG_ROOT}/prowlarr/Definitions/Custom/torrentio.yml
```

on the host — Prowlarr sees it as `/config/Definitions/Custom/`. Restart with
`docker compose restart prowlarr`, not `systemctl`.

Two things the guide glosses over: the definition asks for a **debrid provider
API key**, which is a paid service, and its rate limit is why the file sets
`requestDelay: 20`.

### 2–4. The three custom formats — **by hand**

Ordinary custom formats. They would automate cleanly and are not automated
only because piece 1 is missing, which would leave them scoring nothing.

Import all three in Settings > Custom Formats > **+** > Import, adjusting each
language field to *Portuguese (Brazil)*:

| Format | Implementation | Score |
| --- | --- | --- |
| `Language: Not Original or Portuguese` | two negated `LanguageSpecification`s, both required | `-10000` |
| `Language: Prefer Portuguese` | `LanguageSpecification` | `+10` |
| `dublado` | `ReleaseTitleSpecification` matching `PTBR`, `PT-BR`, `Dublado`, `Dual Audio` | `+10` |

Then, in the quality profile:

- **Language: Any** — the language preference now lives in the formats, so
  constraining it here as well rejects the dual-audio releases you want
- **Upgrade Until Custom Format Score: 20** — without raising this, the two
  `+10` formats can never trigger an upgrade and the whole arrangement is inert

The `-10000` format is what makes it a filter rather than a preference: it sits
below the profile's `minFormatScore` of 0, so a release that is neither
original-language nor Portuguese is refused outright. If you would rather
*prefer* dubbing than *require* it, drop that format and keep the two positives
— Radarr then takes the original audio when no dub exists.

### Sonarr — same treatment — **by hand, and note the trap**

The guide's title says Radarr *and* Sonarr but it only shows Radarr. The two
positive formats port across unchanged. Do not port the `-10000` one to a
series library without thinking: dubbing coverage for TV is far thinner than
for film, and a hard reject means whole seasons silently never download.

---

## What is left over

Three things from the guides have no equivalent here at all, and one thing here
has no equivalent in the guides.

**No equivalent here:**

- **Sonarr language profiles** — removed in v4, replaced by custom formats
- **In-app automatic updates** — the image is the update mechanism
- **The Windows Recycle Bin** — a container cannot reach it

**No equivalent in the guides**, because they predate it or are Windows-native:

- one `/data` mount instead of three folders, which is the difference between
  an import that renames and an import that copies
- the hardlink probe, because on NTFS the answer is usually *no* and it is
  better to know at setup time
- the executable payload filter, in three places at once — qBittorrent's
  excluded filenames, a Sonarr release profile and a Radarr custom format
- Lidarr, Komga, Kavita, Jellyseerr and Homepage, which the guides do not cover

# The r/pirataria guides against this stack

Both guides this repository takes its settings from are written for **native
Windows installs** — one `.exe` per app, folders anywhere on `C:`, everything on
`localhost`. Here it is the same applications in containers behind one bridge
network and one `/data` mount.

Most of the advice survives that unchanged. This page is only the parts that do
not, in the guides' own order, so you can read them with this open beside you.

| Mark | Meaning |
| --- | --- |
| **script** | already done for you; re-running is safe |
| **by hand** | do it in the app, as written |
| **differs** | done here, but not the guide's way |
| **gone** | the guide's mechanism no longer exists |
| **refused** | could be done, deliberately is not |

Why each setting is worth having is in [tuning.md](tuning.md); this page assumes
it. Sources: *Guia do Streaming Doméstico Automatizado*, *[GUIA] Filmes dublados
automáticos no Radarr e Sonarr*, and the [TRaSH Guides](https://trash-guides.info/)
they draw their custom formats from.

---

## Guide 1 — the automated streaming server

| Guide step | | Here |
| --- | --- | --- |
| three folders: `qBitTorrent`, `Filmes`, `Séries` | **differs** | one `/data` mount, `torrents/` and `media/` siblings — three mounts are three filesystems in a container, so every import becomes a copy ([windows.md](windows.md#one-root-path-and-why-it-matters)) |
| qBittorrent: pre-allocate disk space | **script** | seeded before first start |
| qBittorrent: default save path | **script** | `/data/torrents`, incomplete in `/data/torrents/incomplete` |
| qBittorrent: Web UI user and password | **differs** | automation never logs in — `AuthSubnetWhitelist` exempts the Docker bridge range. Set a password anyway before exposing 8080 |
| UI language → Portuguese (Brazil) | **by hand** | per app, cosmetic, nothing reads it |
| Radarr/Sonarr: naming and folder format | **script** | `-ApplyNaming`. The guide's IMDb-id format plus quality and codec tokens |
| Radarr: "ignore free space check" | **refused** | it disables the check that stops an import filling the disk, and here every import is a full copy |
| Radarr/Sonarr: use hardlinks instead of copy | **by hand** | leave it on; it falls back to copying. Setup probes whether it actually works |
| Radarr/Sonarr: propers and repacks → do not prefer | **script** | `-ApplyNaming` |
| Radarr/Sonarr: recycle bin | **script, differs** | `/data/recycle`, kept 14 days. A container cannot reach the Windows Recycle Bin |
| Radarr/Sonarr: root folders | **script** | plus `/data/media/anime`, which the guide does not have |
| Settings > Quality: min and max sizes | **script** | `-ApplyQualityFloors`. They all ship at zero, which lets a 600 MB file pass as 2160p |
| custom formats BR-DISK and 3D | **script, differs** | own patterns through `/customformat/schema` instead of TRaSH `trash_id` imports, so a bad regex fails at creation. Also scored into every quality profile, without which a format rejects nothing |
| custom format Open Matte, and other preferences | **by hand** | which shapes you *prefer* is taste. Import the TRaSH JSON and score it positive |
| Settings > Profiles: quality, upgrades, cutoff | **by hand** | the guide's advice stands. It is the one setting that is purely your disk and your taste |
| Settings > Download Clients | **script** | one category per app, host `qbittorrent`, not `localhost` |
| Settings > General: automatic updates | **refused** | in a container an in-app update either fails or leaves you off-tag. Update the image instead ([day-2.md](day-2.md)) |
| Sonarr: series type Anime | **by hand** | per series; there is no global setting |
| Prowlarr: paste each API key in | **script** | keys are read out of `config.xml` inside the container |
| Prowlarr: add indexers, *Sync App Indexers* | **refused** | none are preconfigured and none will be. The guide's method — filter Public plus your categories — is a good one |
| Bazarr: point at Sonarr and Radarr | **script** | |
| Bazarr: language profile | **script** | `-SubtitleLanguage pb`. Still yours: applying it in bulk to what is already in the library |
| Bazarr: OpenSubtitles account | **by hand** | it wants your **username**, not your email — the email earns a 12-hour lockout |
| Plex: everything in that section | **by hand** | apply as written. Plex is behind the `plex` profile and off by default; Jellyfin needs no account or claim token. No GDM discovery and no QuickSync here ([windows.md](windows.md)) |

Three of those rows are the whole reason this page exists.

### qBittorrent: Automatic Torrent Management — do turn it on

The guide is emphatic and correct, and the seed config does **not** set it:
Options > Downloads > *Default Torrent Management Mode: Automatic*.

The wiring script gives each app its own category. With Automatic mode off those
categories label a download but do not place it.

### Sonarr: Language Profiles — **gone**

The guide is Sonarr v3. Language profiles were removed in v4, which is what runs
here; there is no such page. Language preference is now custom formats scored
inside a quality profile — exactly what guide 2 does for Radarr.

### Settings > Lists: Letterboxd — **not automated**

The trick still works: swap `letterboxd.com` for
`letterboxd-list-radarr.onrender.com` in a list URL to get a feed Radarr polls
every 12 hours. Add it under Lists > Advanced Lists > Custom Lists, root folder
`/data/media/movies`.

> The guide also sets **Clean Library Level: Remove Movie and Delete Files**.
> That deletes the file from disk, without confirmation, on the next poll after
> something leaves the list. Sensible on a small disk, alarming on a large one.
> Start with *Disabled*.

---

## Guide 2 — automatic Brazilian Portuguese dubbing

Four pieces. All four are available here now, but only the last three are
applied for you — the first is an indexer, and adding indexers stays yours.

**1. The Torrentio Cardigann definition — shipped, not enabled.** The repository
carries `prowlarr/definitions/torrentio.yml` and `Setup-HomeServer.ps1` installs
it into `CONFIG_ROOT/prowlarr/Definitions/Custom/`, then restarts Prowlarr so it
is picked up. That is neither of the two paths the guide gives, and the restart
is `docker compose restart prowlarr`, not `systemctl`.

Having the definition only puts *Torrentio* in the Add Indexer list. **You still
add and configure it**, including the options string — the guide's Brazilian one
is:

```
providers=comando,comoeubaixo,ondebaixa,bludv|sort=qualitysize
```

The vendored file is a newer revision than the guide's: it already lists
`comando` and `bludv` among its defaults, and its debrid provider defaults to
`none` rather than requiring a paid Real-Debrid key. Whether Torrentio returns
usable magnets with no debrid provider is the thing to check first if searches
come back empty.

**2–4. The three custom formats — by hand.** Ordinary custom formats that would
automate cleanly, left manual because they are worth nothing until you have
decided piece 1 is what you want. Import them in
Settings > Custom Formats > **+** > Import, setting every language field to
*Portuguese (Brazil)*:

| Format | Implementation | Score |
| --- | --- | --- |
| `Language: Not Original or Portuguese` | two negated `LanguageSpecification`s, both required | `-10000` |
| `Language: Prefer Portuguese` | `LanguageSpecification` | `+10` |
| `dublado` | `ReleaseTitleSpecification` on `PTBR`, `PT-BR`, `Dublado`, `Dual Audio` | `+10` |

Then in the quality profile, **Language: Any** — the preference lives in the
formats now, so constraining it here as well rejects the dual-audio releases you
want — and **Upgrade Until Custom Format Score: 20**, without which the two
`+10` formats can never trigger an upgrade and the arrangement is inert.

The `-10000` format is what makes this a filter rather than a preference: it
sits below the profile's `minFormatScore` of 0, so anything neither
original-language nor Portuguese is refused outright. Drop it and keep the two
positives if you would rather Radarr fell back to the original audio when no dub
exists.

**Sonarr gets the same treatment**, which the guide's title promises and its
body never shows. Port the two positive formats across. Think before porting the
`-10000` one: dubbing coverage for series is far thinner than for film, and a
hard reject means whole seasons silently never arrive.

---

## Neither guide covers

One `/data` mount, the hardlink probe, and the executable payload filter in
three places at once — qBittorrent's excluded filenames, a Sonarr release
profile, a Radarr custom format. That last one is the most useful setting in the
stack and it comes from the article this port is based on, not from these
guides. Nor do they cover Lidarr, Komga, Kavita, Jellyseerr or Homepage.

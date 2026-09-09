# Tuning reference

What this stack sets for you, what it leaves to you, and what it will not set on
purpose. Scope is the four things this server exists for: **anime, movies, music
and manga.**

Settings come from two r/pirataria guides and the
[TRaSH Guides](https://trash-guides.info/) behind them, checked against what
`Wire-Services.ps1` actually does. To read them in the guides' own order, with
each step marked follow / skip / do differently, see
[guide-parity.md](guide-parity.md).

## What the switches do

`Wire-Services.ps1` runs at the end of setup and is idempotent. Without a switch
it wires services together and nothing else.

| | Sets |
| --- | --- |
| *(always)* | qBittorrent as download client in Sonarr, Radarr and Lidarr, one category each so the queues never mix; root folders under `/data/media`; the three apps registered in Prowlarr with `fullSync`; Bazarr pointed at Sonarr and Radarr |
| `-ApplyQualityFloors` | a minimum size per quality definition; custom formats rejecting executable payloads, BR-DISK and 3D, scored `-10000` into every quality profile |
| `-ApplyNaming` | file and folder naming, propers *do not prefer*, and a recycle bin at `/data/recycle` kept 14 days |
| `-SubtitleLanguage pb` | a Bazarr language profile, set as the default for series and movies, plus subtitle sync and upgrades |

`-ApplyNaming` is off by default because it enables renaming on import: on a
fresh install that is the point, on an existing library it renames everything on
the next refresh.

## Why those, and not others

**Quality floors, because every definition ships at zero.** A minimum size of
zero lets a 600 MB file pass as 2160p. The floors are in MB per minute of
runtime.

**The executable filter, because it is the most useful setting in the stack.** A
"complete" torrent whose only payload is a renamed executable never reaches
disk: qBittorrent refuses to write those extensions at all, and the *arr apps
reject the release and blocklist it. Sonarr gets a release profile, Radarr a
custom format — it has no release-profile endpoint. This one is not from the
guides; it comes from the article this port is based on.

**Rejecting BR-DISK and 3D by score, not by rule.** Both are release-title
matches in the same table as the executable filter, so adding another shape to
reject is a row rather than another block of code. The idea comes from the TRaSH
Guides; the patterns are this repository's own, and Radarr compiles them at
creation, so a bad one fails loudly instead of matching nothing.

**Naming, because the player reads the filename.** Folders carry the IMDb id so
the player matches on the id rather than guessing from the title. The anime
format additionally carries absolute episode numbering and audio languages,
which is the case that actually breaks without it — rendered by a live Sonarr:

```
The Series Title's! (2010) - S01E01 - 001 - Episode Title 1 [WEBDL-1080p v2][10bit][AVC][DTS 5.1][JA]-RlsGrp
```

**A recycle bin, because torrents carry junk.** Both apps import the media and
send the rest to `/data/recycle`, a sibling of `media/` and `torrents/` so
deleting into it is a move.

**A Bazarr language profile, because Bazarr ignores items without one.**
Silently. Before this existed the integration fetched nothing while appearing
correctly configured.

### Release selection order

Worth knowing before tuning anything, because it explains why a custom format
score sometimes loses. Radarr and Sonarr pick in this order: **quality**, custom
format score, protocol, indexer priority, indexer flags, seeds and peers, size.

Quality wins first. A custom format cannot rescue a release the quality profile
already rejected, and cannot beat a higher quality unless its score is negative
enough to push the release below the profile's minimum.

## Traps, all found by running it

- **`colonReplacementFormat` is an integer in Sonarr and a string in Radarr.**
- **The recycle bin path is validated inside the container** for existence and
  write access, and the whole settings object is rejected otherwise — which is
  why `Setup-HomeServer.ps1` creates the folder.
- **Bazarr booleans must be lower case.** `True` is refused with 406 *and the
  whole form is discarded with it*, which is how this wiring did nothing at all
  for a long time while reporting success.
- **A Bazarr `204` proves only that the request was accepted.** Field names
  missing the `settings-` prefix are accepted too, write the wrong type into the
  config, and kill Bazarr on its next read. Values are read back, not trusted.
- **Changing `use_sonarr` restarts Bazarr**, so the connection drops before the
  reply arrives even though the write landed. Connection settings go last.

Provider registration is schema-driven for the same reason: `New-ProviderFromSchema`
fetches the app's own `/schema` and overrides only the fields it cares about,
instead of hardcoding a field list that the next *arr release invalidates.

## Left to you, and why

- **Which indexers to enable.** Prowlarr is the only place indexers live —
  registered with `fullSync`, so what you add there is pushed out. An indexer
  added inside an *arr app is not tracked, not removed when it dies, and is the
  usual source of bad releases. Which ones you enable is yours to decide.
- **Series type Anime**, per series in Sonarr. It switches numbering from
  season/episode to absolute, which is how anime releases are named. There is no
  global setting.
- **A subtitle provider account**, and **applying the language profile in bulk**
  to what is already in the library — a default applies to items added after it
  is set, never retrospectively.
- **Komga and Kavita libraries.** Both mount `/data/media/manga`, `/comics` and
  `/books`; their first-run wizards are interactive by design.
- **Hardlinks**: leave "use hardlinks instead of copy" on. It falls back to
  copying, so it costs nothing and pays off if `DATA_ROOT` ever moves into the
  WSL2 filesystem. `Setup-HomeServer.ps1` probes whether it actually works.
- **Disk pre-allocation** is on in the seeded config, so a download cannot start
  and then run out of space unattended. Only a fresh install gets it —
  `qBittorrent.conf` is written when absent and never touched again.

## Not done

- **Brazilian Portuguese dubbing.** Three of its four pieces are ordinary custom
  formats that would automate cleanly. The fourth is an indexer, which this stack
  does not configure, and without it the other three have nothing to score. The
  manual recipe is in [guide-parity.md](guide-parity.md).
- **Music playback.** Lidarr fills `/data/media/music` and nothing in the stack
  presents it. Jellyfin can serve the same path but is not configured to. The one
  content type where the pipeline stops.
- **Manga acquisition.** Being built — see
  [manga-anime-sync.md](manga-anime-sync.md). Only the MangaBaka mirror exists so
  far. `Import-MangaLists.ps1` is a different thing: it reports what is missing
  from Komga or Kavita and acquires nothing ([manga-lists.md](manga-lists.md)).

Those last two share a shape with the Letterboxd list the movie guide uses, and
it is worth naming: an external list is the source of truth, the *arr app or the
sync script is the executor, and **removal policy is a decision, not a default** —
deleting files when something leaves a list is useful on a small disk and
alarming on a large one.

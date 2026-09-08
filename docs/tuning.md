# Tuning reference

What this stack sets for you, what it leaves for you to set, and what it will not
set on purpose. Scope is the four things this server exists for: **anime,
movies, music and manga.**

Settings collected from two r/pirataria guides — the automated home streaming
guide and the follow-up on automatic Brazilian Portuguese dubbing — plus the
[TRaSH Guides](https://trash-guides.info/) they draw their custom formats from,
checked against what `Wire-Services.ps1` actually does today.

Three states are used throughout:

- **automated** — `Wire-Services.ps1` does it, and re-running is safe
- **manual** — you have to do it in the app, and why it was left that way
- **not done** — nobody has built it yet, with the issue tracking it

---

## Everything

### Prowlarr is the only place indexers live — automated

Sonarr, Radarr and Lidarr are registered in Prowlarr with `fullSync`, so
indexers added there are pushed out. Adding an indexer directly inside an *arr
app means it is not tracked, not removed when it dies, and is the usual source
of bad releases.

**Which indexers to enable is not automated and will not be.** The guide's own
approach is to filter by public plus the categories you care about and add what
looks useful.

### Release selection order

Worth knowing before tuning anything, because it explains why a custom format
score sometimes loses. Radarr and Sonarr pick in this order:

1. quality
2. custom format score
3. protocol
4. indexer priority
5. indexer flags
6. seeds and peers
7. size

Quality wins first. A custom format cannot rescue a release the quality profile
already rejected, and cannot beat a higher quality unless the score is negative
enough to push the release below the profile's minimum.

### Quality floors — automated with `-ApplyQualityFloors`

Every quality definition ships with a minimum size of zero, which lets a 600 MB
file pass as 2160p. `-ApplyQualityFloors` sets a floor per definition in MB per
minute of runtime.

### Executable payload filter — automated with `-ApplyQualityFloors`

A release advertising `.exe`, `.scr`, `.bat` and friends is rejected: a release
profile in Sonarr, and a custom format scored `-10000` in Radarr. qBittorrent
also refuses to write those files at all, seeded into its config before first
start.

This one is not from the guides. It comes from the original article this port is
based on, and it is the single most useful setting in the stack.

### File and folder naming — not done

The guides are emphatic about this and the stack does nothing with it. Naming
matters because the player reads the filename to catalogue the item, so getting
it wrong means fixing metadata by hand forever.

What the guides set:

- movies and series folders carry the IMDb id, so the player matches on the id
  rather than guessing from the title
- rename on import is enabled, illegal characters are replaced, and the colon
  replacement is set to delete
- the file name carries quality, dynamic range, audio codec, audio channels,
  video codec and the release group
- **the anime format additionally carries absolute episode numbering and the
  audio languages**, which is what makes an anime library sort correctly

The anime part matters most here. Tracked in the naming issue.

### Propers and repacks — not done

The guides set this to *do not prefer*, so a PROPER does not jump ahead of the
scoring you set up deliberately. One setting, not currently touched.

### Recycle bin — not done

Torrents often carry extra files. With a recycle bin path set, the *arr app
imports the media and sends the rest there, emptying it on a schedule you pick.
Without one, that junk accumulates in the library.

---

## Anime and movies

### Download client — automated

qBittorrent is registered in Sonarr, Radarr and Lidarr with one category each
(`tv-sonarr`, `radarr`, `lidarr`) so the queues never mix, and with completed
and failed downloads removed from the client's history after import.

### Root folders — automated

`/data/media/tv`, `/data/media/anime`, `/data/media/movies`, `/data/media/music`.

### Series type for anime — manual

Sonarr needs the series type set to **Anime** on each series, which switches
episode numbering from season/episode to absolute. Anime releases are named with
absolute numbering, so without this the matching fails. It is per-series and
cannot be set once globally.

### Disk pre-allocation — conflicts with what is shipped

The guide turns pre-allocation **on**, so a download cannot start and then run
out of space unattended. The qBittorrent config seeded by `Setup-HomeServer.ps1`
currently turns it **off**.

The guide's argument is stronger here than in its original Linux setting:
hardlinks usually fail on an NTFS bind mount, so every import is a full copy and
the peak space needed is roughly double. Tracked as an issue.

### Hardlinks instead of copy — leave enabled

The guides enable "use hardlinks instead of copy". Leave it on even though it
will probably not work: the setting falls back to copying, so enabling it costs
nothing and pays off if `DATA_ROOT` ever moves into the WSL2 filesystem.
`Setup-HomeServer.ps1` probes whether hardlinks actually work and tells you.

### Unwanted release formats — not done

The guides import two custom formats from TRaSH Guides, both scored `-10000`:

- **BR-DISK** — full disc rips in ISO form. Enormous, and the player often will
  not play them at all.
- **3D** — half-OU and half-SBS releases, which look broken on a normal screen.

Both are release-title matches, the same mechanism as the executable filter
already built, so they fit the existing wiring rather than needing new machinery.

### Brazilian Portuguese dubbing — not done, and needs a decision first

The second guide builds this out of four pieces:

1. a custom Cardigann indexer definition dropped into Prowlarr's
   `Definitions/Custom/`, which is what surfaces releases from Brazilian sites,
   with its indexer priority raised to the top
2. a custom format rejecting audio that is neither original nor Portuguese,
   scored `-10000`
3. a custom format preferring Portuguese audio, scored `+10`
4. a custom format matching dubbing markers in the release title, scored `+10`

and then raises the profile's *upgrade until custom format score* so the
preference actually takes effect.

Pieces 2 to 4 are ordinary custom formats and would automate cleanly. **Piece 1
is an indexer**, and this stack does not configure indexers on purpose. Without
it the other three have nothing to score, so the whole chain is a documented
exception or it is nothing.

### Subtitles — partly automated

Bazarr is pointed at Sonarr and Radarr automatically. Everything else is manual,
and Bazarr silently ignores any item without a language profile, so this is not
optional:

- a language profile, then assigned in bulk to the existing library — making it
  the default only affects items added afterwards
- **automatic subtitle synchronisation**, which times the subtitle to the actual
  file
- upgrade previously downloaded subtitles
- at least one provider account

---

## Music

### Acquisition — automated

Lidarr is wired to qBittorrent and Prowlarr with the `lidarr` category and
`/data/media/music` as its root folder.

### Playback — nothing serves it

Lidarr fills `/data/media/music` and no service in the stack presents it. Jellyfin
can serve music from the same path, but it is not configured to, and it is not
what a dedicated music server does.

This is the one gap in the four content types where the pipeline simply stops.
Tracked as an issue.

---

## Manga

### Libraries — manual

Komga and Kavita both mount `/data/media/manga`, `/data/media/comics` and
`/data/media/books`. Their first-run wizards create the admin account and point
the libraries at those paths, and neither can be automated: account creation is
interactive by design.

Two readers are included on purpose. They overlap almost entirely — run both
against the same folders for a week and keep the one you prefer.

### Acquisition — being built

See `manga-anime-sync.md`. Lists come from AniList and MyAnimeList, identity is
resolved through a local MangaBaka mirror, and acquisition goes through AIO
Webtoon Downloader. None of it is wired yet.

### List import — automated, different thing

`Import-MangaLists.ps1` matches a MangaDex or MangaFire list against what is
already in Komga or Kavita and reports what is missing. It acquires nothing.

---

## What the list-driven pipelines have in common

The movie guide drives Radarr from a Letterboxd list: the list becomes a feed,
Radarr polls it, adds what appears and can delete what is removed.

That is structurally the same thing being built for manga from AniList and
MyAnimeList, and the same thing the anime bridge will do into Sonarr. Same shape
each time: an external list is the source of truth, the *arr app or the sync
script is the executor, and removal policy is a deliberate choice rather than a
default — deleting files when something leaves a list is useful on a small disk
and alarming on a large one.

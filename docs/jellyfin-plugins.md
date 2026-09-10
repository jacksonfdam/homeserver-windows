# Making Jellyfin feel like Netflix or YouTube

Skip-intro buttons, trailers playing behind the menu, a discovery row wired to
Jellyseerr, custom tabs and a modern theme. All of it is plugins and CSS, none
of it is automated, and none of it changes how anything is acquired — this is
purely the front end.

Adapted from a r/pirataria tutorial, with the paths and URLs corrected for this
stack: everything here uses container paths and Compose service names, not
`localhost` and not a Windows drive letter.

## Read this before installing anything

**Jellyfin plugins are tied to the Jellyfin version.** Intro Skipper in
particular ships one build per Jellyfin release. A plugin installed against
10.11 stops loading when the image moves to 10.12, usually silently — the
button just stops appearing.

That matters here because `docker compose pull` and the `utils` profile's
Watchtower both update Jellyfin without asking. If you invest in this setup,
either pin the image to a version in `docker-compose.yml` or expect to
reinstall plugins after an update.

The plugins themselves live in `${CONFIG_ROOT}/jellyfin`, which is a bind mount,
so they survive recreating the container — the version mismatch is the failure
mode, not data loss.

## 1. Add the plugin repositories

Dashboard → Plugins → Repositories, or straight to
`http://<host>:8096/web/#/dashboard/plugins/repositories`.

| Repository URL | What it actually serves |
| --- | --- |
| `https://intro-skipper.org/manifest.json` | Intro Skipper |
| `https://www.iamparadox.dev/jellyfin/plugins/manifest.json` | **six plugins**: File Transformation, Media Bar, Home Screen Sections, Custom Tabs, Collection Sections, Plugin Pages |
| `https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/10.11/manifest.json` | Jellyfin Enhanced, JavaScript Injector, Jellyfin Tweaks |
| `https://raw.githubusercontent.com/CherryFloors/jellyfin-plugin-cinemamode/main/manifest.json` | Cinema Mode |
| `https://raw.githubusercontent.com/kinggeorges12/JellyBridge/refs/heads/main/manifest.json` | JellyBridge — needs Jellyseerr |
| `https://app.lizardbyte.dev/jellyfin-plugin-repo/manifest.json` | Themerr |

Three things worth knowing, all checked against the manifests themselves rather
than the tutorial:

- **The `iamparadox.dev` URL is one repository, not two.** Tutorials list it
  twice, once for File Transformation and once for Media Bar. Add it once and
  all six plugins above appear.
- **Those six are not served by Jellyfin Enhanced's repository.** The
  `n00bcodr` one carries only Jellyfin Enhanced, JavaScript Injector and
  Jellyfin Tweaks. If you are hunting for Custom Tabs or Collection Sections in
  there, that is why you cannot find them.
- **`intro-skipper.org/manifest.json` returns HTML in a browser, and that is
  correct.** It serves a manifest chosen by the Jellyfin version in the request,
  so with no version — a browser — there is nothing to serve. Do not conclude
  the URL is dead and go looking for another one.

The `n00bcodr` URL has `10.11` in its path, so it is pinned to that Jellyfin
release. The stack runs `lscr.io/linuxserver/jellyfin:latest`; if that has moved
past 10.11, swap the number for your version or the repository shows nothing.

## 2. Install the plugins

Dashboard → Plugins → Catalog. If nothing new shows up, restart Jellyfin first —
repositories are read at startup.

| Plugin | What it does |
| --- | --- |
| **Intro Skipper** | the skip-intro and skip-credits buttons |
| **File Transformation** | required by Intro Skipper for those buttons to reach the web UI |
| **Jellyfin Enhanced** | a bundle of player and UI improvements |
| **Home Screen Sections** | extra rows on the home screen |
| **Collection Sections** | collections as home-screen rows |
| **Custom Tabs** | your own tabs in the top navigation |
| **Media Bar** | the large rotating hero banner |
| **Plugin Pages** | gives the above their settings pages |
| **JellyBridge** | a discovery library backed by Jellyseerr |
| **Cinema Mode** | trailers and background video |
| **Themerr** | theme songs per title |

Two plugins that tutorials list are in none of these repositories: **Chapter
Creator** and **EDL Creator**. Both relate to editing chapter data for Intro
Skipper. If they do not appear in your catalogue, they are not missing because
you skipped a repository — look for them on their own projects.

Then restart: Dashboard → Restart, or from the host

```powershell
docker compose restart jellyfin
```

Intro Skipper and Cinema Mode start working on their own after that. Intro
Skipper has to analyse each library before it knows where the intros are, so the
buttons appear gradually, not immediately.

## 3. Jellyfin Enhanced

Its settings page has a Playback section. Worth turning on:

- Auto-resume on tab switch
- Auto Picture-in-Picture on tab switch
- Long press for 2× speed
- Custom pause screen

Its Jeer section takes a Jellyseerr URL and API key, if you run Jellyseerr. Use
the service name, **not** the host address:

```
http://jellyseerr:5055
```

The plugin runs inside the Jellyfin container, so `localhost` there means
Jellyfin itself. This is the same mistake that breaks Homepage widgets — see
[services.md](services.md).

## 4. JellyBridge

Needs Jellyseerr up. It creates a library of recommendations; favouriting
something in it raises a Jellyseerr request.

`Setup-HomeServer.ps1` creates `discover` alongside the other library folders,
so the path already exists:

```
DATA_ROOT/media/discover     ->     /data/media/discover
```

Add it as a library — Dashboard → Libraries → Add Media Library, pointing at
`/data/media/discover`. In the library settings:

- preferred download language: whatever you want metadata in
- **off:** media segment providers, video previews (trailers), chapter images

Those three are off because nothing in this library is a real file — scanning it
for chapters and previews is work with nothing to find.

Then open `http://<host>:8096/web/#/configurationpage?name=JellyBridge`:

| Field | Value |
| --- | --- |
| Jellyseerr URL | `http://jellyseerr:5055` |
| API Key | from Jellyseerr → Settings → General |
| Library Directory | `/data/media/discover` |

Test the connection. On:

```
Error: The library directory is not accessible.
```

the plugin cannot write into that path from inside the container. Check that the
path is the **container** path above and not a Windows one, and that
`/data/media/discover` exists — it is created by Setup, but only on a run after
this feature landed. On Docker Desktop, NTFS bind mounts largely ignore
`PUID`/`PGID`/`UMASK`, so a genuine permission failure here is more likely a
wrong path than a wrong owner.

Once it says Success:

- **Import Discover Content** → set Watch Region, then hit ↻
- **Synced from Jellyseerr** → ↻, then pick the providers and categories you want
- **Discover Pages: 1.** Higher numbers create a great many phantom items
- **Content Retention Time: 7** days
- Save

## 5. The theme

Per user, not per server: Settings → Display → Custom CSS.

```css
@import url("https://cdn.jsdelivr.net/gh/lscambo13/ElegantFin@main/Theme/ElegantFin-jellyfin-theme-build-latest-minified.css");
```

That is [ElegantFin](https://github.com/lscambo13/ElegantFin). It is fetched
from a CDN by each client on every load, so it needs internet access from the
browser, not from the server, and pulls whatever is current on `main` — the
theme can change under you without anything here changing.

Each Jellyfin user sets this separately, and it does not touch native clients
(Android TV, Roku, the desktop apps). This is a web-interface change only, which
is worth knowing before judging the result on a TV.

# Running it after setup

One prompt drives all of it:

```powershell
.\scripts\Start-HomeServerConsole.ps1
```

`status` reports what is configured, what is not, and what to run next. `up`,
`down`, `restart`, `logs`, `open`, `wire`, `floors`, `naming`, `dashboard`,
`mirror` and `clean` do the rest, and `help` lists them.

Every command prints the equivalent command line before it runs. That makes the
console a way to learn the scripts rather than a way to avoid them — and if it
ever misbehaves, you copy what it printed and run that instead.

Two commands refuse rather than surprise you. `naming` counts what the library
already holds and makes you type the word out, because it renames every file on
the next refresh and turning the setting back off does not undo it. `wire` will
not run against a service that is not answering yet, since registering a
provider in an app that has not finished starting is how half-configured stacks
happen.

For a shortcut or a script, one command and out:

```powershell
.\scripts\Start-HomeServerConsole.ps1 -Command status
```

## By hand

Which is what the console is calling anyway:

```powershell
# status / logs
docker compose ps
docker compose logs -f sonarr

# stop, keeping data
docker compose down

# update everything
docker compose pull; docker compose up -d

# clean dead downloads (dry run, then for real)
.\scripts\Clear-StalledQueue.ps1
.\scripts\Clear-StalledQueue.ps1 -Apply

# what is configured, what is not, and what to run next
.\scripts\Get-HomeServerStatus.ps1
```

Updates come from the image, never from inside an app. In-app automatic updates
either fail or leave you with a container that no longer matches its tag —
leave them off. Enable the `utils` profile if you would rather Watchtower pulled
new images at 04:00 daily.

## Scheduled tasks

The two daily jobs — clearing dead downloads and refreshing the MangaBaka mirror
— are not scheduled unless you ask:

```powershell
.\scripts\Setup-HomeServer.ps1 -RegisterTasks
```

Both run as you and only while you are logged on. Task Scheduler can change
that, but it needs a stored password, so the script does not do it for you.

## Backup

The only thing worth backing up is `CONFIG_ROOT`. It holds every app database,
API key and setting, and it is small. Media is replaceable; two years of
correctly organised metadata is not.

```powershell
docker compose down
Compress-Archive -Path C:\homeserver\config\* -DestinationPath "C:\backups\homeserver-$(Get-Date -f yyyy-MM-dd).zip"
docker compose up -d
```

# Disk Buddy

A small Windows tool that keeps an eye on your system drive and tells you, with a normal Windows notification, when it is time to do something about it. One PowerShell script, no services, no admin rights for day-to-day use.

It is built for people who fill a drive without noticing: developers (Docker, pnpm, Python packages, Playwright browsers), gamers (shader caches, leftover game data), and anyone with an iPhone backup quietly sitting in AppData.

## What it does

- **Watches** free space every 15 minutes and notifies you when the drive is getting full, almost full, or just lost a lot of space in a short time (a big build, an image pull, a download). Notifications wait until you are on the desktop, so they never land on top of a game.
- **Measures the whole drive** once a day in about 40 seconds and tells you, at most once a week, when a lot of rebuildable cache has piled up - even while the drive still has plenty of room.
- **Cleans only what comes back on its own**: old Docker images and build cache, pnpm/npm/pip caches, old Temp files, GPU shader caches, crash dumps, unpacked driver installers, browser caches (only while that browser is closed), old Playwright browser versions, iOS firmware files from iTunes.
- **Shows you the rest** in a report: things worth a look (phone backups, big Python packages with the exact `pip uninstall` line, old installers in Downloads, app data nothing has written to in months), the biggest folders on the drive, large archives in your folders, and your Docker usage. These are never touched automatically.
- **Compacts Docker's virtual disk** so the space Docker freed actually returns to the drive (asks for admin once).
- **Profiles** let one install serve several purposes or people: each profile picks which cache groups count, which folders the report focuses on, and can override any threshold.

It never deletes project files, named Docker volumes, anything in the Recycle Bin, or anything listed under "Worth a look".

## Install

Requires Windows 10/11. Uses Windows PowerShell 5.1, which every Windows has.

1. Put the folder somewhere permanent, for example `C:\Users\<you>\Disk Buddy`.
2. Right-click `Install-DiskBuddy.ps1` and choose **Run with PowerShell**, or from a terminal:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "Install-DiskBuddy.ps1"
   ```

   This registers a notification identity, a `diskbuddy:` link handler for the notification buttons, a `diskbuddy` command for Win+R, a Start-menu entry, and a scheduled task that runs the check every 15 minutes. It creates `config.json` from `config.example.json` if you have none, then shows a test notification.

   Windows may warn that the scripts came from the internet. They are plain text you can read before running; the command above runs them regardless of the execution policy.

`Uninstall-DiskBuddy.ps1` removes all of that again. The folder itself is left for you to delete.

## Using it

Press **Win+R** and type:

| Command | What happens |
|---|---|
| `diskbuddy` | Opens the report in your browser |
| `diskbuddy clean` | Removes the rebuildable caches, then tells you what it freed |
| `diskbuddy compact` | Shrinks Docker's disk file (admin prompt, Docker stops for a few minutes) |
| `diskbuddy volumes` | Removes leftover unnamed Docker volumes after showing you the list |
| `diskbuddy snooze` | No "getting full" warnings for a day (critical ones still come through) |
| `diskbuddy profile gaming` | Switches to the `gaming` profile |
| `diskbuddy demo` | Shows one example of each notification |

The same actions are buttons on the notifications and on the report.

## Profiles

`config.json` holds the thresholds and a `Profiles` map. The active one is named by `Profile`.

```json
"Profile": "dev",
"Profiles": {
  "default": { "Groups": "*", "Focus": [] },
  "dev": {
    "Groups": ["system", "docker", "node", "python", "ai", "browsers", "downloads"],
    "Focus": ["%USERPROFILE%\\projects\\*", "%LOCALAPPDATA%\\Docker"]
  },
  "gaming": {
    "Groups": ["system", "gpu", "games", "apps", "downloads"],
    "Focus": ["D:\\SteamLibrary\\steamapps\\common"],
    "WarnFreeGB": 80
  }
}
```

- **Groups** - which parts of the catalogue count, for the report, for Clean and for the weekly digest. `"*"` means all. Available groups: `system docker node python ai gpu browsers apple apps games downloads dotnet java`.
- **Focus** - folders (wildcards and `%ENV%` allowed, other drives too) the report breaks down, each with its five biggest subfolders. The archive search is limited to these when set. Nothing here is ever cleaned.
- Any other key in a profile overrides the top-level setting while that profile is active, so a gaming rig can warn at 80 GB and a laptop at 20.

Switch from the report (buttons next to the profile name), with `diskbuddy profile <name>`, or by editing `Profile` in `config.json`.

## Settings

All in `config.json`; defaults in brackets.

| Key | Meaning |
|---|---|
| `Drive` | Drive letter to watch [C] |
| `WarnFreeGB`, `CriticalFreeGB` | Below these, you get "getting full" / "almost full" [50, 25] |
| `DropAlertGB` | A loss this big between two checks triggers a "lost X GB" note [10] |
| `WarnRepeatHours`, `CriticalRepeatHours` | How often the same warning may repeat [24, 4] |
| `DeepScanHours` | How often the whole drive is measured [24] |
| `CacheAlertGB`, `DigestRepeatHours` | Cache digest threshold and how often it may repeat [15, 168] |
| `DockerPruneOlderThanHours` | Clean prunes Docker images and build cache older than this [168] |
| `TempOlderThanDays` | Clean removes Temp files older than this [7] |
| `OrphanMonths` | App data untouched this long is flagged as a possible leftover [6] |
| `OldInstallerDays` | Installers in Downloads older than this are flagged [30] |
| `BigPackageGB`, `BigFolderMinGB`, `ArchiveMinMB` | Size floors for the report lists [0.5, 2, 50] |
| `WaitForDesktopMinutes` | How long a notification waits for you to be on the desktop [13] |
| `Sound*` | Sounds per notification kind; file names from `C:\Windows\Media` or full paths |

## How it works

`DiskBuddy.ps1` is the whole program. The scheduled task runs it in `Check` mode; the notification buttons, the report buttons and the `diskbuddy` command run the other modes through the `diskbuddy:` link handler. The report is served on `localhost` under a random path for 15 minutes so its buttons can run things; a static copy is kept as `report.html`.

The drive scan is a small C# walker compiled at run time (`FindFirstFileEx` with large fetch) that sizes every folder in one pass, skips junctions and OneDrive placeholders, and does not expand dependency trees such as `node_modules`.

`state.json` remembers what was last measured and when you were last told; `diskbuddy.log` shows what it did.

## License

MIT.

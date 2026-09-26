# Persistent Windows 11 window repairs

SpotX installs a compiled per-user helper automatically when `run.ps1`
finishes on Windows 11/x64 with the standard Spotify installation. It combines the
Spotify taskbar registration refresh and maximized-window minimize guard.
`-window_fixes_off` skips automatic helper installation.

The helper starts at user sign-in through its owned `HKCU\...\Run` entry. Its
supervisor and repair worker run as Windows executables without background
PowerShell. If the worker exits unexpectedly, the supervisor retries with
bounded backoff (five rapid failures maximum). Spotify closing does not stop the
helper; new Spotify processes receive the guard automatically after startup.

## Install or remove separately

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-SpotifyWindowHelper.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Uninstall-SpotifyWindowHelper.ps1
```

Installation uses the .NET Framework x64 compiler included with Windows and
writes into `%LOCALAPPDATA%\SpotXMinimizeGuard`. The setup contains a compressed
source bundle and checks every embedded SHA-256 before compilation. The helper
needs no separate repository, moving branch, release asset or network download.
A foreign startup command with the same name is refused. Compilation occurs
before the existing helper is stopped; launch failure restores the previous
executable and startup value. Uninstall.bat invokes the installed helper removal
script before restoring Spotify backups.

Removal stops both helper roles and removes only its matching startup command.
Recovery state and logs remain. Completely exit Spotify to remove a guard that
is already in that process's memory. Reinstallation replaces the helper and
clears its stop signal. The old PowerShell startup watcher is migrated only after
successful installation.

## Scope and diagnostics

The taskbar refresh is restricted to the installed Spotify main HWND. The minimize
guard additionally requires the exact verified `libcef.dll` SHA-256 and live
instruction bytes documented in [the manual helper](minimize-animation.md).
Spotify/CEF files on disk are not changed by this helper. Updated/unsupported
CEF builds skip only the native minimize guard; the taskbar refresh remains available. Custom Spotify paths and non-x64 Windows are not supported
by this integration.

The worker polls every two seconds and waits until Spotify is five seconds old.
It never repeats native application after an uncertain failure in the same
process. Recovery files are checked against the live patch and wrapper. Replacing
the main HWND within an existing process requires a full Spotify restart; this
condition is logged once per new HWND rather than attempting an unsafe rebind.

`helper.log` and `state-*.json` in the install folder show results. Running
`SpotifyWindowHelper.exe --check` inspects and logs the current guard without
applying either repair. Killing the supervisor is not automatically repaired
until the next sign-in; killing the worker is covered by the supervisor.

## Validation

- Eight executable native ABI cases and four malformed recovery-state refusals.
- Compiled x64 helper and PowerShell 5.1 syntax checks.
- Live worker failure recovered by the same supervisor.
- Live uninstall stopped both roles and removed the startup registration;
  reinstall restored them.
- Consecutive full Spotify restarts received verified guards with the helper
  remaining alive.
- Initial minimize guard visually accepted by the reporter. New post-change
  ETL frame timing and a full Windows reboot/sign-in were not performed.

The earlier startup PowerShell watcher later stopped running; its log did not
establish why. The persistent compiled implementation replaces that watcher.
This is a maintained automatic session repair, not a rebuilt Spotify/CEF binary.

## Maintaining the setup and updates

The complete online `run.ps1` and saved-file setup contain the same helper code.
Installer batch files prefer the adjacent `run.ps1` in a checkout; standalone
batch files use the existing official primary/mirror URLs. No user-fork URL or
commit is embedded in the helper bootstrap.

After changing one of the four helper sources, regenerate the embedded bundle:

```powershell
powershell.exe -NoProfile -File .\scripts\Build-SpotifyWindowHelperBundle.ps1
powershell.exe -NoProfile -File .\scripts\Build-SpotifyWindowHelperBundle.ps1 -Check
powershell.exe -NoProfile -File .\tests\Test-WindowHelperBundle.ps1
```

The build normalizes source line endings to UTF-8/LF. CI checks that the setup's
embedded content exactly matches the reviewed source files, rejects unexpected
filenames and corrupted hashes, and compiles the helper. SpotX reinstallation or
an installer update replaces the installed helper automatically. A Spotify
self-update is detected by the worker but does not add support for an unverified
CEF build. Supporting another CEF binary requires reviewing its instruction
site/wrapper and adding a verified hash before regenerating the bundle.

The minimize guard requires native access to Spotify's CEF window handler; its
XPUI JavaScript/CSS cannot implement this Windows frame repair. The compiled
code is shipped as part of the setup and maintains per-session application.
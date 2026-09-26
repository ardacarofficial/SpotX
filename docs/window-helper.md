# Persistent Windows 11 window repairs

This fork installs a compiled per-user helper automatically when `run.ps1`
finishes on Windows 11/x64 with the verified Spotify CEF build. It combines the
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
writes into `%LOCALAPPDATA%\SpotXMinimizeGuard`. Online SpotX installation
fetches a commit-pinned source bundle and checks every SHA-256 before compilation.
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
builds are skipped. Custom Spotify paths and non-x64 Windows are not supported
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

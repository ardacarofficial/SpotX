# Optional minimize-animation workaround

This experimental helper addresses a hitch when minimizing **maximized**
Spotify on Windows 11. The reporter confirmed smooth minimizing after applying
the guard. No post-change frame-time trace has been collected, so this is not
a measured performance guarantee for other systems.

## Supported build

- Windows 11, x64 Spotify desktop installation in `%APPDATA%\Spotify`.
- Tested with Spotify `1.3.1.234.g59d6bf59`, CEF
  `146.0.10+g8219561+chromium-146.0.7680.179`, Windows 11 25H2 build 26200.9457.
- 64-bit Windows PowerShell 5.1 or PowerShell 7.
- Required `libcef.dll` SHA-256:
  `EB2F59B8997949875C4829A5DC0448600BABA3B9F24F8FD0B45A1DC9388AAF73`.

The file hash and live instruction bytes must match. Other builds are refused;
do not bypass these checks after a Spotify update.

## Apply and undo

Download or clone this branch with both files in `scripts` intact. Open Spotify,
then run from the repository folder in 64-bit PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Enable-SpotifyMinimizeAnimation.ps1
```

Add `-WhatIf` to check the file hash and loaded module without applying the guard.
Live instruction checks run when actually applying or undoing. The helper prints
a recovery JSON path. To undo while the same Spotify process is running:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Enable-SpotifyMinimizeAnimation.ps1 -Undo -StatePath 'PATH_PRINTED_WHEN_APPLIED'
```

**Completely exit Spotify and reopen it to remove the guard without a state
file.** Closing its window may only hide it in the tray. Apply again for each
new session if needed. A replacement main window also requires a fresh session.
There is no startup task, service or installer integration. Repeated application
to an already patched process is refused.

## What changes

The helper modifies nine bytes in the running process and allocates a 4 KB native
wrapper with x64 unwind metadata. It does not modify Spotify files on disk.
Threads are briefly suspended during the verified instruction exchange.
A short-lived remote thread registers the unwind table; no helper worker remains.

In the verified CEF window-position handler, a frame-change notification can
update DWM margins as the window becomes minimized. The guard skips that branch
only when the captured main HWND is iconic, before the cached margins change.
Other windows and non-minimized states use the original frame predicate.
This is scoped to that call site, not every DWM call in Spotify.

Pre-change traces found six 103–113 ms waits in
`DwmExtendFrameIntoClientArea`, through DWM's synchronous ALPC request path.
The matching [Chromium source](https://github.com/chromium/chromium/blob/146.0.7680.179/ui/views/win/hwnd_message_handler.cc)
provides the mechanism investigated. This does not establish that SpotX caused
the underlying behavior or that all minimize hitches have this cause.

Undo verifies the saved process and code before restoring the original bytes.
The small allocation remains inert until Spotify exits, so an in-flight call can
return safely. If an operation fails, retain the printed recovery path; fully
exiting Spotify removes any session changes.

## Local validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SpotifyFrameGuard.ps1
```

Eight native wrapper cases cover target/non-target HWND, minimized/not minimized
and the original frame predicate. Four additional cases reject malformed recovery
state before opening a target process. Tests execute synthetic data in their own
process and never modify Spotify. Live application was verified by instruction
readback, a responding Spotify process, unchanged on-disk DLL hash, and the
reporter's visual acceptance. Post-change ETL timing remains unmeasured.

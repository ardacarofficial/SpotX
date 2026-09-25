@echo off
setlocal
rem Refresh the taskbar entry of the currently running patched Spotify.
rem Does not reinstall Spotify or change its patched files.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Repair-SpotifyTaskbar.ps1"
set "repairExit=%errorlevel%"
echo.
pause
exit /b %repairExit%

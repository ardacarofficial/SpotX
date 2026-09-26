@echo off
SETLOCAL ENABLEDELAYEDEXPANSION

set "SPOTIFY_PATH=%Appdata%\Spotify"

:: Remove the installed window-repair host before restoring Spotify backups.
if exist "%LOCALAPPDATA%\SpotXMinimizeGuard\Uninstall-SpotifyWindowHelper.ps1" (
    "%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\SpotXMinimizeGuard\Uninstall-SpotifyWindowHelper.ps1"
    if errorlevel 1 (
        echo Window helper removal failed. Spotify backups were not restored.
        pause
        exit /b 1
    )
)

if exist "%SPOTIFY_PATH%\chrome_elf.dll.bak" ( 
    del /s /q "%SPOTIFY_PATH%\chrome_elf.dll" > NUL 2>&1
    move "%SPOTIFY_PATH%\chrome_elf.dll.bak" "%SPOTIFY_PATH%\chrome_elf.dll" > NUL 2>&1
)

if exist "%SPOTIFY_PATH%\Spotify.dll.bak" ( 
    del /s /q "%SPOTIFY_PATH%\Spotify.dll" > NUL 2>&1
    move "%SPOTIFY_PATH%\Spotify.dll.bak" "%SPOTIFY_PATH%\Spotify.dll" > NUL 2>&1
)

if exist "%SPOTIFY_PATH%\Spotify.bak" ( 
    del /s /q "%SPOTIFY_PATH%\Spotify.exe" > NUL 2>&1
    move "%SPOTIFY_PATH%\Spotify.bak" "%SPOTIFY_PATH%\Spotify.exe" > NUL 2>&1
)

if exist "%SPOTIFY_PATH%\Apps\xpui.bak" (
    del /s /q "%SPOTIFY_PATH%\Apps\xpui.spa" > NUL 2>&1
    move "%SPOTIFY_PATH%\Apps\xpui.bak" "%SPOTIFY_PATH%\Apps\xpui.spa" > NUL 2>&1
) 

if exist "%temp%\SpotX_Temp*" (
    for /d %%i in ("%temp%\SpotX_Temp*") do (
        rd /s/q "%%i" > NUL 2>&1
    )
)

echo Patch successfully removed
pause

@echo off

:: Line for changing spotx parameters, each parameter should be separated by a space
set param=-premium -new_theme -no_pause

set url='https://raw.githubusercontent.com/SpotX-Official/SpotX/refs/heads/main/run.ps1'
set url2='https://spotx-official.github.io/SpotX/run.ps1'
set tls=[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;

:: A complete checkout uses the setup code shipped alongside this batch file.
if exist "%~dp0..\run.ps1" (
    "%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\run.ps1" %param%
    goto setup_finished
)
%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe ^
-Command %tls% $p='%param%'; """ & { $(try { iwr -useb %url% } catch { $p+= ' -m'; iwr -useb %url2% })} $p """" | iex

:setup_finished
pause
exit /b

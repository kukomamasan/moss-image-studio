@echo off
rem MOSS Image Studio launcher.
rem Preferred path: the VBScript launcher (stays open with MOSS and closes with it).
rem Fallback: if wscript.exe is unavailable, locate Windows PowerShell 5.1 directly
rem in its standard Windows installation location, without relying on PATH.
set "SCRIPT=%~dp0MOSS-Image-Studio.ps1"
set "VBS=%~dp0MOSS-Image-Studio.vbs"
set "PS51=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS51%" set "PS51=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "WSCRIPT=%SystemRoot%\System32\wscript.exe"
if not exist "%SCRIPT%" goto missing_script
if not exist "%WSCRIPT%" set "WSCRIPT=%SystemRoot%\Sysnative\wscript.exe"
if exist "%WSCRIPT%" if exist "%VBS%" goto launch_vbs
if exist "%PS51%" goto launch_powershell
goto missing_powershell

:launch_vbs
start "" "%WSCRIPT%" "%VBS%"
rem 'exit' (not 'exit /b'): Windows' start hosts batch files with 'cmd /K'
rem (run and remain) - '/b' would leave an EMPTY console window open for
rem the whole session. 'exit' closes the host in both cases.
exit

:launch_powershell
rem /min keeps the fallback console out of the way (same reason as the
rem hidden console in the VBS launcher - no visible flash at startup).
start "MOSS" /min /wait "%PS51%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
exit

:missing_script
echo ERROR: MOSS-Image-Studio.ps1 was not found beside this launcher.
pause
exit

:missing_powershell
echo ERROR: Windows PowerShell 5.1 could not be found.
pause
exit

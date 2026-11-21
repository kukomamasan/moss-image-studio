@echo off
rem MOSS Image Studio launcher.
rem Preferred path: the VBScript launcher (stays open with MOSS and closes with it).
rem Fallback: if wscript.exe is unavailable, locate Windows PowerShell 5.1 directly
rem in its standard Windows installation location, without relying on PATH.
set "PS51=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS51%" set "PS51=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%WINDIR%\System32\wscript.exe" (
    start "" wscript.exe "%~dp0MOSS-Image-Studio.vbs"
    rem 'exit' (not 'exit /b'): Windows' start hosts batch files with 'cmd /K'
    rem (run and remain) - '/b' would leave an EMPTY console window open for
    rem the whole session (the path prompt with nothing in it). 'exit' closes
    rem the host in both cases: /K host and normal 'cmd /c' invocation.
    exit
)
if exist "%PS51%" (
    rem /min keeps the fallback console out of the way (same reason as the
    rem hidden console in the VBS launcher - no visible flash at startup).
    start "MOSS" /min /wait "%PS51%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0MOSS-Image-Studio.ps1"
) else (
    echo ERROR: Windows PowerShell 5.1 could not be found.
    pause
)
exit

@echo off
rem MOSS Image Studio launcher.
rem Preferred path: the VBScript launcher (stays open with MOSS and closes with it).
rem Fallback: if wscript.exe is unavailable, locate Windows PowerShell 5.1 directly
rem in its standard Windows installation location, without relying on PATH.
set "PS51=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS51%" set "PS51=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%WINDIR%\System32\wscript.exe" (
    start "" wscript.exe "%~dp0MOSS-Image-Studio.vbs"
    exit /b
)
if exist "%PS51%" (
    start "" /wait "%PS51%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0MOSS-Image-Studio.ps1"
) else (
    echo ERROR: Windows PowerShell 5.1 could not be found.
    pause
)
exit /b

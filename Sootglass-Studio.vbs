Option Explicit

Dim shell, fso, root, powershell, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(root, "Sootglass-Studio.ps1")
If Not fso.FileExists(scriptPath) Then
    MsgBox "Sootglass-Studio.ps1 could not be found beside this launcher.", vbCritical, "Sootglass Studio"
    WScript.Quit 1
End If

powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powershell) Then powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powershell) Then powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powershell) Then
    MsgBox "Windows PowerShell 5.1 could not be found.", vbCritical, "Sootglass Studio"
    WScript.Quit 1
End If

command = Chr(34) & powershell & Chr(34) & " -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & scriptPath & Chr(34)
' Window style 0 = the PowerShell console is hidden from the very first
' moment (previously style 1 showed it for a second or more until Sootglass's
' own Hide-MossConsoleWindow ran after the GUI window appeared - users saw
' a flashing console during the hardware scan). Sootglass never reads from or
' writes to the console - its dialogs are WinForms - so hiding is safe.
shell.Run command, 0, True

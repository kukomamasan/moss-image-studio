Option Explicit

Dim shell, fso, root, powershell, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)

powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powershell) Then powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powershell) Then powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powershell) Then
    MsgBox "Windows PowerShell 5.1 could not be found.", vbCritical, "MOSS Image Studio"
    WScript.Quit 1
End If

command = Chr(34) & powershell & Chr(34) & " -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & fso.BuildPath(root, "MOSS-Image-Studio.ps1") & Chr(34)
shell.Run command, 1, True


' Launches a PowerShell script with no visible window.
' Works around Windows Terminal intercepting -WindowStyle Hidden
' when it is set as the default terminal application.
'
' Usage: wscript //nologo run_hidden.vbs "C:\full\path\to\script.ps1"

Dim oShell, sFile
Set oShell = CreateObject("WScript.Shell")
sFile = WScript.Arguments(0)
oShell.Run "powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -WindowStyle Hidden -File """ & sFile & """", 0, False

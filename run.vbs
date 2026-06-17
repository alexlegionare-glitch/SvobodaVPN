' Запуск Свобода VPN полностью скрыто (без мелькающей консоли PowerShell)
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & folder & "\app.ps1""", 0, False

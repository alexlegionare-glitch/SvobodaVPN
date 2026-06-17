chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA 'SvobodaVPN'

# остановить старую копию и убрать старый ярлык «Свобода VPN»
Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($old in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Свобода VPN.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Свобода VPN.lnk'))) {
    if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "  Установка «Свобода VPN»" -ForegroundColor Cyan
Write-Host "  -> $target" -ForegroundColor Gray
Write-Host ""

New-Item -ItemType Directory -Force $target | Out-Null
$files = 'app.ps1','sing-box.exe','wintun.dll','profiles.json','PWDTT.exe'
foreach ($f in $files) {
    $sp = Join-Path $src $f
    if (Test-Path $sp) { Copy-Item $sp (Join-Path $target $f) -Force; Write-Host "  + $f" -ForegroundColor DarkGray }
    else { Write-Host "  ! нет файла $f" -ForegroundColor Yellow }
}

# ярлык на рабочем столе
$ws = New-Object -ComObject WScript.Shell
$lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Свобода VPN.lnk'
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $target 'app.ps1') + '"')
$lnk.WorkingDirectory = $target
$lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
$lnk.WindowStyle = 7
$lnk.Save()

# ярлык в меню Пуск
$startLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Свобода VPN.lnk'
$lnk2 = $ws.CreateShortcut($startLnk)
$lnk2.TargetPath = 'powershell.exe'
$lnk2.Arguments = $lnk.Arguments; $lnk2.WorkingDirectory = $target
$lnk2.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"; $lnk2.WindowStyle = 7; $lnk2.Save()

Write-Host ""
Write-Host "  Готово! Ярлык «Свобода VPN» на рабочем столе и в меню Пуск." -ForegroundColor Green
Write-Host "  Запусти его, подтверди UAC, вставь свою ссылку сервера." -ForegroundColor Green
Write-Host ""

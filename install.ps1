chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# нужны права админа — для автозапуска через Планировщик с повышенными правами (без UAC при входе)
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath
    exit
}

$src     = $PSScriptRoot
$target  = Join-Path $env:LOCALAPPDATA 'SvobodaVPN'
$appPath = Join-Path $target 'app.ps1'
$icoPath = Join-Path $target 'svoboda.ico'
$argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $appPath + '"'

# остановить старую копию + убрать прежний ярлык перед переустановкой
Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup'))) {
    foreach ($nm in @('Свобода VPN.lnk')) {
        $old = Join-Path $dir $nm
        if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ""
Write-Host "  Установка «Свобода VPN»" -ForegroundColor Cyan
Write-Host "  -> $target" -ForegroundColor Gray
Write-Host ""

New-Item -ItemType Directory -Force $target | Out-Null
$files = 'app.ps1','sing-box.exe','wintun.dll','profiles.json','PWDTT.exe','svoboda.ico'
foreach ($f in $files) {
    $sp = Join-Path $src $f
    if (Test-Path $sp) { Copy-Item $sp (Join-Path $target $f) -Force; Write-Host "  + $f" -ForegroundColor DarkGray }
    else { Write-Host "  ! нет файла $f" -ForegroundColor Yellow }
}

# ярлыки (рабочий стол + меню Пуск) с фирменной иконкой
$ws = New-Object -ComObject WScript.Shell
function New-Lnk($path) {
    $l = $ws.CreateShortcut($path)
    $l.TargetPath = 'powershell.exe'; $l.Arguments = $argLine; $l.WorkingDirectory = $target
    if (Test-Path $icoPath) { $l.IconLocation = $icoPath } else { $l.IconLocation = "$env:SystemRoot\System32\shell32.dll,13" }
    $l.WindowStyle = 7; $l.Save()
}
New-Lnk (Join-Path ([Environment]::GetFolderPath('Desktop'))  'Свобода VPN.lnk')
New-Lnk (Join-Path ([Environment]::GetFolderPath('Programs')) 'Свобода VPN.lnk')

# автозапуск при входе в Windows — Планировщик задач (повышенные права → без окна UAC при логине)
try {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest -LogonType Interactive
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'SvobodaVPN' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "  + автозапуск при входе в Windows (Планировщик задач)" -ForegroundColor DarkGray
} catch {
    Write-Host "  ! автозапуск не настроен: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Готово! Ярлык «Свобода VPN» на рабочем столе и в меню Пуск." -ForegroundColor Green
Write-Host "  VPN будет включаться сам при входе в Windows." -ForegroundColor Green
Write-Host "  Открой приложение и добавь свою ссылку сервера («+ Добавить сервер»)." -ForegroundColor Green
Write-Host ""
Start-Sleep -Seconds 3

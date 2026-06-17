chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

# права админа — чтобы снять автозапуск из Планировщика
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath
    exit
}

$target = Join-Path $env:LOCALAPPDATA 'SvobodaVPN'

Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
Unregister-ScheduledTask -TaskName 'SvobodaVPN' -Confirm:$false -ErrorAction SilentlyContinue
foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup'))) {
    foreach ($nm in @('Свобода VPN.lnk')) { Remove-Item (Join-Path $dir $nm) -Force }
}
Remove-Item $target -Recurse -Force

Write-Host ""
Write-Host "  «Свобода VPN» удалена (вместе с автозапуском)." -ForegroundColor Green
Write-Host ""
Start-Sleep -Seconds 2

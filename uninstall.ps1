chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
$target = Join-Path $env:LOCALAPPDATA 'SvobodaVPN'

Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Свобода VPN.lnk') -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Свобода VPN.lnk') -Force
Remove-Item $target -Recurse -Force

Write-Host ""
Write-Host "  «Свобода VPN» удалена." -ForegroundColor Green
Write-Host ""

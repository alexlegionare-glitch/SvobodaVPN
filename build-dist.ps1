chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$src = $PSScriptRoot
$dist = Join-Path $src 'dist'
$pkg = Join-Path $dist 'SvobodaVPN-Setup'
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $pkg | Out-Null

# движок + приложение + установщик (БЕЗ geoip/geosite; БЕЗ профилей; БЕЗ sb-config.json — он генерится из активного профиля и палит сервер)
$files = 'app.ps1','sing-box.exe','wintun.dll','PWDTT.exe','svoboda.ico','run.vbs','register-autostart.ps1','install.ps1','uninstall.ps1','Установить.bat','Удалить.bat'
foreach ($f in $files) { Copy-Item (Join-Path $src $f) (Join-Path $pkg $f) -Force }

# чистый profiles.json — без чужих ключей (каждый вставляет свою ссылку)
[IO.File]::WriteAllText((Join-Path $pkg 'profiles.json'), '{"active":0,"profiles":[]}', (New-Object Text.UTF8Encoding($false)))

$readme = @"
СВОБОДА VPN — установка за минуту

1. Запусти «Установить.bat»
2. На рабочем столе появится ярлык «Свобода VPN». Запусти, подтверди UAC («Да»).
3. Нажми «+ Добавить сервер» и вставь свою ссылку:
   vless:// hysteria2:// ss:// tuic:// trojan:// vmess://
4. Нажми большую круглую кнопку — VPN включится на весь ПК.

Нет своего сервера? Подними его за 1 команду — см. страницу загрузки
(раздел «Свой VPN с нуля — для новичка»).

Два режима (ссылка-переключатель внизу окна):
  • Обычный      — кнопка вкл/выкл + «Добавить сервер». Для новичка.
  • Продвинутый  — «Серверы» (все настройки: протокол, транспорт, uTLS,
                   Reality, mux) + «Подписка» с авто-обновлением списка.

Удаление: «Удалить.bat».
"@
[IO.File]::WriteAllText((Join-Path $pkg 'ЧИТАЙ.txt'), $readme, (New-Object Text.UTF8Encoding($true)))

$zip = Join-Path $dist 'SvobodaVPN-Setup.zip'
Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip -Force
$mb = [math]::Round((Get-Item $zip).Length/1MB,1)
Write-Host "ZIP готов: $zip  ($mb МБ)" -ForegroundColor Green

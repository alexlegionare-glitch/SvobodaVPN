# ===== Свобода VPN — трей-клиент (sing-box / VLESS no-SNI) =====
# авто-запрос админ-прав (TUN требует админа), запуск скрыто
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$PSCommandPath
    exit
}

# DPI-aware — чёткий шрифт на масштабе 125/150% (без мыла)
Add-Type @"
using System.Runtime.InteropServices;
public class DPI {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
}
"@
[void][DPI]::SetProcessDPIAware()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# множитель под DPI экрана (координаты в пикселях масштабируем, шрифты в пунктах сами)
try { $script:scale=[DPI]::GetDpiForSystem()/96.0 } catch { $script:scale=1.0 }; if($script:scale -lt 1){ $script:scale=1.0 }
function Px { param([int]$v) [int][math]::Round($v*$script:scale) }
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32 {
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern int SendMessage(IntPtr h, int m, int w, int l);
}
"@

$root     = Split-Path -Parent $PSCommandPath
$cfg      = Join-Path $root 'sb-config.json'
$exe      = Join-Path $root 'sing-box.exe'
$profPath = Join-Path $root 'profiles.json'

# --- стиль: светлый, индиго-акцент, slate ---
$cBg=[Drawing.Color]::FromArgb(241,245,249); $cCard=[Drawing.Color]::White
$cText=[Drawing.Color]::FromArgb(30,41,59); $cSub=[Drawing.Color]::FromArgb(100,116,139)
$cAccent=[Drawing.Color]::FromArgb(79,70,229); $cGreen=[Drawing.Color]::FromArgb(22,163,74); $cRed=[Drawing.Color]::FromArgb(220,38,38)
$cBtn2=[Drawing.Color]::FromArgb(238,242,255); $cBorder=[Drawing.Color]::FromArgb(226,232,240)

function Write-TextNoBom($path,$text){ [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false))) }
function Load-State { Get-Content $profPath -Raw -Encoding UTF8 | ConvertFrom-Json }
function Save-State { param($s) Write-TextNoBom $profPath ($s | ConvertTo-Json -Depth 6) }
$script:state = Load-State
function Active-Profile { $script:state.profiles[$script:state.active] }

function New-Profile { @{ name='';type='vless';server='';port=443;uuid='';password='';sni='';insecure=$true;fp='chrome';flow='';reality_pbk='';reality_sid='';transport='tcp';path='';host='';method='';obfs='';mux=$false;sub=$false } }
function Pad-B64 { param($s) $s=$s.Replace('-','+').Replace('_','/'); switch($s.Length % 4){ 2{$s+='=='} 3{$s+='='} }; $s }
function Parse-Query { param($q) $h=@{}; if($q){ foreach($pair in $q.Split('&')){ $kv=$pair.Split('=',2); if($kv.Count -eq 2){ $h[$kv[0]]=[Uri]::UnescapeDataString($kv[1]) } } }; $h }

function Build-Tls { param($p)
    $tls=@{ enabled=$true; insecure=[bool]$p.insecure }
    if ("$($p.sni)") { $tls.server_name="$($p.sni)" }
    if ("$($p.fp)")  { $tls.utls=@{ enabled=$true; fingerprint="$($p.fp)" } }
    if ("$($p.reality_pbk)") { $tls.reality=@{ enabled=$true; public_key="$($p.reality_pbk)"; short_id="$($p.reality_sid)" } }
    $tls
}
function Build-Transport { param($p)
    switch ("$($p.transport)") {
        'grpc'        { return @{ type='grpc'; service_name="$($p.path)" } }
        'ws'          { $pp="$($p.path)"; if(-not $pp){$pp='/'}; $hd=@{}; if("$($p.host)"){$hd.Host="$($p.host)"}; return @{ type='ws'; path=$pp; headers=$hd } }
        'httpupgrade' { $pp="$($p.path)"; if(-not $pp){$pp='/'}; return @{ type='httpupgrade'; path=$pp; host="$($p.host)" } }
        default       { return $null }
    }
}
function Build-Outbound { param($p)
    $t="$($p.type)"; if(-not $t){$t='vless'}
    $s="$($p.server)"; $port=[int]$p.port; $uuid="$($p.uuid)"; $pass="$($p.password)"
    $tls=Build-Tls $p; $tr=Build-Transport $p
    switch ($t) {
        'vless'       { $ob=@{ type='vless'; server=$s; server_port=$port; uuid=$uuid; tls=$tls }; if("$($p.flow)"){$ob.flow="$($p.flow)"}; if($tr){$ob.transport=$tr} }
        'vmess'       { $ob=@{ type='vmess'; server=$s; server_port=$port; uuid=$uuid; security='auto'; tls=$tls }; if($tr){$ob.transport=$tr} }
        'trojan'      { $ob=@{ type='trojan'; server=$s; server_port=$port; password=$pass; tls=$tls }; if($tr){$ob.transport=$tr} }
        'shadowsocks' { $ob=@{ type='shadowsocks'; server=$s; server_port=$port; method="$($p.method)"; password=$pass } }
        'hysteria2'   { [void]$tls.Remove('utls'); $ob=@{ type='hysteria2'; server=$s; server_port=$port; password=$pass; tls=$tls }; if("$($p.obfs)"){ $ob.obfs=@{ type='salamander'; password="$($p.obfs)" } } }
        'tuic'        { [void]$tls.Remove('utls'); $tls.alpn=@('h3'); $ob=@{ type='tuic'; server=$s; server_port=$port; uuid=$uuid; password=$pass; tls=$tls } }
        default       { $ob=@{ type='vless'; server=$s; server_port=$port; uuid=$uuid; tls=$tls } }
    }
    if($p.mux){ $ob.multiplex=@{ enabled=$true; protocol='h2mux'; max_streams=8 } }
    $ob.tag='proxy'; $ob
}
function Write-SbConfig { param($p)
    $conf=[ordered]@{
        log=@{ level='warn'; output=(Join-Path $root 'sb_log.txt') }
        dns=@{ servers=@(@{ tag='remote'; address='1.1.1.1'; detour='proxy' }); final='remote'; strategy='ipv4_only' }
        inbounds=@(@{ type='tun'; tag='tun-in'; interface_name='SvobodaTun'; address=@('172.18.0.1/30'); mtu=1400; auto_route=$true; strict_route=$false; stack='gvisor'; sniff=$true })
        outbounds=@( (Build-Outbound $p), @{ type='direct'; tag='direct' }, @{ type='dns'; tag='dns-out' } )
        route=@{ rules=@(@{ protocol='dns'; outbound='dns-out' }); auto_detect_interface=$true; final='proxy' }
    }
    Write-TextNoBom $cfg ($conf | ConvertTo-Json -Depth 10)
}

function Parse-VpnLink { param($link)
    $link=$link.Trim(); $p=New-Profile; $name=''
    if($link.Contains('#')){ $name=[Uri]::UnescapeDataString($link.Substring($link.IndexOf('#')+1)); $link=$link.Substring(0,$link.IndexOf('#')) }
    if($link -match '^vless://'){
        $p.type='vless'; $rest=$link.Substring(8); $uuid=$rest.Split('@')[0]; $hp=$rest.Split('@')[1]
        $hostport=$hp.Split('?')[0]; $q=Parse-Query ($hp.Split('?',2)[1])
        $p.uuid=$uuid; $p.server=$hostport.Split(':')[0]; $p.port=[int]($hostport.Split(':')[1])
        $p.sni=$q['sni']; $p.fp=$q['fp']; $p.flow=$q['flow']
        if($q['security'] -eq 'reality'){ $p.reality_pbk=$q['pbk']; $p.reality_sid=$q['sid'] }
        $net=$q['type']; if($net){ $p.transport=$net; if($net -eq 'grpc'){$p.path=$q['serviceName']} elseif($net -eq 'ws' -or $net -eq 'httpupgrade'){$p.path=$q['path']; $p.host=$q['host']} }
        if($q['allowInsecure'] -eq '1' -or $q['insecure'] -eq '1'){ $p.insecure=$true } else { $p.insecure=$false }
        if(-not $p.sni){ $p.insecure=$true }
    }
    elseif($link -match '^(hysteria2|hy2)://'){
        $p.type='hysteria2'; $rest=$link -replace '^(hysteria2|hy2)://',''; $pass=$rest.Split('@')[0]; $hp=$rest.Split('@')[1]
        $hostport=$hp.Split('?')[0]; $q=Parse-Query ($hp.Split('?',2)[1])
        $p.password=[Uri]::UnescapeDataString($pass); $p.server=$hostport.Split(':')[0]; $p.port=[int]($hostport.Split(':')[1])
        $p.sni=$q['sni']; if($q['insecure'] -eq '1'){ $p.insecure=$true }; if($q['obfs'] -eq 'salamander'){ $p.obfs=$q['obfs-password'] }
    }
    elseif($link -match '^tuic://'){
        $p.type='tuic'; $rest=$link.Substring(7); $cred=$rest.Split('@')[0]; $hp=$rest.Split('@')[1]
        $p.uuid=$cred.Split(':')[0]; $p.password=[Uri]::UnescapeDataString($cred.Split(':',2)[1])
        $hostport=$hp.Split('?')[0]; $q=Parse-Query ($hp.Split('?',2)[1])
        $p.server=$hostport.Split(':')[0]; $p.port=[int]($hostport.Split(':')[1]); $p.sni=$q['sni']
        if($q['allow_insecure'] -eq '1' -or $q['insecure'] -eq '1'){ $p.insecure=$true }
    }
    elseif($link -match '^trojan://'){
        $p.type='trojan'; $rest=$link.Substring(9); $p.password=[Uri]::UnescapeDataString($rest.Split('@')[0]); $hp=$rest.Split('@')[1]
        $hostport=$hp.Split('?')[0]; $q=Parse-Query ($hp.Split('?',2)[1])
        $p.server=$hostport.Split(':')[0]; $p.port=[int]($hostport.Split(':')[1]); $p.sni=$q['sni']; $p.fp=$q['fp']
        if($q['allowInsecure'] -eq '1'){ $p.insecure=$true }
        $net=$q['type']; if($net){ $p.transport=$net; if($net -eq 'grpc'){$p.path=$q['serviceName']} elseif($net -eq 'ws'){$p.path=$q['path']; $p.host=$q['host']} }
    }
    elseif($link -match '^ss://'){
        $p.type='shadowsocks'; $rest=$link.Substring(5)
        if($rest.Contains('@')){
            $mp=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Pad-B64 $rest.Split('@')[0])))
            $p.method=$mp.Split(':')[0]; $p.password=$mp.Split(':',2)[1]
            $hp=$rest.Split('@')[1].Split('?')[0]; $p.server=$hp.Split(':')[0]; $p.port=[int]($hp.Split(':')[1])
        } else {
            $dec=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Pad-B64 $rest.Split('?')[0])))
            $p.method=$dec.Split(':')[0]; $am=$dec.Split(':',2)[1]; $p.password=$am.Split('@')[0]
            $hp=$am.Split('@')[1]; $p.server=$hp.Split(':')[0]; $p.port=[int]($hp.Split(':')[1])
        }
    }
    elseif($link -match '^vmess://'){
        $p.type='vmess'; $j=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Pad-B64 $link.Substring(8)))) | ConvertFrom-Json
        $p.server="$($j.add)"; $p.port=[int]$j.port; $p.uuid="$($j.id)"; $p.sni="$($j.sni)"; $p.host="$($j.host)"; $p.path="$($j.path)"
        if("$($j.net)"){ $p.transport="$($j.net)" }; if("$($j.tls)" -eq 'tls'){ $p.insecure=$true }
        if("$($j.ps)"){ $name="$($j.ps)" }
    }
    else { throw 'Неизвестный формат ссылки (vless/hysteria2/tuic/trojan/ss/vmess)' }
    if(-not $name){ $name="$($p.type) $($p.server)" }
    $p.name=$name; [pscustomobject]$p
}

function Import-Subscription { param($url)
    $raw = (& curl.exe -s -m 25 -A 'Happ/1.0' "$url") 2>$null
    if(-not "$raw"){ throw 'подписка не ответила' }
    $text = "$raw"
    try { $d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Pad-B64 ($text.Trim() -replace '\s','')))); if($d -match '://'){ $text=$d } } catch {}
    $new=@()
    foreach($l in ($text -split "`n")){ $l=$l.Trim(); if($l -match '://'){ try { $np=Parse-VpnLink $l; $np.sub=$true; $new+=$np } catch {} } }
    if($new.Count -eq 0){ throw 'в подписке нет серверов' }
    $new
}

function Is-Connected { [bool](Get-Process sing-box -ErrorAction SilentlyContinue) }
function Connect-Vpn {
    if (Is-Connected) { return }
    $ap = Active-Profile
    if (-not $ap -or -not "$($ap.server)") { [Windows.Forms.MessageBox]::Show('Сначала добавь сервер: «⚙ Управление серверами» → вставь свою ссылку (vless / hysteria2 / ss / tuic / trojan / vmess).','Свобода VPN','OK','Information'); return }
    Write-SbConfig $ap
    Start-Process -FilePath $exe -ArgumentList 'run','-c',$cfg -WorkingDirectory $root -WindowStyle Hidden
}
function Disconnect-Vpn { Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force }

function New-DotIcon { param($color)
    $bmp=New-Object Drawing.Bitmap 32,32
    $g=[Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object Drawing.SolidBrush $color),5,5,22,22); $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icoOn=New-DotIcon $cGreen; $icoOff=New-DotIcon ([Drawing.Color]::FromArgb(120,120,140))

# иконки в стиле Lucide (шрифт Segoe Fluent Icons)
function New-Glyph { param([int]$code,[int]$size,$color)
    try {
        $bmp=New-Object Drawing.Bitmap $size,$size
        $g=[Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='ClearTypeGridFit'; $g.Clear([Drawing.Color]::Transparent)
        $f=New-Object Drawing.Font('Segoe Fluent Icons',[float]($size*0.62),[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
        $sf=New-Object Drawing.StringFormat; $sf.Alignment='Center'; $sf.LineAlignment='Center'
        $g.DrawString([string][char]$code,$f,(New-Object Drawing.SolidBrush $color),(New-Object Drawing.RectangleF(0,0,$size,$size)),$sf)
        $g.Dispose(); $bmp
    } catch { $null }
}

function Set-RoundRegion { param($ctl,$radius)
    $p=New-Object Drawing.Drawing2D.GraphicsPath
    $d=$radius*2; $w=$ctl.Width; $h=$ctl.Height
    $p.AddArc(0,0,$d,$d,180,90); $p.AddArc($w-$d,0,$d,$d,270,90)
    $p.AddArc($w-$d,$h-$d,$d,$d,0,90); $p.AddArc(0,$h-$d,$d,$d,90,90); $p.CloseFigure()
    $ctl.Region=New-Object Drawing.Region $p
}
function Flat-Button { param($b)
    $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.ForeColor=[Drawing.Color]::White
    $b.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold); $b.Cursor='Hand'
}

try {
# ===================== MAIN WINDOW =====================
$script:form=New-Object Windows.Forms.Form
$script:form.FormBorderStyle='None'; $script:form.StartPosition='CenterScreen'; $script:form.AutoScaleMode='None'
$script:form.Size=New-Object Drawing.Size((Px 460),(Px 548)); $script:form.BackColor=$cBg
$script:form.ShowInTaskbar=$true; $script:form.Text='Свобода VPN'
$semi=[Drawing.FontStyle]::Bold
$dragH={ param($s,$e) if($e.Button -eq 'Left'){ [W32]::ReleaseCapture(); [W32]::SendMessage($script:form.Handle,0xA1,0x2,0) } }

# header (белый) с текстом-заголовком
$hdr=New-Object Windows.Forms.Panel; $hdr.SetBounds(0,0,(Px 460),(Px 66)); $hdr.BackColor=$cCard
$script:form.Controls.Add($hdr); $hdr.Add_MouseDown($dragH)
$lblTitle=New-Object Windows.Forms.Label; $lblTitle.Text='Свобода ВПН'; $lblTitle.ForeColor=$cAccent
$lblTitle.Font=New-Object Drawing.Font('Segoe UI Semibold',17,$semi); $lblTitle.SetBounds((Px 24),(Px 14),(Px 360),(Px 38)); $lblTitle.TextAlign='MiddleLeft'
$hdr.Controls.Add($lblTitle); $lblTitle.Add_MouseDown($dragH)
$btnMin=New-Object Windows.Forms.Button; $btnMin.Text='—'; $btnMin.SetBounds((Px 392),(Px 10),(Px 30),(Px 30)); Flat-Button $btnMin; $btnMin.BackColor=$cCard; $btnMin.ForeColor=$cSub; $btnMin.Font=New-Object Drawing.Font('Segoe UI',11)
$btnClose=New-Object Windows.Forms.Button; $btnClose.Text='✕'; $btnClose.SetBounds((Px 424),(Px 10),(Px 30),(Px 30)); Flat-Button $btnClose; $btnClose.BackColor=$cCard; $btnClose.ForeColor=$cSub; $btnClose.Font=New-Object Drawing.Font('Segoe UI',11)
$hdr.Controls.Add($btnMin); $hdr.Controls.Add($btnClose)

# статус
$script:lblStatus=New-Object Windows.Forms.Label; $script:lblStatus.SetBounds(0,(Px 82),(Px 460),(Px 30)); $script:lblStatus.TextAlign='MiddleCenter'
$script:lblStatus.Font=New-Object Drawing.Font('Segoe UI Semibold',14,$semi); $script:form.Controls.Add($script:lblStatus)

# большая круглая кнопка с иконкой питания
$script:btnConn=New-Object Windows.Forms.Button; $script:btnConn.SetBounds((Px 155),(Px 124),(Px 150),(Px 150))
Flat-Button $script:btnConn; $script:btnConn.Font=New-Object Drawing.Font('Segoe UI Semibold',13,$semi)
$script:btnConn.TextImageRelation='ImageAboveText'; $script:btnConn.ImageAlign='MiddleCenter'; $script:btnConn.TextAlign='MiddleCenter'
$gPow=New-Glyph 0xE7E8 (Px 44) ([Drawing.Color]::White); if($gPow){ $script:btnConn.Image=$gPow; $script:btnConn.Padding=New-Object Windows.Forms.Padding(0,(Px 18),0,0) }
$script:form.Controls.Add($script:btnConn)

# IP
$script:lblIp=New-Object Windows.Forms.Label; $script:lblIp.SetBounds(0,(Px 288),(Px 460),(Px 22)); $script:lblIp.TextAlign='MiddleCenter'
$script:lblIp.Font=New-Object Drawing.Font('Segoe UI',10); $script:lblIp.ForeColor=$cSub; $script:form.Controls.Add($script:lblIp)

# выбор сервера
$lblSrv=New-Object Windows.Forms.Label; $lblSrv.Text='Сервер'; $lblSrv.ForeColor=$cSub
$lblSrv.Font=New-Object Drawing.Font('Segoe UI',10); $lblSrv.SetBounds((Px 28),(Px 322),(Px 200),(Px 18)); $script:form.Controls.Add($lblSrv)
$script:cmb=New-Object Windows.Forms.ComboBox; $script:cmb.SetBounds((Px 28),(Px 344),(Px 404),(Px 36)); $script:cmb.DropDownStyle='DropDownList'
$script:cmb.FlatStyle='Flat'; $script:cmb.BackColor=$cCard; $script:cmb.ForeColor=$cText
$script:cmb.Font=New-Object Drawing.Font('Segoe UI',11); $script:form.Controls.Add($script:cmb)

# кнопки с иконками
$btnMng=New-Object Windows.Forms.Button; $btnMng.Text='Серверы'; $btnMng.SetBounds((Px 28),(Px 396),(Px 196),(Px 44))
Flat-Button $btnMng; $btnMng.BackColor=$cBtn2; $btnMng.ForeColor=$cAccent; $btnMng.Font=New-Object Drawing.Font('Segoe UI Semibold',11,$semi)
$btnMng.TextImageRelation='ImageBeforeText'; $g2=New-Glyph 0xE713 (Px 22) $cAccent; if($g2){ $btnMng.Image=$g2 }
$script:form.Controls.Add($btnMng)
$btnSub=New-Object Windows.Forms.Button; $btnSub.Text='Подписка'; $btnSub.SetBounds((Px 236),(Px 396),(Px 196),(Px 44))
Flat-Button $btnSub; $btnSub.BackColor=$cBtn2; $btnSub.ForeColor=$cAccent; $btnSub.Font=New-Object Drawing.Font('Segoe UI Semibold',11,$semi)
$btnSub.TextImageRelation='ImageBeforeText'; $g3=New-Glyph 0xE72C (Px 22) $cAccent; if($g3){ $btnSub.Image=$g3 }
$script:form.Controls.Add($btnSub)
$btnVk=New-Object Windows.Forms.Button; $btnVk.Text='VK-туннель — строгий белый список'; $btnVk.SetBounds((Px 28),(Px 454),(Px 404),(Px 46))
Flat-Button $btnVk; $btnVk.BackColor=$cGreen; $btnVk.ForeColor=[Drawing.Color]::White; $btnVk.Font=New-Object Drawing.Font('Segoe UI Semibold',11,$semi)
$btnVk.TextImageRelation='ImageBeforeText'; $g4=New-Glyph 0xE717 (Px 22) ([Drawing.Color]::White); if($g4){ $btnVk.Image=$g4 }
$script:form.Controls.Add($btnVk)
# Обычный режим: одна простая кнопка добавления сервера
$btnAdd=New-Object Windows.Forms.Button; $btnAdd.Text='+  Добавить сервер (вставить ссылку)'; $btnAdd.SetBounds((Px 28),(Px 396),(Px 404),(Px 44))
Flat-Button $btnAdd; $btnAdd.BackColor=$cBtn2; $btnAdd.ForeColor=$cAccent; $btnAdd.Font=New-Object Drawing.Font('Segoe UI Semibold',11,$semi)
$script:form.Controls.Add($btnAdd)
# переключатель режима
$lblMode=New-Object Windows.Forms.Label; $lblMode.SetBounds((Px 28),(Px 508),(Px 404),(Px 24)); $lblMode.TextAlign='MiddleCenter'; $lblMode.ForeColor=$cAccent; $lblMode.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Underline); $lblMode.Cursor='Hand'
$script:form.Controls.Add($lblMode)
$script:form.Add_Shown({ Set-RoundRegion $script:form (Px 18); Set-RoundRegion $script:btnConn (Px 75); Set-RoundRegion $btnMng (Px 10); Set-RoundRegion $btnSub (Px 10); Set-RoundRegion $btnAdd (Px 10); Set-RoundRegion $btnVk (Px 12) })

function Fill-Combo {
    $script:cmb.Items.Clear()
    foreach($p in $script:state.profiles){ [void]$script:cmb.Items.Add($p.name) }
    if($script:state.profiles.Count -gt 0){ $script:cmb.SelectedIndex=[int]$script:state.active }
}
function Update-UI {
    if(Is-Connected){
        $script:btnConn.Text='Отключить'; $script:btnConn.BackColor=$cGreen
        $script:lblStatus.Text='● Защищено'; $script:lblStatus.ForeColor=$cGreen
        $script:tray.Icon=$icoOn; $script:tray.Text='Свобода VPN — защищено'
    } else {
        $script:btnConn.Text='Подключить'; $script:btnConn.BackColor=$cAccent
        $script:lblStatus.Text='● Не защищено'; $script:lblStatus.ForeColor=$cSub
        $script:lblIp.Text=''; $script:tray.Icon=$icoOff; $script:tray.Text='Свобода VPN — отключено'
    }
}
function Check-Ip {
    $script:lblIp.Text='проверяю…'; $script:lblIp.ForeColor=$cSub; $script:lblIp.Refresh()
    $ip=(& curl.exe -s -m 10 https://api.ipify.org) 2>$null
    if($ip){ $script:lblIp.Text="IP: $ip"; $script:lblIp.ForeColor=$cGreen } else { $script:lblIp.Text='IP: нет ответа'; $script:lblIp.ForeColor=$cRed }
}
# умное подключение: пробует активный сервер, при неудаче перебирает остальные
function Auto-Connect {
    $n=$script:state.profiles.Count
    if($n -eq 0){ Connect-Vpn; Update-UI; return }
    $script:lblStatus.Text='Подключаюсь…'; $script:lblStatus.ForeColor=$cAccent; $script:lblStatus.Refresh()
    for($k=0;$k -lt $n;$k++){
        $idx=([int]$script:state.active + $k) % $n
        $script:state.active=$idx; if($script:cmb.SelectedIndex -ne $idx){ $script:cmb.SelectedIndex=$idx }
        Write-SbConfig $script:state.profiles[$idx]
        # ТСПУ ставит блок в момент хендшейка (>50% — ложные срабатывания): даём узлу 2 попытки переподключения, прежде чем считать его мёртвым
        for($try=1;$try -le 2;$try++){
            if($try -eq 2){ $script:lblStatus.Text='Переподключаюсь…'; $script:lblStatus.ForeColor=$cAccent; $script:lblStatus.Refresh() }
            Disconnect-Vpn; Start-Sleep -Milliseconds 300
            Start-Process -FilePath $exe -ArgumentList 'run','-c',$cfg -WorkingDirectory $root -WindowStyle Hidden
            Start-Sleep -Seconds 4
            $ip=(& curl.exe -s -m 8 https://api.ipify.org) 2>$null
            if($ip){ Save-State $script:state; Update-UI; $script:lblIp.Text="через $($script:state.profiles[$idx].name)  ·  $ip"; $script:lblIp.ForeColor=$cGreen; return }
        }
    }
    Disconnect-Vpn; Update-UI; $script:lblStatus.Text='Не удалось подключиться'; $script:lblStatus.ForeColor=$cRed
}

# ===================== EDITOR WINDOW (все настройки) =====================
function Show-Editor {
    $ed=New-Object Windows.Forms.Form; $ed.FormBorderStyle='None'; $ed.StartPosition='CenterParent'; $ed.AutoScaleMode='None'
    $ed.Size=New-Object Drawing.Size((Px 470),(Px 600)); $ed.BackColor=$cBg
    $ed.Add_Shown({ Set-RoundRegion $ed (Px 16) })
    $eh=New-Object Windows.Forms.Label; $eh.Text='  Серверы и настройки'; $eh.ForeColor=$cText
    $eh.Font=New-Object Drawing.Font('Segoe UI Semibold',13,[Drawing.FontStyle]::Bold); $eh.SetBounds((Px 8),(Px 12),(Px 320),(Px 30)); $ed.Controls.Add($eh)
    $eh.Add_MouseDown({ param($s,$e) if($e.Button -eq 'Left'){ [W32]::ReleaseCapture(); [W32]::SendMessage($ed.Handle,0xA1,0x2,0) } })
    $bx=New-Object Windows.Forms.Button; $bx.Text='✕'; $bx.SetBounds((Px 426),(Px 10),(Px 30),(Px 30)); Flat-Button $bx; $bx.BackColor=$cBg; $bx.ForeColor=$cSub; $ed.Controls.Add($bx)

    $lblImp=New-Object Windows.Forms.Label; $lblImp.Text='Вставь ссылку (vless / hysteria2 / ss / tuic / trojan / vmess):'; $lblImp.ForeColor=$cSub; $lblImp.Font=New-Object Drawing.Font('Segoe UI',9); $lblImp.SetBounds((Px 16),(Px 46),(Px 430),(Px 16)); $ed.Controls.Add($lblImp)
    $tbImp=New-Object Windows.Forms.TextBox; $tbImp.SetBounds((Px 16),(Px 64),(Px 340),(Px 26)); $tbImp.BackColor=$cCard; $tbImp.ForeColor=$cText; $tbImp.BorderStyle='FixedSingle'; $tbImp.Font=New-Object Drawing.Font('Segoe UI',10); $ed.Controls.Add($tbImp)
    $bImp=New-Object Windows.Forms.Button; $bImp.Text='Добавить'; $bImp.SetBounds((Px 364),(Px 64),(Px 90),(Px 26)); Flat-Button $bImp; $bImp.BackColor=$cGreen; $bImp.ForeColor=[Drawing.Color]::White; $bImp.Font=New-Object Drawing.Font('Segoe UI Semibold',9,[Drawing.FontStyle]::Bold); $ed.Controls.Add($bImp)

    $lst=New-Object Windows.Forms.ListBox; $lst.SetBounds((Px 16),(Px 98),(Px 438),(Px 72)); $lst.BackColor=$cCard; $lst.ForeColor=$cText; $lst.BorderStyle='FixedSingle'; $lst.Font=New-Object Drawing.Font('Segoe UI',10); $ed.Controls.Add($lst)

    # прокручиваемая панель со ВСЕМИ настройками
    $pnl=New-Object Windows.Forms.Panel; $pnl.SetBounds((Px 12),(Px 178),(Px 446),(Px 350)); $pnl.AutoScroll=$true; $pnl.BackColor=$cBg; $ed.Controls.Add($pnl)
    $fw=Px 414
    $py=0
    $fields=@{}
    foreach($f in @(@('name','Название'),@('server','IP / домен'),@('port','Порт'),@('uuid','UUID (vless/vmess/tuic)'),@('password','Пароль (trojan/ss/hysteria2/tuic)'),@('sni','SNI (пусто = без SNI)'),@('reality_pbk','Reality Public Key (pbk)'),@('reality_sid','Reality Short ID (sid)'),@('path','Path / serviceName (ws/grpc)'),@('host','Host (ws)'),@('obfs','Obfs-пароль (hysteria2)'))){
        $lb=New-Object Windows.Forms.Label; $lb.Text=$f[1]; $lb.ForeColor=$cSub; $lb.Font=New-Object Drawing.Font('Segoe UI',9); $lb.SetBounds((Px 4),$py,$fw,(Px 16)); $pnl.Controls.Add($lb)
        $tb=New-Object Windows.Forms.TextBox; $tb.SetBounds((Px 4),($py+(Px 17)),$fw,(Px 26)); $tb.BackColor=$cCard; $tb.ForeColor=$cText; $tb.BorderStyle='FixedSingle'; $tb.Font=New-Object Drawing.Font('Segoe UI',10); $pnl.Controls.Add($tb)
        $fields[$f[0]]=$tb; $py+=Px 48
    }
    $combos=@{}
    foreach($cs in @(@('type','Протокол',@('vless','vmess','trojan','shadowsocks','hysteria2','tuic')),@('fp','uTLS отпечаток (маскировка)',@('','chrome','firefox','safari','edge','ios','random')),@('flow','Flow (vless+Reality)',@('','xtls-rprx-vision')),@('transport','Транспорт',@('tcp','grpc','ws','httpupgrade')),@('method','Метод (shadowsocks)',@('','2022-blake3-aes-256-gcm','aes-256-gcm','chacha20-ietf-poly1305')))){
        $lb=New-Object Windows.Forms.Label; $lb.Text=$cs[1]; $lb.ForeColor=$cSub; $lb.Font=New-Object Drawing.Font('Segoe UI',9); $lb.SetBounds((Px 4),$py,$fw,(Px 16)); $pnl.Controls.Add($lb)
        $cb=New-Object Windows.Forms.ComboBox; $cb.SetBounds((Px 4),($py+(Px 17)),$fw,(Px 26)); $cb.DropDownStyle='DropDownList'; $cb.FlatStyle='Flat'; $cb.BackColor=$cCard; $cb.ForeColor=$cText; $cb.Font=New-Object Drawing.Font('Segoe UI',10); foreach($it in $cs[2]){ [void]$cb.Items.Add($it) }; $pnl.Controls.Add($cb)
        $combos[$cs[0]]=$cb; $py+=Px 48
    }
    $chkIns=New-Object Windows.Forms.CheckBox; $chkIns.Text='Не проверять сертификат (insecure)'; $chkIns.ForeColor=$cText; $chkIns.Font=New-Object Drawing.Font('Segoe UI',9); $chkIns.SetBounds((Px 4),$py,$fw,(Px 24)); $pnl.Controls.Add($chkIns); $py+=Px 28
    $chkMux=New-Object Windows.Forms.CheckBox; $chkMux.Text='Mux — мультиплекс (иногда помогает обойти DPI)'; $chkMux.ForeColor=$cText; $chkMux.Font=New-Object Drawing.Font('Segoe UI',9); $chkMux.SetBounds((Px 4),$py,$fw,(Px 24)); $pnl.Controls.Add($chkMux); $py+=Px 28

    $bNew=New-Object Windows.Forms.Button; $bNew.Text='Новый'; $bNew.SetBounds((Px 16),(Px 540),(Px 110),(Px 36)); Flat-Button $bNew; $bNew.BackColor=$cBtn2; $bNew.ForeColor=$cAccent
    $bSave=New-Object Windows.Forms.Button; $bSave.Text='Сохранить'; $bSave.SetBounds((Px 136),(Px 540),(Px 190),(Px 36)); Flat-Button $bSave; $bSave.BackColor=$cAccent
    $bDel=New-Object Windows.Forms.Button; $bDel.Text='Удалить'; $bDel.SetBounds((Px 336),(Px 540),(Px 118),(Px 36)); Flat-Button $bDel; $bDel.BackColor=$cRed
    $ed.Controls.Add($bNew); $ed.Controls.Add($bSave); $ed.Controls.Add($bDel)

    function Fill-List { $lst.Items.Clear(); foreach($p in $script:state.profiles){ [void]$lst.Items.Add($p.name) } }
    function Fill-Fields { param($p)
        foreach($k in @($fields.Keys)){ $fields[$k].Text="$($p.$k)" }
        foreach($k in @($combos.Keys)){ $combos[$k].SelectedItem="$($p.$k)"; if($combos[$k].SelectedIndex -lt 0){ $combos[$k].SelectedIndex=0 } }
        $chkIns.Checked=[bool]$p.insecure; $chkMux.Checked=[bool]$p.mux
    }
    function Read-Fields {
        if($lst.SelectedIndex -ge 0){ $oldSub=[bool]$script:state.profiles[$lst.SelectedIndex].sub } else { $oldSub=$false }
        $np=[pscustomobject](New-Profile)
        foreach($k in @($fields.Keys)){ if($k -eq 'port'){ $np.port=[int]("0"+$fields['port'].Text) } else { $np.$k=$fields[$k].Text } }
        foreach($k in @($combos.Keys)){ $np.$k="$($combos[$k].SelectedItem)" }
        $np.insecure=$chkIns.Checked; $np.mux=$chkMux.Checked; $np.sub=$oldSub
        if($np.port -le 0){ $np.port=443 }
        $np
    }
    Fill-List
    $lst.Add_SelectedIndexChanged({ if($lst.SelectedIndex -ge 0){ Fill-Fields $script:state.profiles[$lst.SelectedIndex] } })
    $bNew.Add_Click({ $lst.ClearSelected(); Fill-Fields ([pscustomobject](New-Profile)); $fields['name'].Text='Новый сервер'; $fields['port'].Text='443' })
    $bImp.Add_Click({
        if(-not $tbImp.Text.Trim()){ return }
        try {
            $np=Parse-VpnLink $tbImp.Text
            $arr=@($script:state.profiles); $arr+=$np; $script:state.profiles=$arr; $script:state.active=$arr.Count-1
            Save-State $script:state; Fill-List; Fill-Combo; $tbImp.Text=''
            [Windows.Forms.MessageBox]::Show("Добавлен: $($np.name)","Импорт",'OK','Information')
        } catch { [Windows.Forms.MessageBox]::Show("Не удалось разобрать ссылку: $($_.Exception.Message)","Импорт",'OK','Warning') }
    })
    $bSave.Add_Click({
        $np=Read-Fields
        $arr=@($script:state.profiles)
        if($lst.SelectedIndex -ge 0){ $arr[$lst.SelectedIndex]=$np } else { $arr+=$np }
        $script:state.profiles=$arr; Save-State $script:state; Fill-List; Fill-Combo
        [Windows.Forms.MessageBox]::Show("Сохранено: $($np.name)","Серверы",'OK','Information')
    })
    $bDel.Add_Click({
        if($lst.SelectedIndex -ge 0 -and $script:state.profiles.Count -gt 1){
            $i=$lst.SelectedIndex; $new=@()
            for($k=0;$k -lt $script:state.profiles.Count;$k++){ if($k -ne $i){ $new+=$script:state.profiles[$k] } }
            $script:state.profiles=$new
            if([int]$script:state.active -ge $script:state.profiles.Count){ $script:state.active=0 }
            Save-State $script:state; Fill-List; Fill-Combo
        }
    })
    $bx.Add_Click({ $ed.Close() })
    [void]$ed.ShowDialog($script:form)
}

# ===================== TRAY =====================
$script:tray=New-Object Windows.Forms.NotifyIcon; $script:tray.Icon=$icoOff; $script:tray.Visible=$true; $script:tray.Text='Свобода VPN'
$menu=New-Object Windows.Forms.ContextMenuStrip
$miOpen=$menu.Items.Add('Открыть'); $miConn=$menu.Items.Add('Подключить'); $miDisc=$menu.Items.Add('Отключить'); [void]$menu.Items.Add('-'); $miExit=$menu.Items.Add('Выход')
$script:tray.ContextMenuStrip=$menu

function Show-Window { $script:form.Show(); $script:form.WindowState='Normal'; $script:form.Activate() }

$script:btnConn.Add_Click({
    if(Is-Connected){ Disconnect-Vpn; Update-UI } else { Auto-Connect }
})
$btnMng.Add_Click({ Show-Editor })
$btnSub.Add_Click({
    Add-Type -AssemblyName Microsoft.VisualBasic
    $cur = "$($script:state.subscription)"
    $url = [Microsoft.VisualBasic.Interaction]::InputBox('Вставь URL подписки (sub-ссылка сервиса или своя) — серверы обновятся автоматически:','Подписка',$cur)
    if(-not $url){ return }
    try {
        $subs = Import-Subscription $url
        $manual = @($script:state.profiles | Where-Object { -not $_.sub })
        $script:state.profiles = @($manual + $subs)
        $script:state | Add-Member -NotePropertyName subscription -NotePropertyValue $url -Force
        $script:state.active = 0
        Save-State $script:state; Fill-Combo; Update-UI
        [Windows.Forms.MessageBox]::Show("Загружено серверов из подписки: $($subs.Count)",'Подписка','OK','Information')
    } catch { [Windows.Forms.MessageBox]::Show("Ошибка подписки: $($_.Exception.Message)",'Подписка','OK','Warning') }
})
$btnVk.Add_Click({
    $pw = Join-Path $root 'PWDTT.exe'
    if (-not (Test-Path $pw)) { [Windows.Forms.MessageBox]::Show('Модуль VK-туннеля (PWDTT.exe) не найден рядом с приложением.','VK-туннель','OK','Warning'); return }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$pw`"" }
    catch {
        try { [System.Diagnostics.Process]::Start($pw) | Out-Null }
        catch { [Windows.Forms.MessageBox]::Show("Не удалось запустить VK-модуль:`n$($_.Exception.Message)",'VK-туннель','OK','Warning') }
    }
})
$btnAdd.Add_Click({
    Add-Type -AssemblyName Microsoft.VisualBasic
    $link=[Microsoft.VisualBasic.Interaction]::InputBox('Вставь ссылку сервера (vless:// и т.д.) — её выдаёт твой VPS после настройки:','Добавить сервер','')
    if(-not $link){ return }
    try { $np=Parse-VpnLink $link; $arr=@($script:state.profiles); $arr+=$np; $script:state.profiles=$arr; $script:state.active=$arr.Count-1; Save-State $script:state; Fill-Combo; Update-UI; [Windows.Forms.MessageBox]::Show("Добавлен сервер: $($np.name).`nНажми большую кнопку, чтобы подключиться.",'Сервер','OK','Information') }
    catch { [Windows.Forms.MessageBox]::Show("Не получилось разобрать ссылку:`n$($_.Exception.Message)",'Сервер','OK','Warning') }
})
function Apply-Mode {
    $adv=[bool]$script:state.advanced
    $btnMng.Visible=$adv; $btnSub.Visible=$adv; $btnAdd.Visible=(-not $adv)
    if($adv){ $lblMode.Text='← обычный режим (проще)' } else { $lblMode.Text='⚙ продвинутый режим (все настройки)' }
}
$lblMode.Add_Click({ $cur=[bool]$script:state.advanced; $script:state | Add-Member -NotePropertyName advanced -NotePropertyValue (-not $cur) -Force; Save-State $script:state; Apply-Mode })
$btnMin.Add_Click({ $script:form.Hide() })
$btnClose.Add_Click({ $script:form.Hide() })
$script:cmb.Add_SelectedIndexChanged({ if($script:cmb.SelectedIndex -ge 0){ $script:state.active=$script:cmb.SelectedIndex; Save-State $script:state } })
$script:form.Add_FormClosing({ param($s,$e) if(-not $script:exiting){ $e.Cancel=$true; $script:form.Hide() } })

$miOpen.Add_Click({ Show-Window }); $script:tray.Add_MouseDoubleClick({ Show-Window })
$miConn.Add_Click({ Connect-Vpn; Start-Sleep -Milliseconds 1600; Update-UI })
$miDisc.Add_Click({ Disconnect-Vpn; Update-UI })
$miExit.Add_Click({ $script:exiting=$true; Disconnect-Vpn; $script:tray.Visible=$false; [Windows.Forms.Application]::Exit() })

Fill-Combo; Update-UI; Apply-Mode
$script:tray.ShowBalloonTip(3000,'Свобода VPN','Подключаюсь автоматически…',[Windows.Forms.ToolTipIcon]::Info)
# авто-подключение при запуске (новичку ничего делать не надо)
$script:startTimer=New-Object Windows.Forms.Timer; $script:startTimer.Interval=900
$script:startTimer.Add_Tick({ $script:startTimer.Stop(); Auto-Connect })
$script:startTimer.Start()
$ctx=New-Object Windows.Forms.ApplicationContext
[Windows.Forms.Application]::Run($ctx)
}
catch {
    $_ | Out-File (Join-Path $root 'gui_error.txt') -Encoding UTF8
    [Windows.Forms.MessageBox]::Show("Ошибка: $($_.Exception.Message)","Свобода VPN",'OK','Error')
}

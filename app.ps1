# ===== Свобода VPN — клиент (sing-box) =====
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $vbs = Join-Path (Split-Path -Parent $PSCommandPath) 'run.vbs'
    if (Test-Path $vbs) { Start-Process wscript.exe -Verb RunAs -ArgumentList ('"'+$vbs+'"') }
    else { Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$PSCommandPath }
    exit
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Native {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern int SendMessage(IntPtr h, int m, int w, int l);
  [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
  [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr LoadImage(IntPtr hinst, IntPtr name, uint type, int cx, int cy, uint fuLoad);
}
"@
[void][Native]::SetProcessDPIAware()
try { [void][Native]::SetCurrentProcessExplicitAppUserModelID('Svoboda.VPN') } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System.Windows.Forms;
public class ShadowForm : Form {
  protected override CreateParams CreateParams { get { CreateParams cp = base.CreateParams; cp.ClassStyle |= 0x00020000; return cp; } }
}
"@
try { $script:scale=[Native]::GetDpiForSystem()/96.0 } catch { $script:scale=1.0 }; if($script:scale -lt 1){ $script:scale=1.0 }
function Px { param([int]$v) [int][math]::Round($v*$script:scale) }
# курсор-рука нужного размера под DPI (стоковый Cursors.Hand на system-aware рендерится крошечным)
$script:curHand=[Windows.Forms.Cursors]::Hand
try { $hc=[Native]::LoadImage([IntPtr]::Zero,[IntPtr]32649,2,[int](32*$script:scale),[int](32*$script:scale),0); if($hc -ne [IntPtr]::Zero){ $script:curHand=New-Object Windows.Forms.Cursor $hc } } catch {}

$root     = Split-Path -Parent $PSCommandPath
$cfg      = Join-Path $root 'sb-config.json'
$exe      = Join-Path $root 'sing-box.exe'
$profPath = Join-Path $root 'profiles.json'
$icoFile  = Join-Path $root 'svoboda.ico'

# --- палитра: оранжево-серо-бело-чёрная ---
$cSide      =[Drawing.Color]::FromArgb(32,33,36)
$cSideHover =[Drawing.Color]::FromArgb(48,49,54)
$cSideText  =[Drawing.Color]::FromArgb(168,170,176)
$cBg        =[Drawing.Color]::White
$cText      =[Drawing.Color]::FromArgb(24,24,27)
$cSub       =[Drawing.Color]::FromArgb(92,94,100)
$cAccent    =[Drawing.Color]::FromArgb(234,88,12)
$cAccent2   =[Drawing.Color]::FromArgb(249,115,22)
$cCard      =[Drawing.Color]::FromArgb(245,245,246)
$cBorder    =[Drawing.Color]::FromArgb(224,224,228)
$cGrey      =[Drawing.Color]::FromArgb(82,84,90)
$white      =[Drawing.Color]::White
$fFam='Segoe UI'

function F { param([single]$sz,[string]$style='Regular') New-Object Drawing.Font($fFam,$sz,[Drawing.FontStyle]::$style) }

function Write-TextNoBom($path,$text){ [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false))) }
function Load-State { Get-Content $profPath -Raw -Encoding UTF8 | ConvertFrom-Json }
function Save-State { param($s) Write-TextNoBom $profPath ($s | ConvertTo-Json -Depth 6) }
$script:state = Load-State
if(-not ($script:state.PSObject.Properties.Name -contains 'exclusions')){ $script:state | Add-Member -NotePropertyName exclusions -NotePropertyValue @() -Force }
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
    $rules=@(@{ protocol='dns'; outbound='dns-out' })
    $ex=@($script:state.exclusions) | Where-Object { "$_".Trim() }
    if($ex.Count -gt 0){ $rules += @{ domain_suffix=@($ex); outbound='direct' } }
    $conf=[ordered]@{
        log=@{ level='warn'; output=(Join-Path $root 'sb_log.txt') }
        dns=@{ servers=@(@{ tag='remote'; address='1.1.1.1'; detour='proxy' }); final='remote'; strategy='ipv4_only' }
        inbounds=@(@{ type='tun'; tag='tun-in'; interface_name='SvobodaTun'; address=@('172.18.0.1/30'); mtu=1400; auto_route=$true; strict_route=$false; stack='gvisor'; sniff=$true })
        outbounds=@( (Build-Outbound $p), @{ type='direct'; tag='direct' }, @{ type='dns'; tag='dns-out' } )
        route=@{ rules=$rules; auto_detect_interface=$true; final='proxy' }
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
        if(-not $p.fp){ $p.fp='chrome' }
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
    else { throw 'Неизвестный формат ссылки (vless / hysteria2 / tuic / trojan / ss / vmess)' }
    if(-not $name){ $name="$($p.type) $($p.server)" }
    $p.name=$name; [pscustomobject]$p
}
function Import-Subscription { param($url)
    $raw = (& curl.exe -s -m 25 -A 'Happ/1.0' "$url") 2>$null
    if(-not "$raw"){ throw 'подписка не ответила' }
    $text="$raw"
    try { $d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Pad-B64 ($text.Trim() -replace '\s','')))); if($d -match '://'){ $text=$d } } catch {}
    $new=@()
    foreach($l in ($text -split "`n")){ $l=$l.Trim(); if($l -match '://'){ try { $np=Parse-VpnLink $l; $np.sub=$true; $new+=$np } catch {} } }
    if($new.Count -eq 0){ throw 'в подписке нет серверов' }
    $new
}

function Is-Connected { [bool](Get-Process sing-box -ErrorAction SilentlyContinue) }
function Disconnect-Vpn { Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }

# ── иконки ──
function New-ShieldIcon { param($fill)
    $s=32; $bmp=New-Object Drawing.Bitmap $s,$s
    $g=[Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $pts=@(
        (New-Object Drawing.PointF([single](0.50*$s),[single](0.06*$s))),
        (New-Object Drawing.PointF([single](0.88*$s),[single](0.20*$s))),
        (New-Object Drawing.PointF([single](0.88*$s),[single](0.52*$s))),
        (New-Object Drawing.PointF([single](0.50*$s),[single](0.95*$s))),
        (New-Object Drawing.PointF([single](0.12*$s),[single](0.52*$s))),
        (New-Object Drawing.PointF([single](0.12*$s),[single](0.20*$s)))
    )
    $g.FillPolygon((New-Object Drawing.SolidBrush $fill),[Drawing.PointF[]]$pts)
    $pen=New-Object Drawing.Pen($white,[single]($s*0.10)); $pen.StartCap='Round'; $pen.EndCap='Round'; $pen.LineJoin='Round'
    $g.DrawLines($pen,[Drawing.PointF[]]@((New-Object Drawing.PointF([single](0.34*$s),[single](0.50*$s))),(New-Object Drawing.PointF([single](0.45*$s),[single](0.62*$s))),(New-Object Drawing.PointF([single](0.66*$s),[single](0.37*$s)))))
    $g.Dispose(); [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icoOn=New-ShieldIcon $cAccent; $icoOff=New-ShieldIcon ([Drawing.Color]::FromArgb(130,132,138))
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
    $p=New-Object Drawing.Drawing2D.GraphicsPath; $d=$radius*2; $w=$ctl.Width; $h=$ctl.Height
    $p.AddArc(0,0,$d,$d,180,90); $p.AddArc($w-$d,0,$d,$d,270,90); $p.AddArc($w-$d,$h-$d,$d,$d,0,90); $p.AddArc(0,$h-$d,$d,$d,90,90); $p.CloseFigure()
    $ctl.Region=New-Object Drawing.Region $p
}
function Flat { param($b,$bg,$fg) $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.BackColor=$bg; $b.ForeColor=$fg; $b.Font=(F 10 'Regular'); $b.Cursor=$script:curHand }
function Skin-List { param($lst)
    $lst.DrawMode='OwnerDrawFixed'; $lst.ItemHeight=(Px 26); $lst.BorderStyle='FixedSingle'
    $lst.Add_DrawItem({ param($s,$e)
        $sel=(($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
        $bg=if($sel){ $cAccent } else { $white }; $fg=if($sel){ $white } else { $cText }
        $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $bg),$e.Bounds)
        if($e.Index -ge 0){ $e.Graphics.DrawString([string]$s.Items[$e.Index],$s.Font,(New-Object Drawing.SolidBrush $fg),([single]($e.Bounds.X+(Px 6))),([single]($e.Bounds.Y+(Px 4)))) }
    })
}

# ===================== ОКНО =====================
$script:form=New-Object ShadowForm
$script:form.FormBorderStyle='None'; $script:form.StartPosition='CenterScreen'; $script:form.AutoScaleMode='None'
$script:form.Size=New-Object Drawing.Size((Px 880),(Px 600)); $script:form.BackColor=$cBg; $script:form.Text='Свобода VPN'; $script:form.ShowInTaskbar=$true
if(Test-Path $icoFile){ try { $script:form.Icon=New-Object Drawing.Icon $icoFile } catch {} } else { try { $script:form.Icon=$icoOn } catch {} }
$dragH={ param($s,$e) if($e.Button -eq 'Left'){ [Native]::ReleaseCapture(); [Native]::SendMessage($script:form.Handle,0xA1,0x2,0) } }

# сайдбар
$side=New-Object Windows.Forms.Panel; $side.SetBounds(0,0,(Px 220),(Px 600)); $side.BackColor=$cSide; $script:form.Controls.Add($side); $side.Add_MouseDown($dragH)
$brand=New-Object Windows.Forms.Label; $brand.Text='  Свобода VPN'; $brand.ForeColor=$white; $brand.Font=(F 15 'Bold'); $brand.SetBounds((Px 16),(Px 22),(Px 200),(Px 34)); $brand.TextAlign='MiddleLeft'; $side.Controls.Add($brand); $brand.Add_MouseDown($dragH)
$gShield=New-Glyph 0xE72E (Px 22) $cAccent  # запасной значок (lock)

# полоса активного пункта
$navStrip=New-Object Windows.Forms.Panel; $navStrip.BackColor=$cAccent; $navStrip.SetBounds(0,(Px 80),(Px 4),(Px 48)); $side.Controls.Add($navStrip)

$script:nav=@{}; $script:panels=@{}
$navDefs=@(@('home','Подключение',0xE701),@('servers','Серверы',0xE968),@('exclusions','Исключения',0xE71C),@('vk','VK-туннель',0xE717),@('settings','Настройки',0xE713))
$ny=Px 80
foreach($nd in $navDefs){
    $b=New-Object Windows.Forms.Button; $b.Text='   '+$nd[1]; $b.SetBounds((Px 4),$ny,(Px 216),(Px 48))
    $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.BackColor=$cSide; $b.ForeColor=$cSideText; $b.Font=(F 11 'Regular'); $b.TextAlign='MiddleLeft'
    $b.TextImageRelation='ImageBeforeText'; $b.ImageAlign='MiddleLeft'; $b.Padding=New-Object Windows.Forms.Padding((Px 14),0,0,0); $b.Cursor=$script:curHand
    $g=New-Glyph $nd[2] (Px 20) $cSideText; if($g){ $b.Image=$g }
    $side.Controls.Add($b); $script:nav[$nd[0]]=$b
    $ny += Px 50
}

# контент-область
$cont=New-Object Windows.Forms.Panel; $cont.SetBounds((Px 220),0,(Px 660),(Px 600)); $cont.BackColor=$cBg; $script:form.Controls.Add($cont); $cont.Add_MouseDown($dragH)
# кнопки окна
$btnClose=New-Object Windows.Forms.Button; $btnClose.Text='✕'; $btnClose.SetBounds((Px 624),(Px 8),(Px 28),(Px 26)); Flat $btnClose $cBg $cSub; $btnClose.Font=(F 11 'Regular'); $cont.Controls.Add($btnClose)
$btnMin=New-Object Windows.Forms.Button; $btnMin.Text='—'; $btnMin.SetBounds((Px 592),(Px 8),(Px 28),(Px 26)); Flat $btnMin $cBg $cSub; $btnMin.Font=(F 11 'Regular'); $cont.Controls.Add($btnMin)
$btnClose.BringToFront(); $btnMin.BringToFront()

function New-Panel {
    $p=New-Object Windows.Forms.Panel; $p.SetBounds(0,(Px 44),(Px 660),(Px 556)); $p.BackColor=$cBg; $cont.Controls.Add($p); $p
}
function Title-Label { param($p,$text) $l=New-Object Windows.Forms.Label; $l.Text=$text; $l.ForeColor=$cText; $l.Font=(F 17 'Bold'); $l.SetBounds((Px 34),(Px 10),(Px 560),(Px 36)); $p.Controls.Add($l); $l }

# ---------- HOME ----------
$pHome=New-Panel; $script:panels['home']=$pHome
[void](Title-Label $pHome 'Подключение')
$script:lblStatus=New-Object Windows.Forms.Label; $script:lblStatus.SetBounds((Px 34),(Px 70),(Px 580),(Px 30)); $script:lblStatus.Font=(F 14 'Bold'); $script:lblStatus.TextAlign='MiddleCenter'; $pHome.Controls.Add($script:lblStatus)
$script:btnConn=New-Object Windows.Forms.Button; $script:btnConn.SetBounds((Px 240),(Px 120),(Px 170),(Px 170)); $script:btnConn.FlatStyle='Flat'; $script:btnConn.FlatAppearance.BorderSize=0; $script:btnConn.ForeColor=$white; $script:btnConn.Font=(F 13 'Bold')
$script:btnConn.TextImageRelation='ImageAboveText'; $script:btnConn.ImageAlign='MiddleCenter'; $script:btnConn.TextAlign='MiddleCenter'; $script:btnConn.Cursor=$script:curHand
$gPow=New-Glyph 0xE7E8 (Px 48) $white; if($gPow){ $script:btnConn.Image=$gPow; $script:btnConn.Padding=New-Object Windows.Forms.Padding(0,(Px 20),0,0) }
$pHome.Controls.Add($script:btnConn)
$script:lblSrv=New-Object Windows.Forms.Label; $script:lblSrv.SetBounds((Px 34),(Px 310),(Px 580),(Px 24)); $script:lblSrv.Font=(F 11 'Regular'); $script:lblSrv.ForeColor=$cText; $script:lblSrv.TextAlign='MiddleCenter'; $pHome.Controls.Add($script:lblSrv)
$script:lblIp=New-Object Windows.Forms.Label; $script:lblIp.SetBounds((Px 34),(Px 336),(Px 580),(Px 22)); $script:lblIp.Font=(F 10 'Regular'); $script:lblIp.ForeColor=$cSub; $script:lblIp.TextAlign='MiddleCenter'; $pHome.Controls.Add($script:lblIp)
$lnkSrv=New-Object Windows.Forms.Button; $lnkSrv.Text='Сменить сервер'; $lnkSrv.SetBounds((Px 255),(Px 372),(Px 140),(Px 30)); Flat $lnkSrv $cBg $cAccent; $lnkSrv.Font=(F 10 'Regular'); $pHome.Controls.Add($lnkSrv)

# ---------- SERVERS ----------
$pSrv=New-Panel; $pSrv.Visible=$false; $script:panels['servers']=$pSrv
[void](Title-Label $pSrv 'Серверы')
$lI=New-Object Windows.Forms.Label; $lI.Text='Вставь ссылку (vless / hysteria2 / tuic / trojan / ss / vmess):'; $lI.ForeColor=$cSub; $lI.Font=(F 9 'Regular'); $lI.SetBounds((Px 34),(Px 56),(Px 580),(Px 16)); $pSrv.Controls.Add($lI)
$script:tbImp=New-Object Windows.Forms.TextBox; $script:tbImp.SetBounds((Px 34),(Px 74),(Px 470),(Px 28)); $script:tbImp.BorderStyle='FixedSingle'; $script:tbImp.Font=(F 10 'Regular'); $script:tbImp.ForeColor=$cText; $pSrv.Controls.Add($script:tbImp)
$bImp=New-Object Windows.Forms.Button; $bImp.Text='Добавить'; $bImp.SetBounds((Px 512),(Px 74),(Px 110),(Px 28)); Flat $bImp $cAccent $white; $bImp.Font=(F 10 'Bold'); $pSrv.Controls.Add($bImp)
$script:lblSrvMsg=New-Object Windows.Forms.Label; $script:lblSrvMsg.SetBounds((Px 34),(Px 106),(Px 588),(Px 18)); $script:lblSrvMsg.Font=(F 9 'Regular'); $script:lblSrvMsg.ForeColor=$cSub; $pSrv.Controls.Add($script:lblSrvMsg)
$script:lstSrv=New-Object Windows.Forms.ListBox; $script:lstSrv.SetBounds((Px 34),(Px 128),(Px 588),(Px 120)); $script:lstSrv.BorderStyle='FixedSingle'; $script:lstSrv.Font=(F 10 'Regular'); $script:lstSrv.ForeColor=$cText; $pSrv.Controls.Add($script:lstSrv); Skin-List $script:lstSrv
$bUse=New-Object Windows.Forms.Button; $bUse.Text='Подключиться к выбранному'; $bUse.SetBounds((Px 34),(Px 256),(Px 280),(Px 34)); Flat $bUse $cAccent $white; $bUse.Font=(F 10 'Bold'); $pSrv.Controls.Add($bUse)
$bDel=New-Object Windows.Forms.Button; $bDel.Text='Удалить'; $bDel.SetBounds((Px 324),(Px 256),(Px 130),(Px 34)); Flat $bDel $cCard $cText; $bDel.Font=(F 10 'Regular'); $pSrv.Controls.Add($bDel)
# редактор (продвинутый)
$script:edPanel=New-Object Windows.Forms.Panel; $script:edPanel.SetBounds((Px 34),(Px 300),(Px 600),(Px 250)); $script:edPanel.AutoScroll=$true; $script:edPanel.BackColor=$cBg; $pSrv.Controls.Add($script:edPanel)
$script:fields=@{}; $script:combos=@{}; $py=0
foreach($f in @(@('name','Название'),@('server','IP / домен'),@('port','Порт'),@('uuid','UUID (vless/vmess/tuic)'),@('password','Пароль (trojan/ss/hy2/tuic)'),@('sni','SNI (пусто = без SNI)'),@('reality_pbk','Reality pbk'),@('reality_sid','Reality sid'))){
    $lb=New-Object Windows.Forms.Label; $lb.Text=$f[1]; $lb.ForeColor=$cSub; $lb.Font=(F 9 'Regular'); $lb.SetBounds((Px 2),$py,(Px 560),(Px 15)); $script:edPanel.Controls.Add($lb)
    $tb=New-Object Windows.Forms.TextBox; $tb.SetBounds((Px 2),($py+(Px 16)),(Px 560),(Px 25)); $tb.BorderStyle='FixedSingle'; $tb.Font=(F 10 'Regular'); $tb.ForeColor=$cText; $script:edPanel.Controls.Add($tb)
    $script:fields[$f[0]]=$tb; $py+=Px 46
}
foreach($cs in @(@('type','Протокол',@('vless','vmess','trojan','shadowsocks','hysteria2','tuic')),@('fp','uTLS отпечаток',@('','chrome','firefox','safari','edge','ios','random')),@('flow','Flow',@('','xtls-rprx-vision')),@('transport','Транспорт',@('tcp','grpc','ws','httpupgrade')),@('method','Метод (ss)',@('','2022-blake3-aes-256-gcm','aes-256-gcm','chacha20-ietf-poly1305')))){
    $lb=New-Object Windows.Forms.Label; $lb.Text=$cs[1]; $lb.ForeColor=$cSub; $lb.Font=(F 9 'Regular'); $lb.SetBounds((Px 2),$py,(Px 560),(Px 15)); $script:edPanel.Controls.Add($lb)
    $cb=New-Object Windows.Forms.ComboBox; $cb.SetBounds((Px 2),($py+(Px 16)),(Px 560),(Px 25)); $cb.DropDownStyle='DropDownList'; $cb.FlatStyle='Flat'; $cb.Font=(F 10 'Regular'); $cb.ForeColor=$cText; foreach($it in $cs[2]){ [void]$cb.Items.Add($it) }; $script:edPanel.Controls.Add($cb)
    $script:combos[$cs[0]]=$cb; $py+=Px 46
}
$script:chkIns=New-Object Windows.Forms.CheckBox; $script:chkIns.Text='Не проверять сертификат (insecure)'; $script:chkIns.ForeColor=$cText; $script:chkIns.Font=(F 9 'Regular'); $script:chkIns.SetBounds((Px 2),$py,(Px 560),(Px 22)); $script:edPanel.Controls.Add($script:chkIns); $py+=Px 26
$script:chkMux=New-Object Windows.Forms.CheckBox; $script:chkMux.Text='Mux — мультиплекс'; $script:chkMux.ForeColor=$cText; $script:chkMux.Font=(F 9 'Regular'); $script:chkMux.SetBounds((Px 2),$py,(Px 560),(Px 22)); $script:edPanel.Controls.Add($script:chkMux); $py+=Px 26
$bSave=New-Object Windows.Forms.Button; $bSave.Text='Сохранить изменения'; $bSave.SetBounds((Px 2),$py,(Px 240),(Px 32)); Flat $bSave $cGrey $white; $bSave.Font=(F 10 'Bold'); $script:edPanel.Controls.Add($bSave)

# ---------- EXCLUSIONS ----------
$pEx=New-Panel; $pEx.Visible=$false; $script:panels['exclusions']=$pEx
[void](Title-Label $pEx 'Исключения')
$lE=New-Object Windows.Forms.Label; $lE.Text='Эти сайты пойдут НАПРЯМУЮ, в обход VPN (банки, госуслуги и т.п.). Указывай домен: gosuslugi.ru'; $lE.ForeColor=$cSub; $lE.Font=(F 9 'Regular'); $lE.SetBounds((Px 34),(Px 56),(Px 588),(Px 32)); $pEx.Controls.Add($lE)
$script:tbEx=New-Object Windows.Forms.TextBox; $script:tbEx.SetBounds((Px 34),(Px 92),(Px 470),(Px 28)); $script:tbEx.BorderStyle='FixedSingle'; $script:tbEx.Font=(F 10 'Regular'); $script:tbEx.ForeColor=$cText; $pEx.Controls.Add($script:tbEx)
$bExAdd=New-Object Windows.Forms.Button; $bExAdd.Text='Добавить'; $bExAdd.SetBounds((Px 512),(Px 92),(Px 110),(Px 28)); Flat $bExAdd $cAccent $white; $bExAdd.Font=(F 10 'Bold'); $pEx.Controls.Add($bExAdd)
$script:lstEx=New-Object Windows.Forms.ListBox; $script:lstEx.SetBounds((Px 34),(Px 128),(Px 588),(Px 330)); $script:lstEx.BorderStyle='FixedSingle'; $script:lstEx.Font=(F 10 'Regular'); $script:lstEx.ForeColor=$cText; $pEx.Controls.Add($script:lstEx); Skin-List $script:lstEx
$bExDel=New-Object Windows.Forms.Button; $bExDel.Text='Удалить выбранный'; $bExDel.SetBounds((Px 34),(Px 466),(Px 200),(Px 34)); Flat $bExDel $cCard $cText; $bExDel.Font=(F 10 'Regular'); $pEx.Controls.Add($bExDel)

# ---------- VK ----------
$pVk=New-Panel; $pVk.Visible=$false; $script:panels['vk']=$pVk
[void](Title-Label $pVk 'VK-туннель')
$lV=New-Object Windows.Forms.Label; $lV.Text='Резервный обход на случай, когда провайдер режет даже VLESS/Reality (строгий белый список).'+[Environment]::NewLine+'Нажми «Запустить» — модуль откроется прямо здесь, в окне приложения (ниже).'; $lV.ForeColor=$cSub; $lV.Font=(F 10 'Regular'); $lV.SetBounds((Px 34),(Px 60),(Px 588),(Px 60)); $pVk.Controls.Add($lV)
$bVk=New-Object Windows.Forms.Button; $bVk.Text='Запустить VK-туннель'; $bVk.SetBounds((Px 34),(Px 130),(Px 240),(Px 38)); Flat $bVk $cAccent $white; $bVk.Font=(F 11 'Bold'); $pVk.Controls.Add($bVk)
$script:lblVk=New-Object Windows.Forms.Label; $script:lblVk.SetBounds((Px 34),(Px 176),(Px 588),(Px 20)); $script:lblVk.Font=(F 9 'Regular'); $script:lblVk.ForeColor=$cSub; $pVk.Controls.Add($script:lblVk)
$script:vkHost=New-Object Windows.Forms.Panel; $script:vkHost.SetBounds((Px 34),(Px 204),(Px 590),(Px 338)); $script:vkHost.BackColor=$cCard; $pVk.Controls.Add($script:vkHost)

# ---------- SETTINGS ----------
$pSet=New-Panel; $pSet.Visible=$false; $script:panels['settings']=$pSet
[void](Title-Label $pSet 'Настройки')
$lblMode2=New-Object Windows.Forms.Label; $lblMode2.Text='Режим интерфейса'; $lblMode2.ForeColor=$cText; $lblMode2.Font=(F 10 'Bold'); $lblMode2.SetBounds((Px 34),(Px 60),(Px 400),(Px 20)); $pSet.Controls.Add($lblMode2)
$script:chkAdv=New-Object Windows.Forms.CheckBox; $script:chkAdv.Text='Продвинутый (показывать все настройки сервера)'; $script:chkAdv.ForeColor=$cText; $script:chkAdv.Font=(F 10 'Regular'); $script:chkAdv.SetBounds((Px 34),(Px 84),(Px 560),(Px 24)); $pSet.Controls.Add($script:chkAdv)
$lblSub2=New-Object Windows.Forms.Label; $lblSub2.Text='Подписка (авто-обновление списка серверов)'; $lblSub2.ForeColor=$cText; $lblSub2.Font=(F 10 'Bold'); $lblSub2.SetBounds((Px 34),(Px 128),(Px 400),(Px 20)); $pSet.Controls.Add($lblSub2)
$script:tbSub=New-Object Windows.Forms.TextBox; $script:tbSub.SetBounds((Px 34),(Px 152),(Px 470),(Px 28)); $script:tbSub.BorderStyle='FixedSingle'; $script:tbSub.Font=(F 10 'Regular'); $script:tbSub.ForeColor=$cText; $pSet.Controls.Add($script:tbSub)
$bSub=New-Object Windows.Forms.Button; $bSub.Text='Обновить'; $bSub.SetBounds((Px 512),(Px 152),(Px 110),(Px 28)); Flat $bSub $cGrey $white; $bSub.Font=(F 10 'Bold'); $pSet.Controls.Add($bSub)
$script:lblSubMsg=New-Object Windows.Forms.Label; $script:lblSubMsg.SetBounds((Px 34),(Px 184),(Px 588),(Px 18)); $script:lblSubMsg.Font=(F 9 'Regular'); $script:lblSubMsg.ForeColor=$cSub; $pSet.Controls.Add($script:lblSubMsg)
$lblAbout=New-Object Windows.Forms.Label; $lblAbout.Text='Свобода VPN · движок sing-box · для личного использования. VPN автоматически включается при входе в Windows.'; $lblAbout.ForeColor=$cSub; $lblAbout.Font=(F 9 'Regular'); $lblAbout.SetBounds((Px 34),(Px 230),(Px 588),(Px 40)); $pSet.Controls.Add($lblAbout)

# ── подключение (неблокирующее) ──
$script:sync=[hashtable]::Synchronized(@{ checking=$false; ip='' })
$script:connState='off'
function Cleanup-Check { try { if($script:connPS){ $script:connPS.Dispose() } } catch {}; try { if($script:connRS){ $script:connRS.Close(); $script:connRS.Dispose() } } catch {}; $script:connPS=$null; $script:connRS=$null }
function Start-Check {
    $script:sync.checking=$true; $script:sync.ip=''
    $script:connRS=[runspacefactory]::CreateRunspace(); $script:connRS.Open(); $script:connRS.SessionStateProxy.SetVariable('sync',$script:sync)
    $script:connPS=[powershell]::Create(); $script:connPS.Runspace=$script:connRS
    [void]$script:connPS.AddScript({ Start-Sleep -Seconds 4; $ip=''; for($i=0;$i -lt 4;$i++){ $r=(& curl.exe -s -m 6 https://api.ipify.org) 2>$null; if($r){ $ip="$r".Trim(); break }; Start-Sleep -Seconds 1 }; $sync.ip=$ip; $sync.checking=$false })
    [void]$script:connPS.BeginInvoke()
}
function Set-Status { param($text,$color) $script:lblStatus.Text=$text; $script:lblStatus.ForeColor=$color }
function Update-UI {
    switch($script:connState){
        'on'     { $script:btnConn.Text='Отключить'; $script:btnConn.BackColor=$cGrey; Set-Status '● Подключено' $cAccent; $script:tray.Icon=$icoOn; $script:tray.Text='Свобода VPN — подключено' }
        'trying' { $script:btnConn.Text='Отмена'; $script:btnConn.BackColor=$cAccent2; $script:tray.Icon=$icoOff; $script:tray.Text='Свобода VPN — подключение…' }
        default  { $script:btnConn.Text='Подключить'; $script:btnConn.BackColor=$cAccent; Set-Status '● Отключено' $cSub; $script:lblIp.Text=''; $script:tray.Icon=$icoOff; $script:tray.Text='Свобода VPN — отключено' }
    }
}
function Try-Server {
    $idx=$script:connQueue[$script:connPos]
    $script:state.active=$idx
    $p=$script:state.profiles[$idx]; $script:lblSrv.Text=$p.name
    Set-Status $(if($script:connAttempt -eq 1){'Подключаюсь…'}else{'Переподключаюсь…'}) $cAccent2
    Write-SbConfig $p
    Disconnect-Vpn; Start-Sleep -Milliseconds 250
    Start-Process -FilePath $exe -ArgumentList 'run','-c',$cfg -WorkingDirectory $root -WindowStyle Hidden
    Start-Check
}
function Start-Connect {
    if($script:connState -eq 'trying'){ return }
    $n=$script:state.profiles.Count
    if($n -eq 0){ Show-Panel 'servers'; $script:lblSrvMsg.Text='Сначала добавь сервер — вставь ссылку выше.'; $script:lblSrvMsg.ForeColor=$cAccent; return }
    $a=[int]$script:state.active; if($a -lt 0 -or $a -ge $n){ $a=0 }
    $script:connQueue=@($a)+@(0..($n-1)|Where-Object{$_ -ne $a}); $script:connPos=0; $script:connAttempt=1; $script:connState='trying'
    Update-UI
    Try-Server; $script:connTimer.Start()
}
$script:connTimer=New-Object Windows.Forms.Timer; $script:connTimer.Interval=400
$script:connTimer.Add_Tick({
    if($script:connState -ne 'trying'){ $script:connTimer.Stop(); return }
    if($script:sync.checking){ return }
    $idx=$script:connQueue[$script:connPos]
    if($script:sync.ip){
        $script:connTimer.Stop(); Cleanup-Check; $script:connState='on'; Update-UI
        $script:lblIp.Text="IP: $($script:sync.ip)"; $script:lblIp.ForeColor=$cAccent
        $script:state | Add-Member -NotePropertyName everConnected -NotePropertyValue $true -Force; Save-State $script:state; return
    }
    Cleanup-Check
    if($script:connAttempt -lt 2){ $script:connAttempt++; Try-Server; return }
    $script:connPos++; $script:connAttempt=1
    if($script:connPos -lt $script:connQueue.Count){ Try-Server; return }
    $script:connTimer.Stop(); $script:connState='off'; Disconnect-Vpn; Update-UI
    Set-Status 'Не удалось подключиться' $cAccent
})
function Do-Disconnect { $script:connTimer.Stop(); Cleanup-Check; $script:connState='off'; Disconnect-Vpn; Start-Sleep -Milliseconds 150; $script:lblSrv.Text=''; Update-UI }

# ── списки ──
function Fill-Servers { $script:lstSrv.Items.Clear(); foreach($p in $script:state.profiles){ [void]$script:lstSrv.Items.Add($p.name) }; if($script:state.profiles.Count -gt 0){ $i=[int]$script:state.active; if($i -ge 0 -and $i -lt $script:state.profiles.Count){ $script:lstSrv.SelectedIndex=$i } } }
function Fill-Excl { $script:lstEx.Items.Clear(); foreach($d in @($script:state.exclusions)){ if("$d".Trim()){ [void]$script:lstEx.Items.Add($d) } } }
function Fill-Editor { param($p)
    foreach($k in @($script:fields.Keys)){ $script:fields[$k].Text="$($p.$k)" }
    foreach($k in @($script:combos.Keys)){ $script:combos[$k].SelectedItem="$($p.$k)"; if($script:combos[$k].SelectedIndex -lt 0){ $script:combos[$k].SelectedIndex=0 } }
    $script:chkIns.Checked=[bool]$p.insecure; $script:chkMux.Checked=[bool]$p.mux
}
function Apply-Mode { $adv=[bool]$script:state.advanced; $script:edPanel.Visible=$adv; $script:chkAdv.Checked=$adv }

# ===================== ТРЕЙ =====================
$script:tray=New-Object Windows.Forms.NotifyIcon; $script:tray.Icon=$icoOff; $script:tray.Visible=$true; $script:tray.Text='Свобода VPN'
$menu=New-Object Windows.Forms.ContextMenuStrip
$miOpen=$menu.Items.Add('Открыть'); $miConn=$menu.Items.Add('Подключить'); $miDisc=$menu.Items.Add('Отключить'); [void]$menu.Items.Add('-'); $miExit=$menu.Items.Add('Выход')
$script:tray.ContextMenuStrip=$menu
function Show-Window { $script:form.Show(); $script:form.WindowState='Normal'; $script:form.Activate() }

function Show-Panel { param($name)
    foreach($n in @('home','servers','exclusions','vk','settings')){ if($script:panels[$n]){ $script:panels[$n].Visible=($n -eq $name) } }
    foreach($n in $script:nav.Keys){ if($n -eq $name){ $script:nav[$n].BackColor=$cSideHover; $script:nav[$n].ForeColor=$white } else { $script:nav[$n].BackColor=$cSide; $script:nav[$n].ForeColor=$cSideText } }
    if($script:nav[$name]){ $navStrip.Top=$script:nav[$name].Top; $navStrip.Visible=$true }
    if($name -eq 'servers'){ Fill-Servers; Apply-Mode }
    if($name -eq 'exclusions'){ Fill-Excl }
    if($name -eq 'home'){ Update-UI; if($script:state.profiles.Count -gt 0 -and -not $script:lblSrv.Text){ $i=[int]$script:state.active; if($i -ge 0 -and $i -lt $script:state.profiles.Count){ $script:lblSrv.Text=$script:state.profiles[$i].name } } }
}

# ===================== ОБРАБОТЧИКИ =====================
foreach($n in @('home','servers','exclusions','vk','settings')){ $nn=$n; $script:nav[$n].Add_Click({ Show-Panel $nn }.GetNewClosure()) }
$btnMin.Add_Click({ $script:form.Hide() })
$btnClose.Add_Click({ $script:form.Hide() })
$lnkSrv.Add_Click({ Show-Panel 'servers' })
$script:btnConn.Add_Click({ if($script:connState -eq 'off'){ Start-Connect } else { Do-Disconnect } })

$bImp.Add_Click({
    $t=$script:tbImp.Text.Trim(); if(-not $t){ return }
    try { $np=Parse-VpnLink $t; $arr=@($script:state.profiles); $arr+=$np; $script:state.profiles=$arr; $script:state.active=$arr.Count-1; Save-State $script:state; $script:tbImp.Text=''; Fill-Servers; $script:lblSrvMsg.Text="Добавлен: $($np.name)"; $script:lblSrvMsg.ForeColor=$cAccent }
    catch { $script:lblSrvMsg.Text="Не разобрал ссылку: $($_.Exception.Message)"; $script:lblSrvMsg.ForeColor=$cAccent }
})
$script:lstSrv.Add_SelectedIndexChanged({ if($script:lstSrv.SelectedIndex -ge 0){ $script:state.active=$script:lstSrv.SelectedIndex; Save-State $script:state; Fill-Editor $script:state.profiles[$script:lstSrv.SelectedIndex] } })
$bUse.Add_Click({ if($script:lstSrv.SelectedIndex -ge 0){ $script:state.active=$script:lstSrv.SelectedIndex; Save-State $script:state }; Show-Panel 'home'; Start-Connect })
$bDel.Add_Click({
    $i=$script:lstSrv.SelectedIndex; if($i -lt 0){ return }
    $new=@(); for($k=0;$k -lt $script:state.profiles.Count;$k++){ if($k -ne $i){ $new+=$script:state.profiles[$k] } }
    $script:state.profiles=$new; if([int]$script:state.active -ge $new.Count){ $script:state.active=0 }; Save-State $script:state; Fill-Servers; $script:lblSrvMsg.Text='Удалён.'; $script:lblSrvMsg.ForeColor=$cSub
})
$bSave.Add_Click({
    $i=$script:lstSrv.SelectedIndex
    $np=[pscustomobject](New-Profile)
    foreach($k in @($script:fields.Keys)){ if($k -eq 'port'){ $np.port=[int]("0"+$script:fields['port'].Text) } else { $np.$k=$script:fields[$k].Text } }
    foreach($k in @($script:combos.Keys)){ $np.$k="$($script:combos[$k].SelectedItem)" }
    $np.insecure=$script:chkIns.Checked; $np.mux=$script:chkMux.Checked
    if($np.port -le 0){ $np.port=443 }
    $arr=@($script:state.profiles); if($i -ge 0){ $np.sub=[bool]$arr[$i].sub; $arr[$i]=$np } else { $arr+=$np }
    $script:state.profiles=$arr; Save-State $script:state; Fill-Servers; $script:lblSrvMsg.Text="Сохранено: $($np.name)"; $script:lblSrvMsg.ForeColor=$cAccent
})
$bExAdd.Add_Click({
    $d=$script:tbEx.Text.Trim() -replace '^https?://','' -replace '/.*$',''
    if(-not $d){ return }
    $ex=@(@($script:state.exclusions) + $d | Where-Object { "$_".Trim() } | Select-Object -Unique)
    $script:state.exclusions=$ex; Save-State $script:state; $script:tbEx.Text=''; Fill-Excl
    if(Is-Connected){ Write-SbConfig (Active-Profile) }
})
$bExDel.Add_Click({
    $i=$script:lstEx.SelectedIndex; if($i -lt 0){ return }
    $ex=@($script:state.exclusions); $new=@(); for($k=0;$k -lt $ex.Count;$k++){ if($k -ne $i){ $new+=$ex[$k] } }
    $script:state.exclusions=$new; Save-State $script:state; Fill-Excl
})
$bVk.Add_Click({
    if($script:pwProc -and -not $script:pwProc.HasExited){ $script:lblVk.Text='VK-туннель уже запущен (ниже).'; $script:lblVk.ForeColor=$cSub; return }
    $pw=Join-Path $root 'PWDTT.exe'
    if(-not (Test-Path $pw)){ $script:lblVk.Text='Модуль PWDTT.exe не найден рядом с приложением.'; $script:lblVk.ForeColor=$cAccent; return }
    $script:lblVk.Text='Запускаю VK-туннель…'; $script:lblVk.ForeColor=$cSub; $script:lblVk.Refresh()
    try { $script:pwProc=Start-Process -FilePath $pw -PassThru } catch { $script:lblVk.Text="Не удалось запустить: $($_.Exception.Message)"; $script:lblVk.ForeColor=$cAccent; return }
    $h=[IntPtr]::Zero
    for($i=0;$i -lt 60;$i++){ Start-Sleep -Milliseconds 100; [Windows.Forms.Application]::DoEvents(); try { $script:pwProc.Refresh(); $h=$script:pwProc.MainWindowHandle } catch {}; if($h -ne [IntPtr]::Zero){ break } }
    if($h -ne [IntPtr]::Zero){
        try {
            [void][Native]::SetParent($h,$script:vkHost.Handle)
            $st=[Native]::GetWindowLong($h,-16); $st=$st -band (-bnot 0x00C00000) -band (-bnot 0x00040000); [void][Native]::SetWindowLong($h,-16,$st)
            [void][Native]::MoveWindow($h,0,0,$script:vkHost.Width,$script:vkHost.Height,$true)
            [void][Native]::ShowWindow($h,5)
            $script:lblVk.Text='VK-туннель встроен в окно (ниже). Управление — здесь.'; $script:lblVk.ForeColor=$cSub
        } catch { $script:lblVk.Text='VK-туннель запущен в отдельном окне.'; $script:lblVk.ForeColor=$cSub }
    } else { $script:lblVk.Text='VK-туннель запущен в отдельном окне (встроить не удалось).'; $script:lblVk.ForeColor=$cSub }
})
$script:chkAdv.Add_CheckedChanged({ $script:state | Add-Member -NotePropertyName advanced -NotePropertyValue ([bool]$script:chkAdv.Checked) -Force; Save-State $script:state; Apply-Mode })
$bSub.Add_Click({
    $url=$script:tbSub.Text.Trim(); if(-not $url){ return }
    try { $subs=Import-Subscription $url; $manual=@($script:state.profiles | Where-Object { -not $_.sub }); $script:state.profiles=@($manual+$subs); $script:state | Add-Member -NotePropertyName subscription -NotePropertyValue $url -Force; $script:state.active=0; Save-State $script:state; $script:lblSubMsg.Text="Загружено серверов: $($subs.Count)"; $script:lblSubMsg.ForeColor=$cAccent }
    catch { $script:lblSubMsg.Text="Ошибка: $($_.Exception.Message)"; $script:lblSubMsg.ForeColor=$cAccent }
})

$miOpen.Add_Click({ Show-Window }); $script:tray.Add_MouseDoubleClick({ Show-Window })
$miConn.Add_Click({ if($script:connState -eq 'off'){ Start-Connect } })
$miDisc.Add_Click({ Do-Disconnect })
$miExit.Add_Click({ $script:exiting=$true; try { $script:connTimer.Stop(); Cleanup-Check } catch {}; try { if($script:pwProc -and -not $script:pwProc.HasExited){ $script:pwProc.Kill() } } catch {}; Disconnect-Vpn; $script:tray.Visible=$false; [Windows.Forms.Application]::Exit() })
$script:form.Add_FormClosing({ param($s,$e) if(-not $script:exiting){ $e.Cancel=$true; $script:form.Hide() } })

$script:form.Add_Shown({ Set-RoundRegion $script:btnConn (Px 18) })
if("$($script:state.subscription)"){ $script:tbSub.Text="$($script:state.subscription)" }
Show-Panel 'home'
$script:form.Show(); $script:form.Activate()
# авто-подключения нет — пользователь жмёт кнопку сам
$ctx=New-Object Windows.Forms.ApplicationContext
[Windows.Forms.Application]::Run($ctx)

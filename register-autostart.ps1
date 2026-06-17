param([switch]$Remove)
$ErrorActionPreference = 'SilentlyContinue'
$name = 'SvobodaVPN'
if ($Remove) { Unregister-ScheduledTask -TaskName $name -Confirm:$false; exit }
$app = Join-Path $PSScriptRoot 'app.ps1'
$arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $app + '"'
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$t = New-ScheduledTaskTrigger -AtLogOn
$p = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest -LogonType Interactive
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $name -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null

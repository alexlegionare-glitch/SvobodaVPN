param([switch]$Remove)
$ErrorActionPreference = 'SilentlyContinue'
$name = 'SvobodaVPN'
if ($Remove) { Unregister-ScheduledTask -TaskName $name -Confirm:$false; exit }
$vbs = Join-Path $PSScriptRoot 'run.vbs'
$a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
$t = New-ScheduledTaskTrigger -AtLogOn
$p = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest -LogonType Interactive
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $name -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null

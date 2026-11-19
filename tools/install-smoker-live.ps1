# Deli Planner - install the 5-minute smoker live feed on Eli's PC. Needs the FOOD.LOG sync installed first.
$dir = Join-Path $env:ProgramData "DeliPlanner"
if (-not (Test-Path (Join-Path $dir "config.json"))) { Write-Host "Install the FOOD.LOG sync first (install-foodlog-sync.ps1)." -ForegroundColor Red; Read-Host "Press Enter to close"; exit 1 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$live = Join-Path $dir "FOODLOG-live.ps1"
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/yehudabcode/deli-planner/main/tools/FOODLOG-live.ps1" -OutFile $live

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$live`""
$trigger   = New-ScheduledTaskTrigger -Daily -At 12:00am
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At 12:00am -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Register-ScheduledTask -TaskName "Deli Planner smoker live" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Scheduled: every 5 minutes, day and night, while this user is signed in." -ForegroundColor Green
Write-Host ""
Write-Host "Sending the first live update now..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $live
Write-Host ""
Write-Host "Take a photo of this window and send it back." -ForegroundColor Yellow
Read-Host "Press Enter to close"

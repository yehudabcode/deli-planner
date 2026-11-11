# Deli Planner - install the hourly FOOD.LOG sync on this PC (Eli's PC, where FOOD.LOG runs).
# Run once. It does not change FOOD.LOG.

$dir = Join-Path $env:ProgramData "DeliPlanner"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host "Deli Planner - FOOD.LOG sync setup" -ForegroundColor Cyan
Write-Host "Paste the same API address and device key used in the planner's Settings."
$url = (Read-Host "API address (ends in /exec)").Trim()
if ($url -notmatch '^https://script\.google\.com/macros/s/[^/]+/exec$') { Write-Host "That doesn't look right. It must start https://script.google.com/macros/s/ and end /exec" -ForegroundColor Red; Read-Host "Press Enter to close"; exit 1 }
$key = (Read-Host "Device key").Trim()
@{ url = $url; key = $key } | ConvertTo-Json | Set-Content -Path (Join-Path $dir "config.json") -Encoding UTF8

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$sync = Join-Path $dir "FOODLOG-sync.ps1"
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/yehudabcode/deli-planner/main/tools/FOODLOG-sync.ps1" -OutFile $sync

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sync`""
$trigger   = New-ScheduledTaskTrigger -Daily -At 6:00am
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At 6:00am -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 17)).Repetition
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Register-ScheduledTask -TaskName "Deli Planner FOOD.LOG sync" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Scheduled: every hour 06:00-23:00 while this user is signed in." -ForegroundColor Green

Write-Host ""
Write-Host "Running the first sync now (can take a minute)..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sync -show
Write-Host ""
Write-Host "Take a photo of this window and send it back." -ForegroundColor Yellow
Read-Host "Press Enter to close"

# Deli Planner - FOOD.LOG sync
# READ ONLY on FOOD.LOG: it only runs SELECT queries. It never changes the FOOD.LOG database.
# Sends the last 21 days of smokehouse cycles (start, end, program, min/max chamber, core, humidity)
# to the Deli Planner Google Sheet. Runs every hour from Windows Task Scheduler.
# Also works out, for cycles from the last 3 days, the longest time (minutes) the CORE stayed at or above
# each temperature from 55 to 90 °C, so the planner can check "core >= 72 °C for 6 min" hold times.

$ErrorActionPreference = "Stop"
$dir = Join-Path $env:ProgramData "DeliPlanner"
$log = Join-Path $dir "sync.log"
function Log($t) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $t"; Add-Content -Path $log -Value $line; Write-Host $t }

try {
    $cfg = Get-Content (Join-Path $dir "config.json") -Raw | ConvertFrom-Json
    $days = 21
    $sql = @"
SELECT e.Id, e.StartTime, e.EndTime, e.Info, e.RecipeNumber, e.Completed, e.ErrorCode, e.EventLogDiscr,
  MIN(CASE WHEN v.Channel = 1 THEN v.Value END) AS c1min, MAX(CASE WHEN v.Channel = 1 THEN v.Value END) AS c1max,
  MIN(CASE WHEN v.Channel = 2 THEN v.Value END) AS c2min, MAX(CASE WHEN v.Channel = 2 THEN v.Value END) AS c2max,
  MIN(CASE WHEN v.Channel = 3 THEN v.Value END) AS c3min, MAX(CASE WHEN v.Channel = 3 THEN v.Value END) AS c3max,
  COUNT(DISTINCT m.MeasurementId) AS n
FROM dbo.EventLog e
LEFT JOIN dbo.Measurements m ON e.EventLogDiscr = 1 AND m.ControlUnitFk = e.ControlUnitFK
  AND m.TimeStamp >= e.StartTime AND m.TimeStamp <= ISNULL(e.EndTime, SYSDATETIME())
LEFT JOIN dbo.AnalogMeasurementValues v ON v.MeasurementFk = m.MeasurementId AND v.Channel IN (1, 2, 3)
WHERE e.StartTime >= DATEADD(day, -$days, SYSDATETIME())
GROUP BY e.Id, e.StartTime, e.EndTime, e.Info, e.RecipeNumber, e.Completed, e.ErrorCode, e.EventLogDiscr
ORDER BY e.StartTime
"@
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=localhost\FOODLOGSERVER;Database=FoodDB;Integrated Security=True;Connect Timeout=20;Application Name=DeliPlannerSync"
    $cn.Open()
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300
    $t = New-Object System.Data.DataTable
    [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($t)

    # Core readings (channel 2) for cooking cycles of the last 3 days, for hold times
    $sqlCore = @"
SELECT e.Id, m.TimeStamp, v.Value
FROM dbo.EventLog e
JOIN dbo.Measurements m ON m.ControlUnitFk = e.ControlUnitFK
  AND m.TimeStamp >= e.StartTime AND m.TimeStamp <= ISNULL(e.EndTime, SYSDATETIME())
JOIN dbo.AnalogMeasurementValues v ON v.MeasurementFk = m.MeasurementId AND v.Channel = 2
WHERE e.EventLogDiscr = 1 AND e.StartTime >= DATEADD(day, -3, SYSDATETIME())
ORDER BY e.Id, m.TimeStamp
"@
    $cmd2 = $cn.CreateCommand(); $cmd2.CommandText = $sqlCore; $cmd2.CommandTimeout = 300
    $tc = New-Object System.Data.DataTable
    [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd2).Fill($tc)
    $cn.Close()

    # Longest unbroken run (minutes) with core >= T, for T = 55..90. A gap of more than 90 s between readings breaks the run.
    $holds = @{}
    $byId = @{}
    foreach ($r in $tc.Rows) { $k = [int]$r.Id; if (-not $byId.ContainsKey($k)) { $byId[$k] = New-Object System.Collections.Generic.List[object] }; $byId[$k].Add(@([datetime]$r.TimeStamp, [double]$r.Value)) }
    foreach ($k in $byId.Keys) {
        $rd = $byId[$k]; $res = [ordered]@{}
        for ($thr = 55; $thr -le 90; $thr++) {
            $best = 0.0; $runStart = $null; $prev = $null
            foreach ($p in $rd) {
                $ok = $p[1] -ge $thr
                if ($ok -and $runStart -ne $null -and $prev -ne $null -and ($p[0] - $prev).TotalSeconds -gt 90) { $runStart = $null }
                if ($ok) { if ($runStart -eq $null) { $runStart = $p[0] }; $len = ($p[0] - $runStart).TotalMinutes + 0.5; if ($len -gt $best) { $best = $len } }
                else { $runStart = $null }
                $prev = $p[0]
            }
            if ($best -le 0) { break }
            $res["$thr"] = [math]::Round($best, 1)
        }
        $holds[$k] = $res
    }

    function D($v) { if ($v -is [DBNull] -or $v -eq $null) { return $null }; return ([datetime]$v).ToString("yyyy-MM-ddTHH:mm:ss") }
    function N($v) { if ($v -is [DBNull] -or $v -eq $null) { return $null }; return [math]::Round([double]$v, 2) }
    $cooks = @()
    foreach ($r in $t.Rows) {
        $cooks += [ordered]@{
            id = [int]$r.Id; start = (D $r.StartTime); end = (D $r.EndTime); program = ([string]$r.Info).Trim()
            recipe = (N $r.RecipeNumber); completed = ($r.Completed -eq $true); error = (N $r.ErrorCode); type = [int]$r.EventLogDiscr
            c1min = (N $r.c1min); c1max = (N $r.c1max); c2min = (N $r.c2min); c2max = (N $r.c2max); c3min = (N $r.c3min); c3max = (N $r.c3max)
            n = [int]$r.n
            hold = $(if ($holds.ContainsKey([int]$r.Id)) { $holds[[int]$r.Id] } else { $null })
        }
    }

    $body = @{ action = "cooks"; key = $cfg.key; cooks = $cooks } | ConvertTo-Json -Depth 4 -Compress
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res = Invoke-RestMethod -Uri $cfg.url -Method Post -ContentType "text/plain; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    if (-not $res.ok) { throw "Planner refused the data: $($res.code)" }
    Log "OK: $($cooks.Count) cycles sent (new $($res.result.added), updated $($res.result.updated)), hold times for $($holds.Count)"

    if ($args -contains "-show") {
        Write-Host ""
        Write-Host "Start               End       Program                         Chamber min-max   Core min-max   Humidity min-max   Core >=72 / >=60 (min)"
        foreach ($c in $cooks) {
            if ($c.type -ne 1) { Write-Host ("{0}  {1,-8}  {2}" -f $c.start.Replace("T"," "), "", "ALARM/EVENT: " + $c.program); continue }
            Write-Host (("{0}  {1,-8}  {2,-30}  {3,6} - {4,-6}   {5,5} - {6,-5}   {7,5} - {8,-5}" -f $c.start.Replace("T"," "), ("$($c.end)".Split("T")[-1]), $c.program, $c.c1min, $c.c1max, $c.c2min, $c.c2max, $c.c3min, $c.c3max) + $(if ($c.hold) { "   " + $c.hold["72"] + " / " + $c.hold["60"] } else { "" }))
        }
    }
} catch {
    Log "FAILED: $($_.Exception.Message)"
    if ($args -contains "-show") { Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}

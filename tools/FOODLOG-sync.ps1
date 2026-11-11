# Deli Planner - FOOD.LOG sync
# READ ONLY on FOOD.LOG: it only runs SELECT queries. It never changes the FOOD.LOG database.
# Sends the last 21 days of smokehouse cycles (start, end, program, min/max chamber, core, humidity)
# to the Deli Planner Google Sheet. Runs every hour from Windows Task Scheduler.

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
    $cn.Close()

    function D($v) { if ($v -is [DBNull] -or $v -eq $null) { return $null }; return ([datetime]$v).ToString("yyyy-MM-ddTHH:mm:ss") }
    function N($v) { if ($v -is [DBNull] -or $v -eq $null) { return $null }; return [math]::Round([double]$v, 2) }
    $cooks = @()
    foreach ($r in $t.Rows) {
        $cooks += [ordered]@{
            id = [int]$r.Id; start = (D $r.StartTime); end = (D $r.EndTime); program = ([string]$r.Info).Trim()
            recipe = (N $r.RecipeNumber); completed = ($r.Completed -eq $true); error = (N $r.ErrorCode); type = [int]$r.EventLogDiscr
            c1min = (N $r.c1min); c1max = (N $r.c1max); c2min = (N $r.c2min); c2max = (N $r.c2max); c3min = (N $r.c3min); c3max = (N $r.c3max)
            n = [int]$r.n
        }
    }

    $body = @{ action = "cooks"; key = $cfg.key; cooks = $cooks } | ConvertTo-Json -Depth 4 -Compress
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res = Invoke-RestMethod -Uri $cfg.url -Method Post -ContentType "text/plain; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    if (-not $res.ok) { throw "Planner refused the data: $($res.code)" }
    Log "OK: $($cooks.Count) cycles sent (new $($res.result.added), updated $($res.result.updated))"

    if ($args -contains "-show") {
        Write-Host ""
        Write-Host "Start               End       Program                         Chamber min-max   Core min-max   Humidity min-max"
        foreach ($c in $cooks) {
            if ($c.type -ne 1) { Write-Host ("{0}  {1,-8}  {2}" -f $c.start.Replace("T"," "), "", "ALARM/EVENT: " + $c.program); continue }
            Write-Host ("{0}  {1,-8}  {2,-30}  {3,6} - {4,-6}   {5,5} - {6,-5}   {7,5} - {8,-5}" -f $c.start.Replace("T"," "), ("$($c.end)".Split("T")[-1]), $c.program, $c.c1min, $c.c1max, $c.c2min, $c.c2max, $c.c3min, $c.c3max)
        }
    }
} catch {
    Log "FAILED: $($_.Exception.Message)"
    if ($args -contains "-show") { Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}

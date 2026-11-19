# Deli Planner - smoker live feed. READ ONLY on FOOD.LOG (SELECT queries only).
# Every 5 minutes: current/recent cycles, current step, last 6 hours of readings and recent alarms -> planner.

$ErrorActionPreference = "Stop"
$dir = Join-Path $env:ProgramData "DeliPlanner"
$log = Join-Path $dir "live.log"
function Log($t) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $t"; Add-Content -Path $log -Value $line; Write-Host $t }
function D($v) { if ($v -is [DBNull] -or $v -eq $null) { return $null }; return ([datetime]$v).ToString("yyyy-MM-ddTHH:mm:ss") }
function N($v) { if ($v -is [DBNull] -or $v -eq $null) { return $null }; return [math]::Round([double]$v, 1) }

try {
    $cfg = Get-Content (Join-Path $dir "config.json") -Raw | ConvertFrom-Json
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=localhost\FOODLOGSERVER;Database=FoodDB;Integrated Security=True;Connect Timeout=20;Application Name=DeliPlannerLive"
    $cn.Open()
    function Q($sql) { $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120; $t = New-Object System.Data.DataTable; [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($t); return ,$t }

    $cyc = Q @"
SELECT TOP 6 e.Id, e.StartTime, e.EndTime, e.Info,
  (SELECT MAX(v.Value) FROM dbo.Measurements m JOIN dbo.AnalogMeasurementValues v ON v.MeasurementFk = m.MeasurementId AND v.Channel = 2
     WHERE m.ControlUnitFk = e.ControlUnitFK AND m.TimeStamp >= e.StartTime AND m.TimeStamp <= ISNULL(e.EndTime, SYSDATETIME())) AS coreMax,
  (SELECT MAX(v.Value) FROM dbo.Measurements m JOIN dbo.AnalogMeasurementValues v ON v.MeasurementFk = m.MeasurementId AND v.Channel = 1
     WHERE m.ControlUnitFk = e.ControlUnitFK AND m.TimeStamp >= e.StartTime AND m.TimeStamp <= ISNULL(e.EndTime, SYSDATETIME())) AS chMax
FROM dbo.EventLog e WHERE e.EventLogDiscr = 1 ORDER BY e.StartTime DESC
"@
    $cycles = @()
    foreach ($r in $cyc.Rows) { $cycles += [ordered]@{ id = [int]$r.Id; start = (D $r.StartTime); end = (D $r.EndTime); program = ([string]$r.Info).Trim(); coreMax = (N $r.coreMax); chMax = (N $r.chMax) } }

    $step = $null
    $run = $cycles | Where-Object { -not $_.end } | Select-Object -First 1
    if ($run) {
        $s = Q "SELECT TOP 1 Info, StartTime FROM dbo.PreparationStepLog WHERE EventLogFK = $($run.id) AND PrepStepDiscr = 1 ORDER BY StartTime DESC"
        if ($s.Rows.Count) { $step = [ordered]@{ name = ([string]$s.Rows[0].Info).Trim(); start = (D $s.Rows[0].StartTime) } }
    }

    $ser = Q @"
SELECT m.MeasurementId, m.TimeStamp, v.Channel, v.Value FROM dbo.Measurements m
JOIN dbo.AnalogMeasurementValues v ON v.MeasurementFk = m.MeasurementId AND v.Channel IN (1, 2, 3)
WHERE m.TimeStamp >= DATEADD(hour, -6, SYSDATETIME()) ORDER BY m.TimeStamp
"@
    $byId = [ordered]@{}
    foreach ($r in $ser.Rows) {
        $k = [string]$r.MeasurementId
        if (-not $byId.Contains($k)) { $byId[$k] = [ordered]@{ t = (D $r.TimeStamp); ch = $null; core = $null; hum = $null } }
        switch ([int]$r.Channel) { 1 { $byId[$k].ch = (N $r.Value) } 2 { $byId[$k].core = (N $r.Value) } 3 { $byId[$k].hum = (N $r.Value) } }
    }
    $all = @($byId.Values)
    $series = @(); for ($i = 0; $i -lt $all.Count; $i += 6) { $series += $all[$i] }   # one point every ~3 minutes
    $latest = if ($all.Count) { $all[$all.Count - 1] } else { $null }
    if ($latest -and $series.Count -and $series[$series.Count - 1].t -ne $latest.t) { $series += $latest }

    $al = Q "SELECT TOP 10 Id, StartTime, Info, ErrorCode FROM dbo.EventLog WHERE EventLogDiscr <> 1 AND StartTime >= DATEADD(hour, -48, SYSDATETIME()) ORDER BY StartTime DESC"
    $alarms = @(); foreach ($r in $al.Rows) { $alarms += [ordered]@{ id = [int]$r.Id; start = (D $r.StartTime); info = ([string]$r.Info).Trim(); error = (N $r.ErrorCode) } }
    $cn.Close()

    $live = [ordered]@{ at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss"); latest = $latest; step = $step; cycles = $cycles; series = $series; alarms = $alarms }
    $body = @{ action = "live"; key = $cfg.key; live = $live } | ConvertTo-Json -Depth 6 -Compress
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res = Invoke-RestMethod -Uri $cfg.url -Method Post -ContentType "text/plain; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    if (-not $res.ok) { throw "Planner refused the data: $($res.code)" }
    $msg = "OK: latest " + $(if ($latest) { "$($latest.t) chamber $($latest.ch) core $($latest.core) hum $($latest.hum)" } else { "no readings in last 6h" }) + $(if ($run) { " | running: $($run.program)" } else { "" })
    if ((Get-Item $log -ErrorAction SilentlyContinue).Length -gt 1MB) { Remove-Item $log }
    Log $msg
} catch {
    Log "FAILED: $($_.Exception.Message)"
    exit 1
}

# Deli Planner - smoker live feed. READ ONLY on FOOD.LOG (SELECT queries only).
# Every 5 minutes: current/recent cycles, current step, last 6 hours of readings and recent alarms -> planner.
# Also (24 Nov 2026): step X of N, step set time and time so far, set points (channels 1001 chamber, 1002 core,
# 1003 humidity), what the current step switches on, the steps still to come and the smoker's details.
# Times are worked out on FOOD.LOG's own clock (the latest reading), which can differ from the PC clock.

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
SELECT TOP 6 e.Id, e.StartTime, e.EndTime, e.Info, e.RecipeNumber,
  (SELECT MAX(v.Value) FROM dbo.Measurements m JOIN dbo.AnalogMeasurementValues v ON v.MeasurementFk = m.MeasurementId AND v.Channel = 2
     WHERE m.ControlUnitFk = e.ControlUnitFK AND m.TimeStamp >= e.StartTime AND m.TimeStamp <= ISNULL(e.EndTime, SYSDATETIME())) AS coreMax,
  (SELECT MAX(v.Value) FROM dbo.Measurements m JOIN dbo.AnalogMeasurementValues v ON v.MeasurementFk = m.MeasurementId AND v.Channel = 1
     WHERE m.ControlUnitFk = e.ControlUnitFK AND m.TimeStamp >= e.StartTime AND m.TimeStamp <= ISNULL(e.EndTime, SYSDATETIME())) AS chMax
FROM dbo.EventLog e WHERE e.EventLogDiscr = 1 ORDER BY e.StartTime DESC
"@
    $cycles = @()
    foreach ($r in $cyc.Rows) { $cycles += [ordered]@{ id = [int]$r.Id; start = (D $r.StartTime); end = (D $r.EndTime); program = ([string]$r.Info).Trim(); recipeNo = (N $r.RecipeNumber); coreMax = (N $r.coreMax); chMax = (N $r.chMax) } }

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

    # ---- full monitoring panel ----
    $nowT = $null
    $lm = Q "SELECT TOP 1 m.MeasurementId, m.TimeStamp FROM dbo.Measurements m ORDER BY m.MeasurementId DESC"
    $setp = [ordered]@{ ch = $null; core = $null; hum = $null }
    if ($lm.Rows.Count) {
        $nowT = [datetime]$lm.Rows[0].TimeStamp
        $sv = Q "SELECT Channel, Value FROM dbo.AnalogMeasurementValues WHERE MeasurementFk = $([long]$lm.Rows[0].MeasurementId) AND Channel IN (1001, 1002, 1003)"
        foreach ($r in $sv.Rows) { switch ([int]$r.Channel) { 1001 { $setp.ch = (N $r.Value) } 1002 { $setp.core = (N $r.Value) } 1003 { $setp.hum = (N $r.Value) } } }
    }
    $panel = $null
    if ($run -and $nowT) {
        $rid = $run.id
        $logged = Q "SELECT StepNumber, Info, StartTime FROM dbo.PreparationStepLog WHERE EventLogFK = $rid AND PrepStepDiscr = 1 ORDER BY StartTime"
        $cur = if ($logged.Rows.Count) { $logged.Rows[$logged.Rows.Count - 1] } else { $null }
        # the program (recipe) being run: same name, not deleted; otherwise the controller program number
        $nm = ($run.program -replace "'", "''")
        $rec = Q "SELECT TOP 1 Id FROM dbo.Recipes WHERE IsDeleted = 0 AND LTRIM(RTRIM(Name)) = LTRIM(RTRIM(N'$nm')) ORDER BY LastModified DESC"
        if (-not $rec.Rows.Count -and $run.recipeNo -ne $null) { $rec = Q "SELECT TOP 1 Id FROM dbo.Recipes WHERE IsDeleted = 0 AND Position = $([int]$run.recipeNo) ORDER BY LastModified DESC" }
        $steps = @()
        if ($rec.Rows.Count) {
            $recId = [int]$rec.Rows[0].Id
            $ps = Q "SELECT Id, Step, Name FROM dbo.PreparationSteps WHERE RecipeFK = $recId ORDER BY Step"
            $args2 = Q "SELECT a.PreparationStepFK, a.BaseProgramParameter, a.AnalogValue, a.DigitalValue FROM dbo.BaseProgramArguments a JOIN dbo.PreparationSteps p ON p.Id = a.PreparationStepFK WHERE p.RecipeFK = $recId"
            $names = Q "SELECT BaseProgramNumber, MAX(Info) AS Info FROM dbo.PreparationStepLog WHERE PrepStepDiscr = 1 AND BaseProgramNumber IS NOT NULL GROUP BY BaseProgramNumber"
            $nameOf = @{}; foreach ($r in $names.Rows) { $nameOf[[int]$r.BaseProgramNumber] = ([string]$r.Info).Trim() }
            foreach ($p in $ps.Rows) {
                $prm = [ordered]@{}; $on = @()
                foreach ($a in $args2.Rows) {
                    if ([int]$a.PreparationStepFK -ne [int]$p.Id) { continue }
                    $k = [string]$a.BaseProgramParameter
                    if ($a.DigitalValue -isnot [DBNull]) { if ([bool]$a.DigitalValue -and $k -like 'Enable*') { $on += $k.Substring(6) } }
                    elseif ($a.AnalogValue -isnot [DBNull]) { $prm[$k] = [math]::Round([double]$a.AnalogValue, 1) }
                }
                $bp = $null; if ([string]$p.Name -match '(\d+)$') { $bp = [int]$matches[1] }
                $steps += [ordered]@{ n = [int]$p.Step; name = $(if ($bp -ne $null -and $nameOf.ContainsKey($bp)) { $nameOf[$bp] } else { [string]$p.Name }); min = $prm['stepTime']; ch = $prm['ChamberTemp']; core = $prm['CoreTemp']; on = $on }
            }
        }
        $curNo = if ($cur) { [int]$cur.StepNumber } else { 0 }
        $curStart = if ($cur) { [datetime]$cur.StartTime } else { [datetime]$run.start }
        $stepElapsed = [math]::Round(($nowT - $curStart).TotalMinutes, 1)
        $curDef = $steps | Where-Object { $_.n -eq $curNo } | Select-Object -First 1
        $left = $null
        if ($steps.Count) {
            $later = @($steps | Where-Object { $_.n -gt $curNo })
            if ($curDef -and $curDef.min -ne $null -and -not ($later | Where-Object { $_.min -eq $null })) {
                $sumLater = 0.0; foreach ($x in $later) { $sumLater += [double]$x.min }
                $left = [math]::Max(0, $curDef.min - $stepElapsed) + $sumLater
                $left = [math]::Round($left, 0)
            }
        }
        $panel = [ordered]@{
            now = $nowT.ToString("yyyy-MM-ddTHH:mm:ss"); stepNo = $curNo + 1; steps = $steps.Count
            stepName = $(if ($cur) { ([string]$cur.Info).Trim() } else { $null }); stepStart = $curStart.ToString("yyyy-MM-ddTHH:mm:ss")
            stepSet = $(if ($curDef) { $curDef.min } else { $null }); stepElapsed = $stepElapsed
            runElapsed = [math]::Round(($nowT - [datetime]$run.start).TotalMinutes, 1); left = $left
            on = @(if ($curDef) { $curDef.on }); set = $setp
            next = @($steps | Where-Object { $_.n -gt $curNo } | ForEach-Object { [ordered]@{ n = $_.n + 1; name = $_.name; min = $_.min; ch = $_.ch } })
        }
    }
    $dev = $null
    $du = Q "SELECT TOP 1 u.Name, u.BaseType, u.HardwareId, u.IpAddress, (SELECT TOP 1 MetadataVersion FROM dbo.ControlUnitMetadata) AS Ver FROM dbo.ControlUnits u WHERE u.IsActive = 1"
    if ($du.Rows.Count) { $r = $du.Rows[0]; $dev = [ordered]@{ name = [string]$r.Name; type = [string]$r.BaseType; hw = [string]$r.HardwareId; ip = [string]$r.IpAddress; ver = [string]$r.Ver } }

    $al = Q "SELECT TOP 10 Id, StartTime, Info, ErrorCode FROM dbo.EventLog WHERE EventLogDiscr <> 1 AND StartTime >= DATEADD(hour, -48, SYSDATETIME()) ORDER BY StartTime DESC"
    $alarms = @(); foreach ($r in $al.Rows) { $alarms += [ordered]@{ id = [int]$r.Id; start = (D $r.StartTime); info = ([string]$r.Info).Trim(); error = (N $r.ErrorCode) } }
    $cn.Close()

    $live = [ordered]@{ at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss"); latest = $latest; step = $step; panel = $panel; set = $setp; device = $dev; cycles = $cycles; series = $series; alarms = $alarms }
    $body = @{ action = "live"; key = $cfg.key; live = $live } | ConvertTo-Json -Depth 6 -Compress
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res = Invoke-RestMethod -Uri $cfg.url -Method Post -ContentType "text/plain; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    if (-not $res.ok) { throw "Planner refused the data: $($res.code)" }
    $msg = "OK: latest " + $(if ($latest) { "$($latest.t) chamber $($latest.ch) core $($latest.core) hum $($latest.hum)" } else { "no readings in last 6h" }) + $(if ($run) { " | running: $($run.program)" + $(if ($panel) { " step $($panel.stepNo)/$($panel.steps) $($panel.stepName) $($panel.stepElapsed)/$($panel.stepSet) min, set $($setp.ch)" } else { "" }) } else { "" })
    if ((Get-Item $log -ErrorAction SilentlyContinue).Length -gt 1MB) { Remove-Item $log }
    Log $msg
} catch {
    Log "FAILED: $($_.Exception.Message)"
    exit 1
}

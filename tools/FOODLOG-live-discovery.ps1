# FOOD.LOG live-screen discovery - READ ONLY (SELECT queries only; changes nothing)
# Run WHILE a smoker program is running. Finds where FOOD.LOG keeps set points, step number,
# step times and time left, so the Smoker phone page can show the full Monitoring screen.
# Output: foodlog_live_discovery.txt on the Desktop. Send that file back.

$out = Join-Path ([Environment]::GetFolderPath("Desktop")) "foodlog_live_discovery.txt"
$lines = New-Object System.Collections.Generic.List[string]
function Say($t) { $lines.Add([string]$t); Write-Host $t }
$cn = New-Object System.Data.SqlClient.SqlConnection "Server=localhost\FOODLOGSERVER;Database=FoodDB;Integrated Security=True;Connect Timeout=20;Application Name=DeliPlannerDiscovery"
$cn.Open()
function Q($sql) { $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120; $t = New-Object System.Data.DataTable; [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($t); return ,$t }
function Dump($title, $sql) {
    Say ""; Say "=== $title"
    try {
        $t = Q $sql
        if (-not $t.Rows.Count) { Say "  (no rows)"; return }
        foreach ($r in $t.Rows) {
            $vals = foreach ($c in $t.Columns) { $v = [string]$r[$c.ColumnName]; if ($v.Length -gt 120) { $v = $v.Substring(0,120) + "..." }; "$($c.ColumnName)=$v" }
            Say ("  " + ($vals -join " | "))
        }
    } catch { Say "  (failed: $($_.Exception.Message))" }
}

Say "FOOD.LOG live discovery  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  PC: $env:COMPUTERNAME"

Dump "Tables and row counts" @"
SELECT t.name AS tbl, SUM(p.rows) AS rows_ FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY t.name ORDER BY t.name
"@

Dump "Columns that look like set points, steps, times or programs" @"
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE '%Set%' OR COLUMN_NAME LIKE '%Nominal%' OR COLUMN_NAME LIKE '%Target%' OR COLUMN_NAME LIKE '%Desired%'
   OR COLUMN_NAME LIKE '%Step%' OR COLUMN_NAME LIKE '%Duration%' OR COLUMN_NAME LIKE '%Remain%' OR COLUMN_NAME LIKE '%Rest%'
   OR COLUMN_NAME LIKE '%Program%' OR COLUMN_NAME LIKE '%Recipe%' OR COLUMN_NAME LIKE '%Phase%' OR COLUMN_NAME LIKE '%Digital%'
   OR COLUMN_NAME LIKE '%State%' OR COLUMN_NAME LIKE '%Status%'
ORDER BY TABLE_NAME, ORDINAL_POSITION
"@

Dump "Running cycle (EventLog, all columns)" "SELECT TOP 2 * FROM dbo.EventLog WHERE EventLogDiscr = 1 ORDER BY StartTime DESC"
$run = Q "SELECT TOP 1 Id FROM dbo.EventLog WHERE EventLogDiscr = 1 ORDER BY StartTime DESC"
$rid = if ($run.Rows.Count) { [int]$run.Rows[0].Id } else { 0 }
Dump "Steps logged for that cycle (PreparationStepLog, all columns)" "SELECT * FROM dbo.PreparationStepLog WHERE EventLogFK = $rid ORDER BY StartTime"

Dump "Latest reading: every analog channel" @"
SELECT v.* FROM dbo.AnalogMeasurementValues v
WHERE v.MeasurementFk = (SELECT MAX(MeasurementId) FROM dbo.Measurements) ORDER BY v.Channel
"@
Dump "Latest reading row (Measurements, all columns)" "SELECT TOP 2 * FROM dbo.Measurements ORDER BY MeasurementId DESC"
Dump "Channels ever recorded (last 24h)" @"
SELECT v.Channel, COUNT(*) AS n, MIN(v.Value) AS mn, MAX(v.Value) AS mx FROM dbo.AnalogMeasurementValues v
JOIN dbo.Measurements m ON m.MeasurementId = v.MeasurementFk WHERE m.TimeStamp >= DATEADD(hour, -24, SYSDATETIME())
GROUP BY v.Channel ORDER BY v.Channel
"@

# Any other table holding values for the latest measurement (e.g. digital outputs: heating, smoke, steam)
$fk = Q "SELECT c.TABLE_NAME, c.COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.COLUMN_NAME LIKE 'Measurement%F%k' AND c.TABLE_NAME <> 'AnalogMeasurementValues'"
foreach ($r in $fk.Rows) { Dump "Latest reading in $($r.TABLE_NAME)" "SELECT TOP 20 * FROM dbo.[$($r.TABLE_NAME)] WHERE [$($r.COLUMN_NAME)] = (SELECT MAX(MeasurementId) FROM dbo.Measurements)" }

# Sample rows from every small table whose name suggests programs/recipes/steps/set points
$tabs = Q "SELECT name FROM sys.tables WHERE name LIKE '%Program%' OR name LIKE '%Recipe%' OR name LIKE '%Step%' OR name LIKE '%Set%' OR name LIKE '%Phase%' OR name LIKE '%Digital%' OR name LIKE '%Unit%' OR name LIKE '%Channel%'"
foreach ($r in $tabs.Rows) { Dump "Sample: $($r.name)" "SELECT TOP 15 * FROM dbo.[$($r.name)]" }

$cn.Close()
$lines | Set-Content -Path $out -Encoding UTF8
Write-Host ""; Write-Host "Done. Saved to $out" -ForegroundColor Green
Read-Host "Press Enter to close"

# FOOD.LOG database discovery - READ ONLY
# Lists the FOOD.LOG databases, tables, columns and 3 sample rows per table.
# It does not change, delete or write anything in FOOD.LOG.
# Output: foodlog_schema.txt on the Desktop. Send that file back.

$out    = Join-Path ([Environment]::GetFolderPath("Desktop")) "foodlog_schema.txt"
$server = "localhost\FOODLOGSERVER"
$lines  = New-Object System.Collections.Generic.List[string]
function Say($t) { $lines.Add([string]$t); Write-Host $t }

function Q($db, $sql) {
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=$db;Integrated Security=True;Connect Timeout=15"
    $cn.Open()
    try {
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $t = New-Object System.Data.DataTable; [void]$da.Fill($t); return ,$t
    } finally { $cn.Close() }
}

Say "FOOD.LOG discovery  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  PC: $env:COMPUTERNAME  User: $env:USERNAME"
Say ""

try {
    $dbs = Q "master" "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name"
    Say "Connected with Windows login. Databases:"
    $dbs | ForEach-Object { Say "  - $($_.name)" }
} catch {
    Say "COULD NOT CONNECT with Windows login: $($_.Exception.Message)"
    Say ""
    Say "Looking for FOOD.LOG connection settings (passwords hidden)..."
    $roots = @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData", "$env:APPDATA", "$env:LOCALAPPDATA") | Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $roots) {
        Get-ChildItem $r -Recurse -Include *.config,*.xml,*.json,*.ini -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match 'FOOD|Fessmann|SIO|Smart' } |
          Select-String -Pattern 'Data Source|Server=|Initial Catalog|Database=' -ErrorAction SilentlyContinue |
          ForEach-Object { Say ("  " + $_.Path + " : " + ($_.Line.Trim() -replace '(?i)(password|pwd)\s*=\s*[^;"]*', '$1=*****')) }
    }
    $lines | Set-Content -Path $out -Encoding UTF8
    Write-Host ""; Write-Host "Saved to $out" -ForegroundColor Yellow
    Read-Host "Press Enter to close"; exit
}

foreach ($db in $dbs) {
    $d = $db.name
    Say ""; Say "==================== DATABASE: $d ===================="
    try {
        $tables = Q $d @"
SELECT s.name AS sch, t.name AS tbl, SUM(p.rows) AS rows_
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY s.name, t.name ORDER BY s.name, t.name
"@
        foreach ($t in $tables) {
            $full = "[$($t.sch)].[$($t.tbl)]"
            Say ""; Say "--- TABLE $full   rows: $($t.rows_)"
            $cols = Q $d "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$($t.sch)' AND TABLE_NAME='$($t.tbl)' ORDER BY ORDINAL_POSITION"
            Say ("    columns: " + (($cols | ForEach-Object { "$($_.COLUMN_NAME) ($($_.DATA_TYPE))" }) -join ", "))
            if ($t.rows_ -gt 0) {
                try {
                    $s = Q $d "SELECT TOP 3 * FROM $full"
                    foreach ($row in $s.Rows) {
                        $vals = foreach ($c in $s.Columns) { $v = [string]$row[$c.ColumnName]; if ($v.Length -gt 60) { $v = $v.Substring(0,60) + "..." }; "$($c.ColumnName)=$v" }
                        Say ("    sample: " + ($vals -join " | "))
                    }
                } catch { Say "    (sample failed: $($_.Exception.Message))" }
            }
        }
    } catch { Say "  (could not read $d : $($_.Exception.Message))" }
}

$lines | Set-Content -Path $out -Encoding UTF8
Write-Host ""; Write-Host "Done. Saved to $out" -ForegroundColor Green
Read-Host "Press Enter to close"

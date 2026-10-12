# Run a read-only DAX query against the model currently open in Power BI Desktop.
# Power BI Desktop hosts the model in a local Analysis Services instance; its port is
# written to msmdsrv.port.txt in the workspace folder. Prints {port, database, rows} as JSON.
#
# Usage: powershell -File scripts/dax_query.ps1 -AdomdDll <path> -Query "EVALUATE ROW(""x"", [Total Orders])"
# The ADOMD.NET client DLL comes from Microsoft's NuGet package
# Microsoft.AnalysisServices.AdomdClient.retail.amd64 (lib/net45) - see powerbi/README.md.
param([Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)][string]$AdomdDll)
$ErrorActionPreference = 'Stop'
Add-Type -Path $AdomdDll
$roots = @("$env:LOCALAPPDATA\Microsoft\Power BI Desktop\AnalysisServicesWorkspaces",
           "$env:USERPROFILE\Microsoft\Power BI Desktop Store App\AnalysisServicesWorkspaces")
$ws = Get-ChildItem $roots -Recurse -Filter msmdsrv.port.txt -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $ws) { throw "No running Power BI Desktop model found (msmdsrv.port.txt missing)." }
$port = ([IO.File]::ReadAllText($ws.FullName, [Text.Encoding]::Unicode)).Trim()
$conn = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection("Data Source=localhost:$port")
$conn.Open()
$db = $conn.GetSchemaDataSet("DBSCHEMA_CATALOGS", $null).Tables[0].Rows[0]["CATALOG_NAME"]
$conn.ChangeDatabase($db)
$cmd = $conn.CreateCommand(); $cmd.CommandText = $Query
$r = $cmd.ExecuteReader()
$rows = @()
while ($r.Read()) {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $r.FieldCount; $i++) { $o[$r.GetName($i)] = $r.GetValue($i) }
    $rows += [pscustomobject]$o
}
$r.Close(); $conn.Close()
[pscustomobject]@{ port = $port; database = $db; rows = $rows } | ConvertTo-Json -Depth 4 -Compress

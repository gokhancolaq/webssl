param(
    [string]$CentralUrl = "http://192.168.254.90:8080",
    [string]$AgentToken = "changeme-token"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$headers = @{ "X-Agent-Token" = $AgentToken }

Get-ChildItem (Join-Path $root "samples\ingest-*.json") | ForEach-Object {
    $body = [System.IO.File]::ReadAllBytes($_.FullName)
    $response = Invoke-RestMethod -Method Post -Uri ($CentralUrl.TrimEnd("/") + "/api/ingest") -Headers $headers -ContentType "application/json; charset=utf-8" -Body $body
    Write-Output ("Gonderildi {0}: {1} bindings={2}" -f $_.Name, $response.hostname, $response.bindings)
}

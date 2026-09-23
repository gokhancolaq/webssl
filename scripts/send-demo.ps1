param(
    [string]$CentralUrl,
    [string]$AgentToken
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not $CentralUrl) {
    $ip = Read-Host "Dashboard IP veya hostname"
    if (-not $ip) { throw "IP / hostname boş olamaz." }
    $port = Read-Host "Dashboard port [8080]"
    if (-not $port) { $port = "8080" }
    $CentralUrl = "http://${ip}:${port}"
}
if (-not $AgentToken) {
    $AgentToken = Read-Host "Agent token"
    if (-not $AgentToken) { throw "Agent token boş olamaz." }
}

$headers = @{ "X-Agent-Token" = $AgentToken }

Get-ChildItem (Join-Path $root "samples\ingest-*.json") | ForEach-Object {
    $body = [System.IO.File]::ReadAllBytes($_.FullName)
    $response = Invoke-RestMethod -Method Post -Uri ($CentralUrl.TrimEnd("/") + "/api/ingest") -Headers $headers -ContentType "application/json; charset=utf-8" -Body $body
    Write-Output ("Gonderildi {0}: {1} bindings={2}" -f $_.Name, $response.hostname, $response.bindings)
}

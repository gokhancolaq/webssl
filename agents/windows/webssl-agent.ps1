#Requires -Version 5.1
<#
.SYNOPSIS
    Collects IIS site bindings and SSL certificate expiry, then posts them to WEBSSL.
#>
[CmdletBinding()]
param(
    [string]$CentralUrl = $env:CENTRAL_URL,
    [string]$AgentToken = $env:AGENT_TOKEN,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
$AgentVersion = "1.0.0"

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptRoot) { $ScriptRoot = "C:\ProgramData\WEBSSL\agent" }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot "agent.config.json" }

if (Test-Path $ConfigPath) {
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    if (-not $CentralUrl -and $config.CentralUrl) { $CentralUrl = $config.CentralUrl }
    if (-not $AgentToken -and $config.AgentToken) { $AgentToken = $config.AgentToken }
}

$LogPath = Join-Path $ScriptRoot "agent.log"
function Write-AgentLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

if (-not $CentralUrl) { throw "CENTRAL_URL or agent.config.json CentralUrl is required." }
if (-not $AgentToken) { throw "AGENT_TOKEN or agent.config.json AgentToken is required." }

function Convert-ToIso {
    param([Nullable[datetime]]$Value)
    if ($null -eq $Value) { return $null }
    return ([datetime]$Value).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-SanNames {
    param($Certificate)
    $names = @()
    try {
        $ext = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" }
        if ($ext) {
            $text = $ext.Format($false)
            foreach ($part in ($text -split "[,\r\n]+")) {
                $clean = $part.Trim()
                if ($clean -match "DNS Name=(.+)$") { $names += $Matches[1].Trim() }
                elseif ($clean -match "^DNS:(.+)$") { $names += $Matches[1].Trim() }
            }
        }
    } catch {
        # SAN is optional
    }
    return $names
}

function Get-CertByThumbprint {
    param([string]$Thumbprint)
    if (-not $Thumbprint) { return $null }
    $clean = ($Thumbprint -replace "\s", "").ToUpperInvariant()
    foreach ($storeName in @("My", "WebHosting")) {
        $path = "Cert:\LocalMachine\$storeName\$clean"
        if (Test-Path $path) {
            return Get-Item $path
        }
    }
    return Get-ChildItem -Path Cert:\LocalMachine\My, Cert:\LocalMachine\WebHosting -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $clean } |
        Select-Object -First 1
}

function Get-SslMap {
    $map = @{}
    if (-not (Test-Path IIS:\SslBindings)) { return $map }
    Get-ChildItem IIS:\SslBindings -ErrorAction SilentlyContinue | ForEach-Object {
        $ip = if ($_.IPAddress -and $_.IPAddress.IPAddressToString) { $_.IPAddress.IPAddressToString } else { "*" }
        if ($ip -eq "0.0.0.0") { $ip = "*" }
        $hostName = ""
        if ($_.PSObject.Properties.Name -contains "Host" -and $_.Host) { $hostName = [string]$_.Host }
        $key = "{0}|{1}|{2}" -f $ip, $_.Port, $hostName.ToLowerInvariant()
        $map[$key] = $_.Thumbprint
        $anyKey = "*|{0}|{1}" -f $_.Port, $hostName.ToLowerInvariant()
        if (-not $map.ContainsKey($anyKey)) { $map[$anyKey] = $_.Thumbprint }
    }
    return $map
}

function Resolve-Thumbprint {
    param($Binding, $SslMap, [string]$Ip, [int]$Port, [string]$HostName)
    if ($Binding.certificateHash) { return $Binding.certificateHash }
    $hostKey = $HostName.ToLowerInvariant()
    foreach ($key in @(
            "{0}|{1}|{2}" -f $Ip, $Port, $hostKey,
            "*|{0}|{1}" -f $Port, $hostKey,
            "{0}|{1}|" -f $Ip, $Port,
            "*|{0}|" -f $Port
        )) {
        if ($SslMap.ContainsKey($key)) { return $SslMap[$key] }
    }
    return $null
}

$ingestUrl = $CentralUrl.TrimEnd("/") + "/api/ingest"
Write-AgentLog "Basladi. Hedef=$ingestUrl"

try {
    $health = Invoke-RestMethod -Method Get -Uri ($CentralUrl.TrimEnd("/") + "/api/health")
    Write-AgentLog ("Dashboard health OK: {0}" -f $health.time)
} catch {
    Write-AgentLog ("Dashboard ULASILAMIYOR: {0}" -f $_.Exception.Message)
    throw "Dashboard'a ulasilamiyor ($CentralUrl). Windows sunucusundan port 8080 acik mi, ufw/firewall?"
}

if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    throw "WebAdministration yok. IIS Management Scripts and Tools kurun."
}
Import-Module WebAdministration -ErrorAction Stop

$sslMap = Get-SslMap
$bindings = @()

Get-Website | ForEach-Object {
    $site = $_
    Get-WebBinding -Name $site.Name | ForEach-Object {
        $binding = $_
        $parts = @($binding.bindingInformation -split ":", 3)
        $ip = if ($parts.Count -gt 0 -and $parts[0]) { $parts[0] } else { "*" }
        if ($ip -eq "0.0.0.0") { $ip = "*" }
        $port = if ($parts.Count -gt 1) { [int]$parts[1] } else { 80 }
        $hostHeader = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $protocol = if ($binding.protocol) { $binding.protocol.ToLowerInvariant() } else { "http" }
        $hasSsl = $protocol -eq "https"
        $row = [ordered]@{
            site_name     = $site.Name
            protocol      = $protocol
            ip            = $ip
            port          = $port
            hostname      = $hostHeader
            has_ssl       = $hasSsl
            cert_subject  = $null
            cert_issuer   = $null
            fingerprint   = $null
            not_before    = $null
            not_after     = $null
            san           = @()
        }

        if ($hasSsl) {
            $thumb = Resolve-Thumbprint -Binding $binding -SslMap $sslMap -Ip $ip -Port $port -HostName $hostHeader
            $cert = Get-CertByThumbprint -Thumbprint $thumb
            if ($cert) {
                $row.cert_subject = $cert.Subject
                $row.cert_issuer = $cert.Issuer
                $row.fingerprint = ($cert.Thumbprint -replace ".{2}(?!$)", '$0:').ToUpperInvariant()
                $row.not_before = Convert-ToIso $cert.NotBefore
                $row.not_after = Convert-ToIso $cert.NotAfter
                $row.san = @(Get-SanNames $cert)
            }
        }
        $bindings += [pscustomobject]$row
    }
}

$payload = @{
    hostname      = $env:COMPUTERNAME
    os_type       = "windows"
    collected_at  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    agent_version = $AgentVersion
    bindings      = @($bindings)
}

# JavaScriptSerializer keeps single-item arrays as JSON arrays (ConvertTo-Json in Windows PowerShell 5.1 does not).
Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = [int]::MaxValue
$body = $serializer.Serialize($payload)

Write-AgentLog ("Toplanan binding: {0}" -f @($bindings).Count)

$headers = @{
    "X-Agent-Token" = $AgentToken
}

try {
    $response = Invoke-RestMethod -Method Post -Uri $ingestUrl -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
    Write-AgentLog ("WEBSSL ingest OK: {0} bindings={1}" -f $response.hostname, $response.bindings)
} catch {
    $detail = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail += " | " + $_.ErrorDetails.Message }
    Write-AgentLog ("WEBSSL ingest failed: {0}" -f $detail)
    throw
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Collects IIS site bindings and SSL certificate expiry, then posts them to WEBSSL.
#>
[CmdletBinding()]
param(
    [string]$CentralUrl = $env:CENTRAL_URL,
    [string]$AgentToken = $env:AGENT_TOKEN,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "agent.config.json")
)

$ErrorActionPreference = "Stop"
$AgentVersion = "1.0.0"

if (Test-Path $ConfigPath) {
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    if (-not $CentralUrl -and $config.CentralUrl) { $CentralUrl = $config.CentralUrl }
    if (-not $AgentToken -and $config.AgentToken) { $AgentToken = $config.AgentToken }
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

if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    throw "WebAdministration module not found. Install IIS Management Scripts and Tools."
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

$ingestUrl = $CentralUrl.TrimEnd("/") + "/api/ingest"
$headers = @{
    "X-Agent-Token" = $AgentToken
}

try {
    $response = Invoke-RestMethod -Method Post -Uri $ingestUrl -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
    Write-Output ("WEBSSL ingest OK: {0} bindings={1}" -f $response.hostname, $response.bindings)
} catch {
    Write-Error ("WEBSSL ingest failed: {0}" -f $_.Exception.Message)
    throw
}

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs a daily Task Scheduler job for the WEBSSL IIS agent.
    Dashboard IP and agent token are asked interactively unless parameters are given.
#>
[CmdletBinding()]
param(
    [string]$CentralUrl,
    [string]$AgentToken,
    [string]$TaskName = "WEBSSL-IIS-Agent",
    [string]$Time = "06:00"
)

$ErrorActionPreference = "Stop"

if (-not $CentralUrl) {
    $ip = Read-Host "Dashboard IP veya hostname"
    if (-not $ip) { throw "IP / hostname boş olamaz." }
    $port = Read-Host "Dashboard port [8080]"
    if (-not $port) { $port = "8080" }
    $CentralUrl = "http://${ip}:${port}"
}
if (-not $AgentToken) {
    $AgentToken = Read-Host "Agent token (dashboard .env icindeki AGENT_TOKEN)"
    if (-not $AgentToken) { throw "Agent token boş olamaz." }
}

$scriptPath = Join-Path $PSScriptRoot "webssl-agent.ps1"
$configPath = Join-Path $PSScriptRoot "agent.config.json"

@{
    CentralUrl = $CentralUrl
    AgentToken = $AgentToken
} | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Output "Scheduled task '$TaskName' installed. Daily run at $Time."
Write-Output "Hedef: $CentralUrl"
Write-Output "First run started."

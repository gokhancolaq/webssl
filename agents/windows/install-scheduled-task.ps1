#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs a daily Task Scheduler job for the WEBSSL IIS agent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CentralUrl,
    [Parameter(Mandatory = $true)]
    [string]$AgentToken,
    [string]$TaskName = "WEBSSL-IIS-Agent",
    [string]$Time = "06:00"
)

$ErrorActionPreference = "Stop"
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
Write-Output "Scheduled task '$TaskName' installed. Daily run at $Time. First run started."

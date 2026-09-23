#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads WEBSSL Windows IIS agent from public GitHub and installs the daily task.

    IIS sunucusunda yönetici PowerShell:

        iex (irm https://raw.githubusercontent.com/gokhancolaq/webssl/main/agents/windows/install.ps1)
#>
[CmdletBinding()]
param(
    [string]$RepoUrl = "https://github.com/gokhancolaq/webssl.git",
    [string]$ZipUrl = "https://github.com/gokhancolaq/webssl/archive/refs/heads/main.zip",
    [string]$RawInstallUrl = "https://raw.githubusercontent.com/gokhancolaq/webssl/main/agents/windows/install.ps1",
    [string]$InstallDir = "$env:ProgramData\WEBSSL\agent",
    [string]$CentralUrl,
    [string]$AgentToken,
    [string]$TaskName = "WEBSSL-IIS-Agent",
    [string]$Time = "06:00"
)

$ErrorActionPreference = "Stop"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

# irm | iex stdin'i kilitler; dosyadan tekrar çalıştır ki Read-Host token alsın.
$scriptFile = $PSCommandPath
if (-not $scriptFile) { $scriptFile = $MyInvocation.MyCommand.Path }
if (-not $scriptFile -or $scriptFile -eq "") {
    $local = Join-Path $env:TEMP "webssl-win-install.ps1"
    Invoke-WebRequest -Uri $RawInstallUrl -OutFile $local -UseBasicParsing
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$local`""
    if ($CentralUrl) { $arg += " -CentralUrl `"$CentralUrl`"" }
    if ($AgentToken) { $arg += " -AgentToken `"$AgentToken`"" }
    Start-Process -FilePath "powershell.exe" -ArgumentList $arg -Wait -NoNewWindow
    return
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Required {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )
    while ($true) {
        $label = $Prompt
        if ($Default) { $label = "$Prompt [$Default]" }
        $value = Read-Host $label
        if ($null -eq $value) { $value = "" }
        $value = $value.Trim()
        if (-not $value -and $Default) { return $Default }
        if ($value) { return $value }
        Write-Host "Bos birakilamaz, tekrar deneyin."
    }
}

if (-not (Test-IsAdmin)) {
    Write-Host "Yonetici yetkisi gerekli, UAC acilacak..."
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`""
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arg -Wait
    return
}

if (-not $CentralUrl) {
    $ip = Read-Required "Dashboard IP veya hostname"
    $port = Read-Required "Dashboard port" "8080"
    $CentralUrl = "http://${ip}:${port}"
}
if (-not $AgentToken) {
    Write-Host "Ubuntu dashboard sunucusundan token:"
    Write-Host "  sudo grep AGENT_TOKEN /opt/webssl/.env"
    $AgentToken = Read-Required "Agent token"
}

$tempRoot = Join-Path $env:TEMP ("webssl-agent-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $sourceDir = $null
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        Write-Host "GitHub'dan klonlaniyor..."
        & git clone --depth 1 $RepoUrl (Join-Path $tempRoot "repo")
        if ($LASTEXITCODE -ne 0) { throw "git clone basarisiz." }
        $sourceDir = Join-Path $tempRoot "repo\agents\windows"
    } else {
        Write-Host "Git yok, ZIP indiriliyor..."
        $zipPath = Join-Path $tempRoot "webssl.zip"
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath (Join-Path $tempRoot "extract") -Force
        $sourceDir = Get-ChildItem (Join-Path $tempRoot "extract") -Directory |
            ForEach-Object { Join-Path $_.FullName "agents\windows" } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
    }

    if (-not $sourceDir -or -not (Test-Path (Join-Path $sourceDir "webssl-agent.ps1"))) {
        throw "Agent dosyalari GitHub paketinde bulunamadi."
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item (Join-Path $sourceDir "webssl-agent.ps1") (Join-Path $InstallDir "webssl-agent.ps1") -Force
    Copy-Item (Join-Path $sourceDir "install-scheduled-task.ps1") (Join-Path $InstallDir "install-scheduled-task.ps1") -Force -ErrorAction SilentlyContinue

    $scriptPath = Join-Path $InstallDir "webssl-agent.ps1"
    $configPath = Join-Path $InstallDir "agent.config.json"
    @{
        CentralUrl = $CentralUrl
        AgentToken = $AgentToken
    } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $Time
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    Write-Host ""
    Write-Host "Dashboard kontrol ediliyor: $CentralUrl"
    try {
        $health = Invoke-RestMethod -Method Get -Uri ($CentralUrl.TrimEnd("/") + "/api/health")
        Write-Host ("Health OK: {0}" -f $health.time)
    } catch {
        Write-Host "UYARI: Dashboard'a su an ulasilamiyor: $($_.Exception.Message)"
        Write-Host "Ubuntu'da servis ve 8080 firewall acik olmali."
    }

    Write-Host "Ilk tarama simdi bu pencerede calisiyor..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "Ilk tarama HATA ile bitti. Log: $(Join-Path $InstallDir 'agent.log')"
        throw "Agent dashboard'a veri gonderemedi."
    }

    Write-Host ""
    Write-Host "WEBSSL Windows agent kuruldu."
    Write-Host "Klasor: $InstallDir"
    Write-Host "Hedef: $CentralUrl"
    Write-Host "Gorev: $TaskName (her gun $Time)"
    Write-Host "Dashboard'u yenileyin: $CentralUrl"
} finally {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

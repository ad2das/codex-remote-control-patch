param(
    [int]$Port = 47658
)

$ErrorActionPreference = "Stop"

$taskName = "CodexRemoteControlServer"
$scriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "Start-CodexRemoteControlServer.ps1")).Path
$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) {
    $pwsh = (Get-Command powershell.exe -ErrorAction Stop).Source
}

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Port $Port"

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$watchdogTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

$installMode = $null
$installDetail = $null

try {
    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger @($logonTrigger, $watchdogTrigger) `
        -Settings $settings `
        -Principal $principal `
        -Description "Keeps Codex remote-control app-server running without modifying app.asar or config.toml." `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 4

    $task = Get-ScheduledTask -TaskName $taskName
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
    $installMode = "scheduledTask"
    $installDetail = "state=$($task.State); lastTaskResult=$($taskInfo.LastTaskResult)"
} catch {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runValue = "`"$pwsh`" -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Port $Port"
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty -Path $runKey -Name $taskName -Value $runValue -PropertyType String -Force | Out-Null
    $installMode = "hkcuRun"
    $installDetail = "scheduledTaskFailed=$($_.Exception.Message)"
}

$status = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Port $Port | ConvertFrom-Json

[pscustomobject]@{
    installMode = $installMode
    installDetail = $installDetail
    remoteControlStatus = $status.status
    serverName = $status.serverName
    installationId = $status.installationId
    environmentId = $status.environmentId
} | ConvertTo-Json -Depth 8

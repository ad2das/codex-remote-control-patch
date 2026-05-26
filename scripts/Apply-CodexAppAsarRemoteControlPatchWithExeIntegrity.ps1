param(
    [string]$PackageRoot = "C:\Users\Administrator\Downloads\OpenAI.Codex_26.519.5221.0_x64__2p2nqsd0c76g0",
    [int]$StartupWaitSeconds = 35
)

$ErrorActionPreference = "Stop"

$appRoot = Join-Path $PackageRoot "app"
$codexExe = Join-Path $appRoot "Codex.exe"
$asarPath = Join-Path $appRoot "resources\app.asar"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$asarBackup = Join-Path (Split-Path $asarPath -Parent) "app.asar.bak-remote-control-exe-integrity-$stamp"
$exeBackup = Join-Path $appRoot "Codex.exe.bak-remote-control-exe-integrity-$stamp"
$reportPath = Join-Path $PWD "apply-app-asar-remote-control-with-exe-integrity-report.txt"

function Write-Report {
    param([string]$Message)
    $line = "$(Get-Date -Format s) $Message"
    Write-Output $line
    Add-Content -Path $reportPath -Value $line -Encoding UTF8
}

function Stop-CodexProcesses {
    Get-Process Codex,codex -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Path -like "$appRoot*" -or $_.Path -like "$(Join-Path $appRoot 'resources')*"
        } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Start-CodexAndCheck {
    $p = Start-Process -FilePath $codexExe -WorkingDirectory $appRoot -PassThru
    Start-Sleep -Seconds $StartupWaitSeconds
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -like "$appRoot*"
    })
    $mainAppServer = $processes | Where-Object {
        $_.Name -ieq "codex.exe" -and
        $_.CommandLine -match "app-server" -and
        $_.CommandLine -notmatch "--listen stdio://"
    } | Select-Object -First 1

    return [pscustomobject]@{
        RootPid = $p.Id
        ProcessCount = $processes.Count
        MainAppServerCommandLine = $mainAppServer.CommandLine
        HasRemoteControlArg = $mainAppServer.CommandLine -match "--remote-control"
    }
}

Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue

Write-Report "PackageRoot=$PackageRoot"
Copy-Item -LiteralPath $asarPath -Destination $asarBackup -Force
Copy-Item -LiteralPath $codexExe -Destination $exeBackup -Force
Write-Report "Backups created: $asarBackup ; $exeBackup"

try {
    Stop-CodexProcesses

    node .\Patch-CodexAppServerRemoteControlArgWithIntegrity.js $asarPath | Tee-Object -Variable asarPatchOutput | Out-Null
    Write-Report "app.asar remote-control patch: $($asarPatchOutput -join ' ')"

    node .\Patch-CodexExeAsarIntegrity.js $codexExe $asarPath | Tee-Object -Variable exePatchOutput | Out-Null
    Write-Report "Codex.exe AsarIntegrity patch: $($exePatchOutput -join ' ')"

    $check = Start-CodexAndCheck
    Write-Report "Started RootPid=$($check.RootPid) ProcessCount=$($check.ProcessCount) HasRemoteControlArg=$($check.HasRemoteControlArg)"
    Write-Report "MainAppServerCommandLine=$($check.MainAppServerCommandLine)"

    if (-not $check.HasRemoteControlArg) {
        throw "Codex started, but the main app-server command line did not include --remote-control."
    }

    Write-Report "RESULT: remote-control app.asar patch applied and verified."
} catch {
    Write-Report "ERROR: $($_.Exception.Message)"
    Stop-CodexProcesses
    Copy-Item -LiteralPath $asarBackup -Destination $asarPath -Force
    Copy-Item -LiteralPath $exeBackup -Destination $codexExe -Force
    Write-Report "Restored original app.asar and Codex.exe after failure."
    Start-Process -FilePath $codexExe -WorkingDirectory $appRoot | Out-Null
    throw
}

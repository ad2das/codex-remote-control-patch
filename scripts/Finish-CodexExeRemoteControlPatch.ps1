param(
    [string]$PackageRoot = "",
    [int]$StartupWaitSeconds = 20
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-CodexPackageRoot {
    if ($PackageRoot) {
        return (Resolve-Path -LiteralPath $PackageRoot).Path
    }

    $paths = New-Object System.Collections.Generic.List[string]

    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -match "\\OpenAI\.Codex_.*\\app\\Codex\.exe$" } |
        ForEach-Object {
            $paths.Add((Split-Path -Parent (Split-Path -Parent $_.ExecutablePath)))
        }

    $downloads = Join-Path $env:USERPROFILE "Downloads"
    if (Test-Path -LiteralPath $downloads) {
        Get-ChildItem -LiteralPath $downloads -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $paths.Add($_.FullName) }
    }

    foreach ($path in ($paths | Select-Object -Unique)) {
        if (
            (Test-Path -LiteralPath (Join-Path $path "app\Codex.exe")) -and
            (Test-Path -LiteralPath (Join-Path $path "app\resources\app.asar"))
        ) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    throw "Codex package root was not found. Pass -PackageRoot explicitly."
}

$PackageRoot = Get-CodexPackageRoot
$appRoot = Join-Path $PackageRoot "app"
$codexExe = Join-Path $appRoot "Codex.exe"
$asarPath = Join-Path $appRoot "resources\app.asar"
$reportPath = Join-Path $scriptRoot "finish-codex-exe-remote-control-patch-report.txt"

function Write-Report {
    param([string]$Message)
    $line = "$(Get-Date -Format s) $Message"
    Write-Output $line
    Add-Content -Path $reportPath -Value $line -Encoding UTF8
}

function Stop-CodexProcesses {
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.ExecutablePath -like "$appRoot*" -or
            $_.ExecutablePath -like "$(Join-Path $appRoot 'resources')*"
        } |
        ForEach-Object {
            try {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                Write-Report "Stopped pid=$($_.ProcessId) $($_.ExecutablePath)"
            } catch {
                Write-Report "Stop failed pid=$($_.ProcessId): $($_.Exception.Message)"
            }
        }
}

function Wait-ExeWritable {
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $stream = [System.IO.File]::Open($codexExe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $stream.Dispose()
            return
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    throw "Codex.exe did not become writable."
}

Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
Write-Report "PackageRoot=$PackageRoot"

Stop-CodexProcesses
Wait-ExeWritable

$asarPatch = & node (Join-Path $scriptRoot "Patch-CodexAppServerRemoteControlArgWithIntegrity.js") $asarPath
Write-Report "app.asar patch: $($asarPatch -join ' ')"

$exePatch = & node (Join-Path $scriptRoot "Patch-CodexExeAsarIntegrity.js") $codexExe $asarPath
Write-Report "Codex.exe AsarIntegrity patch: $($exePatch -join ' ')"

$p = Start-Process -FilePath $codexExe -WorkingDirectory $appRoot -PassThru
Write-Report "Restarted Codex root pid=$($p.Id)"
Start-Sleep -Seconds $StartupWaitSeconds

$processes = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$appRoot*" })
$mainAppServer = $processes |
    Where-Object {
        $_.Name -ieq "codex.exe" -and
        $_.CommandLine -match "app-server" -and
        $_.CommandLine -notmatch "--listen stdio://"
    } |
    Select-Object -First 1

Write-Report "ProcessCount=$($processes.Count)"
Write-Report "MainAppServerCommandLine=$($mainAppServer.CommandLine)"

if ($mainAppServer.CommandLine -notmatch "--remote-control") {
    throw "Codex restarted, but the main app-server command line did not include --remote-control."
}

Write-Report "RESULT: Codex.exe and app.asar remote-control patch applied and verified."

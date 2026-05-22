param(
    [string]$AppRoot = "$env:LOCALAPPDATA\Programs\Codex Offline\_internal\app",
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[codex-remote-control] $Message"
}

function Replace-SameLength {
    param(
        [string]$Text,
        [string]$Old,
        [string]$NewCore,
        [string]$Name
    )

    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -eq 0) {
        $already = ([regex]::Matches($Text, [regex]::Escape($NewCore))).Count
        if ($already -gt 0) {
            Write-Step "$Name already patched ($already occurrence(s))."
            return @{ Text = $Text; Changed = $false }
        }

        throw "$Name pattern not found. This Codex build may need an updated patch."
    }

    if ($NewCore.Length -gt $Old.Length) {
        throw "$Name replacement is longer than the original pattern."
    }

    $new = $NewCore + (" " * ($Old.Length - $NewCore.Length))
    if ($new.Length -ne $Old.Length) {
        throw "$Name replacement length mismatch."
    }

    Write-Step "$Name patched ($count occurrence(s))."
    return @{ Text = $Text.Replace($Old, $new); Changed = $true }
}

$appRootResolved = Resolve-Path -LiteralPath $AppRoot
$asar = Join-Path $appRootResolved "resources\app.asar"
$codexExe = Join-Path $appRootResolved "Codex.exe"

if (-not (Test-Path -LiteralPath $asar)) {
    throw "app.asar not found: $asar"
}

if (-not (Test-Path -LiteralPath $codexExe)) {
    throw "Codex.exe not found: $codexExe"
}

Write-Step "Using app root: $appRootResolved"

Write-Step "Stopping running Codex app processes from this installation."
Get-Process Codex,codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$appRootResolved*" } |
    Stop-Process -Force

Start-Sleep -Milliseconds 500

$encoding = [Text.Encoding]::GetEncoding("ISO-8859-1")
$text = $encoding.GetString([IO.File]::ReadAllBytes($asar))
$changed = $false

$removeRemoteControlOld = 'function cU(e){return Object.hasOwn(e,`remote_control`)||lU(e.features)&&Object.hasOwn(e.features,`remote_control`)}'
$removeRemoteControlNew = 'function cU(e){return !1}'
$result = Replace-SameLength -Text $text -Old $removeRemoteControlOld -NewCore $removeRemoteControlNew -Name "config remote_control removal guard"
$text = $result.Text
$changed = $changed -or $result.Changed

$appServerArgsOld = '[`-c`,`windows.sandbox=''unelevated''`,`app-server`,`--analytics-default-enabled`]'
$appServerArgsNew = '[`app-server`,`--remote-control`,`--analytics-default-enabled`]'
$result = Replace-SameLength -Text $text -Old $appServerArgsOld -NewCore $appServerArgsNew -Name "app-server startup args"
$text = $result.Text
$changed = $changed -or $result.Changed

if ($changed) {
    $backup = "$asar.bak-remote-control-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $asar -Destination $backup
    [IO.File]::WriteAllBytes($asar, $encoding.GetBytes($text))
    Write-Step "Wrote patched app.asar."
    Write-Step "Backup: $backup"
} else {
    Write-Step "No app.asar changes needed."
}

$codexHome = Join-Path $env:USERPROFILE ".codex"
$config = Join-Path $codexHome "config.toml"
if (-not (Test-Path -LiteralPath $codexHome)) {
    New-Item -ItemType Directory -Path $codexHome | Out-Null
}

if (-not (Test-Path -LiteralPath $config)) {
    Set-Content -LiteralPath $config -Value "[features]`r`nremote_control = true`r`n" -Encoding UTF8
    Write-Step "Created config.toml with remote_control enabled."
} else {
    $cfg = Get-Content -LiteralPath $config -Raw
    if ($cfg -match '(?m)^remote_control\s*=') {
        $updated = $cfg -replace '(?m)^remote_control\s*=.*$', 'remote_control = true'
    } elseif ($cfg -match '(?m)^\[features\]\s*$') {
        $updated = $cfg -replace '(?m)^\[features\]\s*$', "[features]`r`nremote_control = true"
    } else {
        $updated = $cfg.TrimEnd() + "`r`n`r`n[features]`r`nremote_control = true`r`n"
    }

    if ($updated -ne $cfg) {
        Set-Content -LiteralPath $config -Value $updated -Encoding UTF8
        Write-Step "Updated config.toml remote_control = true."
    } else {
        Write-Step "config.toml already has remote_control = true."
    }
}

if (-not $NoRestart) {
    Write-Step "Starting Codex."
    Start-Process -FilePath $codexExe -WorkingDirectory $appRootResolved
    Start-Sleep -Seconds 3

    $remoteProcess = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "codex.exe" -and
            $_.ExecutablePath -like "$appRootResolved*" -and
            $_.CommandLine -match "--remote-control"
        } |
        Select-Object -First 1

    if ($remoteProcess) {
        Write-Step "Verified app-server is running with --remote-control. PID: $($remoteProcess.ProcessId)"
    } else {
        Write-Warning "Codex started, but no bundled app-server process with --remote-control was found yet."
    }
}

Write-Step "Done."

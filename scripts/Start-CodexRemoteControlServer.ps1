param(
    [int]$Port = 47658
)

$ErrorActionPreference = "Stop"

$logDir = Join-Path $env:USERPROFILE ".codex\remote-control-server"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "launcher.log"

function Write-LauncherLog {
    param([string]$Message)
    $stamp = (Get-Date).ToString("s")
    Add-Content -Path $logFile -Value "$stamp $Message" -Encoding UTF8
}

function Get-CodexExePath {
    $paths = New-Object System.Collections.Generic.List[string]

    Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -match "resources\\codex\.exe" } |
        ForEach-Object {
            if ($_.CommandLine -match '"([^"]*resources\\codex\.exe)"') {
                $paths.Add($matches[1])
            } elseif ($_.CommandLine -match '([A-Z]:\\[^\s"]*resources\\codex\.exe)') {
                $paths.Add($matches[1])
            }
        }

    $downloads = Join-Path $env:USERPROFILE "Downloads"
    if (Test-Path -LiteralPath $downloads) {
        Get-ChildItem -LiteralPath $downloads -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                $paths.Add((Join-Path $_.FullName "app\resources\codex.exe"))
            }
    }

    $paths.Add("C:\Users\Administrator\Downloads\OpenAI.Codex_26.519.5221.0_x64__2p2nqsd0c76g0\app\resources\codex.exe")

    foreach ($path in ($paths | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    throw "codex.exe was not found."
}

function Get-RemoteControlProcess {
    param([int]$TargetPort)

    Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "codex\.exe" -and
            $_.CommandLine -match "app-server" -and
            $_.CommandLine -match "--remote-control" -and
            $_.CommandLine -match [regex]::Escape("127.0.0.1:$TargetPort")
        } |
        Select-Object -First 1
}

function Invoke-AppServerRequest {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Method,
        [object]$Params,
        [int]$Id
    )

    $payload = @{
        jsonrpc = "2.0"
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Compress -Depth 16

    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $Socket.SendAsync(
        [ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult() | Out-Null

    while ($true) {
        $buffer = New-Object byte[] 65536
        $result = $Socket.ReceiveAsync(
            [ArraySegment[byte]]::new($buffer),
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()

        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
        $message = $text | ConvertFrom-Json
        if ($message.id -eq $Id) {
            return $message
        }
    }
}

function Test-RemoteControlStatus {
    param([int]$TargetPort)

    Add-Type -AssemblyName System.Net.WebSockets.Client
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $null = $socket.ConnectAsync([Uri]"ws://127.0.0.1:$TargetPort/", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        Invoke-AppServerRequest -Socket $socket -Method "initialize" -Params @{
            clientInfo = @{ name = "Codex Remote Control launcher"; version = "1" }
            capabilities = @{ experimentalApi = $true }
        } -Id 1 | Out-Null

        $status = Invoke-AppServerRequest -Socket $socket -Method "remoteControl/status/read" -Params @{} -Id 2
        return $status.result
    } finally {
        try {
            $socket.Dispose()
        } catch {
        }
    }
}

try {
    $existing = Get-RemoteControlProcess -TargetPort $Port
    if ($existing) {
        $status = Test-RemoteControlStatus -TargetPort $Port
        Write-LauncherLog "already_running pid=$($existing.ProcessId) status=$($status.status) environmentId=$($status.environmentId)"
        $status | ConvertTo-Json -Depth 8
        exit 0
    }

    $codexExe = Get-CodexExePath
    $serverLog = Join-Path $logDir "server-$Port.log"
    $args = @(
        "app-server",
        "--listen",
        "ws://127.0.0.1:$Port",
        "--analytics-default-enabled",
        "--remote-control"
    )

    $process = Start-Process -FilePath $codexExe -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $serverLog -RedirectStandardError $serverLog -PassThru
    Start-Sleep -Seconds 3

    if ($process.HasExited) {
        throw "remote-control app-server exited immediately with code $($process.ExitCode)."
    }

    $status = Test-RemoteControlStatus -TargetPort $Port
    Write-LauncherLog "started pid=$($process.Id) status=$($status.status) environmentId=$($status.environmentId)"
    $status | ConvertTo-Json -Depth 8
} catch {
    Write-LauncherLog "error $($_.Exception.Message)"
    throw
}

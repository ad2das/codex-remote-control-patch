# Codex Remote Control Patch

Utilities for enabling Codex Desktop remote control on Windows.

This repository does not redistribute Codex binaries. It only contains local scripts.

## Current Recommended Path

The validated integrated path patches Codex Desktop's `app.asar` and refreshes the embedded Electron `AsarIntegrity` hash in `Codex.exe`.

Apply the integrated patch:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Apply-CodexAppAsarRemoteControlPatchWithExeIntegrity.ps1
```

The patch verifies that the main app server starts with:

```text
codex.exe app-server --analytics-default-enabled --remote-control
```

The script creates timestamped backups of `app.asar` and `Codex.exe` before patching. On verification failure, it restores both files and restarts Codex.

## Fallback Separate Server Path

The fallback path runs a separate bundled `codex.exe app-server` process with `--remote-control`.

This avoids modifying:

- `app.asar`
- `~/.codex/config.toml`
- packaged Codex binaries

Install auto-start:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-CodexRemoteControlAutoStart.ps1
```

Start or verify manually:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-CodexRemoteControlServer.ps1
```

Expected status:

```json
{
  "status": "connected"
}
```

The auto-start installer first tries Windows Task Scheduler. If that is denied by policy, it falls back to:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run\CodexRemoteControlServer
```

## App.asar Patch Notes

`scripts\Enable-CodexRemoteControl.ps1` is the older app.asar patch path. Prefer `scripts\Apply-CodexAppAsarRemoteControlPatchWithExeIntegrity.ps1` for current Codex Desktop builds.

Important notes:

- Do not add `remote_control = true` blindly to `config.toml`; if it lands under an env table it can break startup with `invalid type: boolean true, expected a string`.
- Recent Electron packages embed an `AsarIntegrity` hash in `Codex.exe`. Same-length byte replacements and asar internal integrity updates are not enough; `Codex.exe` must be refreshed to match the patched asar header hash.
- Always keep a timestamped `app.asar` backup and verify app startup after patching.

## Verify Running Process

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -eq "codex.exe" -and
    $_.CommandLine -match "app-server" -and
    $_.CommandLine -match "--remote-control"
  } |
  Select-Object ProcessId, CommandLine
```

You should see a process like:

```text
codex.exe app-server --listen ws://127.0.0.1:47658 --analytics-default-enabled --remote-control
```

## Restore

For the auto-start path:

```powershell
Remove-ItemProperty `
  -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "CodexRemoteControlServer" `
  -ErrorAction SilentlyContinue
```

Then stop the remote-control server process:

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -eq "codex.exe" -and
    $_.CommandLine -match "--remote-control"
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

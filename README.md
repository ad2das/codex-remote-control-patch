# Codex Remote Control Patch

PowerShell patch script for enabling Codex app-server remote control in the Windows Codex desktop app.

This repository does not redistribute Codex binaries. It only patches a local Codex installation by:

- preventing the desktop app from removing `remote_control` from `~/.codex/config.toml`
- starting the bundled app-server with `--remote-control`
- enabling `goals` in `~/.codex/config.toml`
- ensuring the local Codex sqlite state DB has the `thread_goals` table used by `/목표`
- keeping a timestamped backup of `app.asar`

## Supported Target

This was tested against the Windows **Codex Offline** desktop app installed under:

```powershell
$env:LOCALAPPDATA\Programs\Codex Offline\_internal\app
```

Other builds may have different bundled JavaScript and may need an updated patch pattern.

## Usage

Open PowerShell and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Enable-CodexRemoteControl.ps1
```

If Codex is installed somewhere else:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Enable-CodexRemoteControl.ps1 -AppRoot "C:\Path\To\Codex\_internal\app"
```

The script stops the running Codex desktop app while patching, then starts it again.

For the goals sqlite fix, the script uses `python`/`py` first and falls back to `sqlite3` if available. It creates timestamped `.bak-goals-*` backups before touching Codex sqlite files.

## Verify

After running the script, check the bundled app-server process:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -eq "codex.exe" -and $_.CommandLine -match "--remote-control" } |
  Select-Object ProcessId, CommandLine
```

You should see:

```text
codex.exe app-server --remote-control --analytics-default-enabled
```

## Restore

The patch script creates backups next to `app.asar`, for example:

```text
app.asar.bak-remote-control-20260522-095612
```

To restore manually:

1. Exit Codex.
2. Replace `resources\app.asar` with one of the backup files.
3. Start Codex again.

## Notes

Codex app updates or reinstalls can replace `app.asar`, which removes the patch. Run the script again after updating if remote control stops working.

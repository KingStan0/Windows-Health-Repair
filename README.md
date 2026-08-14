# Windows Health Repair

[![CI](https://github.com/KingStan0/Windows-Health-Repair/actions/workflows/ci.yml/badge.svg)](https://github.com/KingStan0/Windows-Health-Repair/actions/workflows/ci.yml)

One-click PowerShell utility that repairs and cleans your Windows system: component store (DISM), protected system files (SFC), and safe disk cleanup - all in the correct order, fully logged.

## Description

System file corruption on Windows is usually fixed by three tools: DISM, SFC, and disk cleanup - but only in the right order, from an elevated console, with patience while long scans run. This project packages that into a single double-click:

1. **DISM ScanHealth + RestoreHealth** - repairs the Windows component store (the source SFC copies files from)
2. **sfc /scannow** - repairs protected system files using the now-healthy store
3. **Disk cleanup** - superseded component cleanup, Windows Update cache, temp files, and optionally the recycle bin

No registry tweaks, no third-party tools, no "optimizer" magic. Only built-in Windows repair utilities, run correctly.

## Features

- **One click** - double-click `Repair Windows Health.bat`, accept the UAC prompt, done
- **Report-only mode** - `-ReportOnly` checks health (DISM scan, `sfc /verifyonly`) without repairing or deleting anything
- **Scheduled maintenance** - `-Schedule` registers a weekly Sunday-03:00 task running with highest privileges (no popup, no reboot prompt)
- **Local repair source** - if Windows Update cannot provide DISM repair files, the script automatically retries with a local Windows ISO (`install.wim`/`install.esd`) if one is found or passed with `-Source`
- **Correct repair order** - DISM before SFC, so SFC has clean files to copy from
- **Accurate results** - real exit codes captured via the .NET Process API (works on PowerShell 5.1, where `Start-Process` cannot provide exit codes)
- **SFC verdict from CBS.log** - sfc runs with its native progress visible (never output-redirected); the result is verified against `CBS.log` (`[SR] Repairing` / `[SR] Repaired` markers) for an accurate verdict either way
- **Hang detection** - warns (never kills) if DISM/SFC sit with zero CPU activity for an extended period
- **Full logging** - timestamped `WindowsHealthRepair_<date>.log` saved next to the script, with per-phase timings, a summary table, and disk-space delta; old logs auto-pruned (keep the last 10 by default)
- **Phase progress** - live progress bar and window title showing overall completion
- **Exit codes** - `0` all healthy, `1` repairs applied / restart recommended, `2` one or more phases errored (scriptable)
- **Completion popup** - a summary dialog at the end (can be disabled via config; always suppressed in scheduled runs)
- **Configurable** - every phase and cleanup target can be toggled via `WindowsHealthRepair.json` (no code edits needed)
- **Safe** - temp-only cleanup, Windows Update services paused only when running and restored to their prior state, reboot prompt only when repairs actually require it. Your files are never touched: the recycle bin is only emptied if you pass `-EmptyRecycleBin`
- **Diagnostic guidance** - on DISM failures, points to Safe Mode / Windows ISO source next steps and logs the relevant log tails

## Requirements

- Windows 10 or Windows 11
- Administrator rights (auto-elevation via UAC)
- Internet connection for DISM RestoreHealth (repair files download from Windows Update)

## Usage

### One-click (recommended)

```bat
Repair Windows Health.bat
```

### Manual

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "Repair-WindowsHealth.ps1"
```

Optional parameters:

| Parameter | Effect |
|-----------|--------|
| `-EmptyRecycleBin` | Also empty the Recycle Bin during Phase 3 (off by default) |
| `-ReportOnly` | Health check only: DISM ScanHealth + `sfc /verifyonly`, no repairs, no cleanup |
| `-Schedule` | Register a weekly scheduled task (Sundays 03:00, highest privileges) and exit |
| `-Unschedule` | Remove the scheduled task and exit |
| `-ScheduledRun` | Internal flag the scheduled task passes: suppresses the popup, restart prompt, and "Press Enter" pause |
| `-Source <path>` | Path to a Windows ISO image (`install.wim`/`install.esd`) or a folder containing `sources\install.wim`/`.esd`, used as fallback when DISM RestoreHealth fails to download from Windows Update |

The script re-launches itself elevated via UAC if needed.

## Automation

The script is designed for scripting and scheduled runs:

- **Exit codes**: `0` = all healthy, `1` = repairs were applied (restart recommended), `2` = one or more phases errored.
- **Scheduled task**: run `Repair-WindowsHealth.ps1 -Schedule` once from an elevated prompt to install a weekly Sunday 03:00 task that runs the full repair with highest privileges. Logs are written to the script folder, so the task can point at any copy of the script. Remove it later with `-Unschedule`.
- **Silent runs**: add `-ScheduledRun` to any manual invocation to suppress the popup, restart prompt, and "Press Enter" pause - useful for CI or scheduled runs outside the registered task.

## Configuration

Copy `WindowsHealthRepair.example.json` to `WindowsHealthRepair.json` next to the script and edit it (all keys are optional - unset keys use built-in defaults). The real file is gitignored so your local settings never dirty the repo.

| Key | Default | Effect |
|-----|---------|--------|
| `RunDismScan` / `RunDismRestore` / `RunSfc` | `true` | toggle repair phases |
| `RunComponentCleanup` / `RunWindowsUpdateCache` / `RunTempCleanup` | `true` | toggle cleanup phases |
| `CleanCurrentUserTemp` / `CleanAllUsersTemp` / `CleanSystemTemp` | `true` | temp locations cleaned (all users' `AppData\Local\Temp` included) |
| `StallWarnMinutes` / `SfcStallWarnMinutes` | `12` / `15` | watchdog warning threshold per tool |
| `LogRetentionCount` / `CleanupOldLogs` | `10` / `true` | how many logs to keep |
| `TcpCheckTimeoutSeconds` | `5` | internet pre-check timeout |
| `ShowCompletionPopup` | `true` | show a completion dialog at the end (always suppressed with `-ScheduledRun`) |

## What to expect

| Phase | Tool | Duration (healthy system) |
|-------|------|---------------------------|
| Pre-flight | DISM CheckHealth | seconds |
| Phase 1 | DISM ScanHealth / RestoreHealth | 5-15 minutes |
| Phase 2 | sfc /scannow | 1-15 minutes |
| Phase 3 | StartComponentCleanup, WU cache, temp files, recycle bin (optional) | ~1 minute |

DISM RestoreHealth may appear stuck at a percentage (commonly 20% or 62.3%) - that is normal while it downloads. Let it finish; do not close the window or kill the process.

At the end, the script shows a summary table (per-phase result + elapsed time, total run time, disk-space delta) and asks to restart only if repairs were applied.

## Logs

- Script log: `WindowsHealthRepair_<yyyyMMdd_HHmmss>.log` (next to the script)
- DISM: `%SystemRoot%\Logs\DISM\dism.log`
- SFC: `%SystemRoot%\Logs\CBS\CBS.log`

## Security and Windows Defender

This tool is designed to stay clear of antivirus heuristics:

- **No `-ExecutionPolicy Bypass`** - the launcher uses `RemoteSigned` and automatically removes the Mark-of-the-Web (`Unblock-File`) from the script, so downloaded copies run normally instead of looking like a bypass dropper
- **No obfuscation** - no encoded commands, no `Invoke-Expression`, no string tricks; the script is plain, readable PowerShell
- **No registry tweaks, no services disabled, no persistence** - it pauses `wuauserv`/`bits` only if they were running, clears the update cache, and restores them to their previous state (a service you had disabled stays disabled)
- **Everything is auditable** - every action is written to the log

If Windows Defender still flags it (heuristic detection of unknown, unsigned scripts is possible):

1. **Prefer a `git clone`** over downloading the ZIP - cloned files have no Mark-of-the-Web
2. **Add a folder exclusion** (Settings > Privacy & security > Windows Security > Virus & threat protection > Manage settings > Exclusions > Add folder) for the folder containing the script
3. **Sign the script** - the definitive fix is a code-signing certificate (e.g. self-signed installed in Trusted Publishers, or a proper cert)

## Disclaimer

This tool runs built-in Windows repair utilities. It does not modify or delete any user data - cleanup is limited to system temp files, the Windows Update cache, and superseded component store versions; the Recycle Bin is only touched with `-EmptyRecycleBin`. That said, use at your own risk. A system backup is always a good idea before major repair operations.

## License

MIT - see [LICENSE](LICENSE).

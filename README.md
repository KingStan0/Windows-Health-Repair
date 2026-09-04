# Windows Health Repair Utility (WHRU)

> One click. DISM -> SFC -> cleanup, in the right order. Fully logged.

Repairs the Windows component store, protected system files, and runs safe disk cleanup with a single double-click. Built-in Windows tools only - no registry tweaks, no third-party binaries.

[![CI](https://github.com/KingStan0/Windows-Health-Repair/actions/workflows/ci.yml/badge.svg)](https://github.com/KingStan0/Windows-Health-Repair/actions/workflows/ci.yml)

## Quick start

```bat
Repair Windows Health Utility.bat
```

Accept the UAC prompt and wait. A typical run takes 10-20 minutes. DISM may sit at a fixed percentage while it downloads - that is normal, let it finish.

## Flags

| Flag | Effect |
| --- | --- |
| `-ReportOnly` | Health check only: DISM ScanHealth + `sfc /verifyonly`. Nothing is repaired or deleted |
| `-CheckDisk` | Add an online `chkdsk /scan` (no reboot) with a dirty-bit pre-check |
| `-Schedule` / `-Unschedule` | Register / remove the weekly Sunday 03:00 task (highest privileges) |
| `-ScheduledRun` | Silent mode for scheduled / CI runs: no popup, no prompts |
| `-Source <path>` | Local `install.wim` / `install.esd` or a folder containing them - DISM fallback source |
| `-LogPath <path>` | Override log directory (default: script folder, fallback `%TEMP%`) |
| `-JsonLog` | Also write `*.jsonl` machine-readable log alongside text log |
| `-RepairIso <path>` | Windows 11 ISO for in-place repair install (`Fix problems using Windows Update` equivalent, 30-60m, reboot) |
| `-EmptyRecycleBin` | Also empty the Recycle Bin |
| `-WhatIf` / `-Confirm` | Preview what would happen / prompt before destructive steps (implies report-only for `-WhatIf`) |

The script auto-elevates via UAC, and arguments passed to the `.bat` are forwarded to the script. Unknown keys in `WindowsHealthRepair.json` are logged as warnings and ignored.

## Configuration

Copy `WindowsHealthRepair.example.json` to `WindowsHealthRepair.json` next to the script. Every key is optional; unset keys use built-in defaults.

| Key | Default | Effect |
| --- | --- | --- |
| `RunDismScan`, `RunDismRestore`, `RunSfc` | `true` | Toggle repair phases |
| `SafeRestoreOnly` | `false` | RestoreHealth uses a local source only - never Windows Update (for LTSC / debloated OS) |
| `RunComponentCleanup`, `RunWindowsUpdateCache`, `RunTempCleanup` | `true` | Toggle cleanup phases |
| `RunChkdsk` | `false` | Enable the disk-check phase (also requires `-CheckDisk`) |
| `CleanCurrentUserTemp`, `CleanAllUsersTemp`, `CleanSystemTemp` | `true` | Which temp locations to clean |
| `StallWarnMinutes`, `SfcStallWarnMinutes`, `ChkdskStallWarnMinutes` | `12` / `15` / `15` | Watchdog warning thresholds (warns, never kills) |
| `LogRetentionCount`, `CleanupOldLogs` | `10` / `true` | Keep the last N logs (`<1` disables pruning) |
| `TcpCheckTimeoutSeconds` | `5` | Internet pre-check timeout |
| `ShowCompletionPopup` | `true` | Summary dialog at the end (always suppressed with `-ScheduledRun`) |
| `UseHighPriority` | `true` | Run the tool and all repair tools at High CPU priority; cleanup uses fast native deletion |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | All healthy |
| `1` | Repairs applied - restart recommended |
| `2` | One or more phases errored |

## What it runs

- **Pre-flight** - CheckHealth, system baseline (install date, uptime, disk, memory, pending reboot via `RebootPending`/`PackagesPending`/`RebootRequired` + `PendingFileRenameOperations`), internet and disk-space checks
- **Phase 1** - DISM ScanHealth + RestoreHealth; retries with a local ISO source if Windows Update fails
- **Phase 2** - `sfc /scannow`, verdict verified from CBS.log, second pass if repairs were applied
- **Optional - repair install** - `setup.exe /auto upgrade` via `-RepairIso` after Phase 2 (30-60m, reboot, keep apps/files)
- **Phase 3** - Component-store analysis + cleanup, Windows Update cache, temp files, optional Recycle Bin
- **Optional - chkdsk** - `chkdsk /scan` after Phase 2

Windows Update services (`wuauserv`, `dosvc`, `bits`) are paused only while the cache is cleared and always restored to their previous state - a service you disabled stays disabled.

## Logs

- Script log: `WindowsHealthRepairUtility_<date>.log` next to the script (`-LogPath` overrides, `-JsonLog` adds `*.jsonl`)
- DISM: `%SystemRoot%\Logs\DISM\dism.log` - SFC: `%SystemRoot%\Logs\CBS\CBS.log`

## Safety

No `ExecutionPolicy Bypass`, no encoded commands, no obfuscation - plain, readable PowerShell that stays clear of antivirus heuristics. The launcher uses `RemoteSigned` plus `Unblock-File` to clear the Mark-of-the-Web. Cleanup touches temp folders, the update cache, and superseded component-store versions only; the Recycle Bin needs an explicit flag. If Defender still flags the unsigned script, prefer `git clone` over the ZIP (no MOTW) or add a folder exclusion. Use at your own risk.

## License

MIT - see [LICENSE](LICENSE).

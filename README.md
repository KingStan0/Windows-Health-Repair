# Windows Health Repair

One-click PowerShell utility that repairs and cleans your Windows system: component store (DISM), protected system files (SFC), and safe disk cleanup - all in the correct order, fully logged.

## Description

System file corruption on Windows is usually fixed by three tools: DISM, SFC, and disk cleanup - but only in the right order, from an elevated console, with patience while long scans run. This project packages that into a single double-click:

1. **DISM ScanHealth + RestoreHealth** - repairs the Windows component store (the source SFC copies files from)
2. **sfc /scannow** - repairs protected system files using the now-healthy store
3. **Disk cleanup** - superseded component cleanup, Windows Update cache, temp files, recycle bin

No registry tweaks, no third-party tools, no "optimizer" magic. Only built-in Windows repair utilities, run correctly.

## Features

- **One click** - double-click `Repair Windows Health.bat`, accept the UAC prompt, done
- **Correct repair order** - DISM before SFC, so SFC has clean files to copy from
- **Accurate results** - real exit codes captured via the .NET Process API (works on PowerShell 5.1, where `Start-Process` cannot provide exit codes)
- **SFC verdict even when silent** - falls back to `CBS.log` analysis when `sfc` writes no summary output
- **Hang detection** - warns (never kills) if DISM/SFC sit with zero CPU activity for an extended period
- **Full logging** - timestamped `WindowsHealthRepair_<date>.log` saved next to the script
- **Safe** - temp-only cleanup, Windows Update services stopped/restarted properly, reboot prompt only when repairs actually require it
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Repair-WindowsHealth.ps1"
```

The script re-launches itself elevated via UAC if needed.

## What to expect

| Phase | Tool | Duration (healthy system) |
|-------|------|---------------------------|
| Pre-flight | DISM CheckHealth | seconds |
| Phase 1 | DISM ScanHealth / RestoreHealth | 5-15 minutes |
| Phase 2 | sfc /scannow | 1-15 minutes |
| Phase 3 | StartComponentCleanup, WU cache, temp, recycle bin | ~1 minute |

DISM RestoreHealth may appear stuck at a percentage (commonly 20% or 62.3%) - that is normal while it downloads. Let it finish; do not close the window or kill the process.

At the end, the script shows a summary (exit codes + SFC verdict) and asks to restart only if repairs were applied.

## Logs

- Script log: `WindowsHealthRepair_<yyyyMMdd_HHmmss>.log` (next to the script)
- DISM: `%SystemRoot%\Logs\DISM\dism.log`
- SFC: `%SystemRoot%\Logs\CBS\CBS.log`

## Disclaimer

This tool runs built-in Windows repair utilities. While designed to be safe and non-destructive (no user data is touched), use at your own risk. A system backup is always a good idea before major repair operations.

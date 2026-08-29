#Requires -Version 5.1

<#
.SYNOPSIS
    One-click Windows health repair utility (WHRU) - DISM, SFC, cleanup.

.DESCRIPTION
    Repairs the Windows component store (DISM ScanHealth/RestoreHealth),
    protected system files (SFC /scannow with CBS.log verification and second
    pass), and performs safe disk cleanup (component store, Windows Update
    cache, temp files, optional Recycle Bin). Fully logged with progress.

.PARAMETER ReportOnly
    Health check only: DISM ScanHealth + sfc /verifyonly. No repairs or deletions.

.PARAMETER CheckDisk
    Add online chkdsk /scan (no reboot) with dirty-bit pre-check. Requires
    config RunChkdsk=true and -not ReportOnly.

.PARAMETER Source
    Local install.wim/install.esd or folder containing sources\install.wim|esd.
    Used as DISM /Source fallback and for SafeRestoreOnly.

.PARAMETER EmptyRecycleBin
    Also empty the Recycle Bin (otherwise left untouched).

.PARAMETER Schedule
    Register weekly scheduled task Sunday 03:00 (highest privileges).

.PARAMETER Unschedule
    Remove scheduled task.

.PARAMETER ScheduledRun
    Silent mode for scheduled/CI: no popup, no prompts.

.PARAMETER LogPath
    Override log directory (default: script folder, fallback %TEMP%).

.PARAMETER WhatIf
    Preview mode (implies ReportOnly). Shows what would happen.

.PARAMETER JsonLog
    Also write machine-readable JSON lines to a .jsonl file alongside the text log.

.EXAMPLE
    .\Repair-WindowsHealthUtility.ps1 -ReportOnly
    .\Repair-WindowsHealthUtility.ps1 -LogPath D:\Logs -CheckDisk
    .\Repair-WindowsHealthUtility.ps1 -LogPath "C:\Data\My.App" -JsonLog
    Repair Windows Health Utility.bat -WhatIf

.NOTES
    Requires Administrator, PowerShell 5.1, Windows 10/11.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$EmptyRecycleBin,
    [switch]$ReportOnly,
    [switch]$Schedule,
    [switch]$Unschedule,
    [switch]$ScheduledRun,
    [string]$Source = '',
    [switch]$CheckDisk,
    [string]$LogPath = '',
    [switch]$JsonLog
)

function Build-RelaunchArgs {
    param(
        [Parameter(Mandatory)][hashtable]$BoundParameters,
        [Parameter(Mandatory)][string]$CommandPath
    )
    $escapedPath = $CommandPath -replace '"', '\"'
    $escapedPath = $escapedPath -replace '(\\+)$', '$1$1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"{0}"' -f $escapedPath))
    foreach ($key in $BoundParameters.Keys) {
        $value = $BoundParameters[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ($value) { $argList += '-' + $key }
        }
        else {
            $argList += '-' + $key
            $escapedValue = ([string]$value) -replace '"', '\"'
            $escapedValue = $escapedValue -replace '(\\+)$', '$1$1'
            $argList += ('"{0}"' -f $escapedValue)
        }
    }
    return $argList
}

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList (Build-RelaunchArgs -BoundParameters $PSBoundParameters -CommandPath $PSCommandPath)
    }
    catch {
        [Console]::WriteLine('This script requires Administrator privileges.')
        exit 1
    }
    exit
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $env:TEMP }
$LogDir = if ($LogPath) {
    $p = $LogPath.TrimEnd('\')
    try {
        $leaf = Split-Path $p -Leaf
        if ($leaf -match '\.(log|jsonl|txt|json)$' -and -not (Test-Path -LiteralPath $p -PathType Container)) { $p = Split-Path $p -Parent }
        if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null }
        if (-not $p) { $p = $ScriptDir }
        $p
    } catch { $ScriptDir }
} else { $ScriptDir }
$LogFile = Join-Path $LogDir ('WindowsHealthRepairUtility_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
try {
    Add-Content -Path $LogFile -Value '' -Encoding UTF8 -ErrorAction Stop
}
catch {
    $LogDir = $env:TEMP
    $LogFile = Join-Path $LogDir ('WindowsHealthRepairUtility_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$JsonLogFile = $null
if ($JsonLog) {
    $JsonLogFile = [System.IO.Path]::ChangeExtension($LogFile, '.jsonl')
    try { Add-Content -Path $JsonLogFile -Value '' -Encoding UTF8 -ErrorAction Stop; Remove-Item -LiteralPath $JsonLogFile -Force -ErrorAction SilentlyContinue } catch { $JsonLogFile = $null }
}

$config = @{
    LogRetentionCount      = 10
    CleanupOldLogs         = $true
    StallWarnMinutes       = 12
    SfcStallWarnMinutes    = 15
    RunDismScan            = $true
    RunDismRestore         = $true
    SafeRestoreOnly        = $false
    RunSfc                 = $true
    RunComponentCleanup    = $true
    RunWindowsUpdateCache  = $true
    RunTempCleanup         = $true
    RunChkdsk              = $false
    ChkdskStallWarnMinutes = 15
    CleanCurrentUserTemp   = $true
    CleanAllUsersTemp      = $true
    CleanSystemTemp        = $true
    TcpCheckTimeoutSeconds = 5
    ShowCompletionPopup    = $true
    UseHighPriority        = $true
}

function Coerce-ConfigValue {
    param($DefaultValue, $LoadedValue)
    if ($DefaultValue -is [bool] -and $LoadedValue -is [string]) {
        $trimmed = $LoadedValue.Trim()
        if ($trimmed -match '^(?i:true|1|yes)$') { return $true }
        if ($trimmed -match '^(?i:false|0|no)$') { return $false }
    }
    if ($DefaultValue -is [int] -and $LoadedValue -is [string]) {
        $trimmed = $LoadedValue.Trim()
        $parsed = 0
        if ([int]::TryParse($trimmed, [ref]$parsed)) { return $parsed }
    }
    return $LoadedValue
}

$ConfigPath = Join-Path $ScriptDir 'WindowsHealthRepair.json'
$configSource = 'built-in defaults'
$unknownConfigKeys = @()
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        foreach ($prop in $loaded.PSObject.Properties) {
            if ($config.ContainsKey($prop.Name)) {
                $config[$prop.Name] = Coerce-ConfigValue -DefaultValue $config[$prop.Name] -LoadedValue $prop.Value
            }
            else {
                $unknownConfigKeys += $prop.Name
            }
        }
        $configSource = 'WindowsHealthRepair.json'
    }
    catch {
        $configSource = 'built-in defaults (config file unreadable)'
    }
}

if ($config.UseHighPriority) {
    try { (Get-Process -Id $PID).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch { }
}

$ScheduledTaskName = 'Windows Health Repair Utility'

if ($Unschedule) {
    try {
        Unregister-ScheduledTask -TaskName $ScheduledTaskName -Confirm:$false -ErrorAction Stop
        [Console]::WriteLine('Scheduled task "' + $ScheduledTaskName + '" removed.')
    }
    catch {
        [Console]::WriteLine('No scheduled task found or could not be removed: ' + $_.Exception.Message)
        exit 2
    }
    exit 0
}

if ($Schedule) {
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        $taskFile = ('"{0}"' -f $PSCommandPath)
        $action = New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy RemoteSigned -File ' + $taskFile + ' -ScheduledRun')
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '03:00'
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd
        Register-ScheduledTask -TaskName $ScheduledTaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Weekly Windows health repair (DISM, SFC, cleanup). Logs are saved in the script folder.' -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        [Console]::WriteLine('Scheduled task "' + $ScheduledTaskName + '" registered: every Sunday at 03:00.')
        [Console]::WriteLine('The task runs with highest privileges. To remove it later, run with -Unschedule.')
    }
    catch {
        [Console]::WriteLine('Failed to register scheduled task: ' + $_.Exception.Message)
        exit 2
    }
    exit 0
}

if (-not $PSCmdlet.ShouldProcess("System", "Run Windows Health Repair (DISM, SFC, cleanup)")) {
    $ReportOnly = $true
    [Console]::WriteLine('WhatIf: preview mode - no repairs or cleanup will be performed.')
}

$script:results = New-Object System.Collections.ArrayList
$script:stepPos = 0
$steps = New-Object System.Collections.ArrayList
[void]$steps.Add('Pre-flight')
if ($config.RunDismScan -and -not $ReportOnly) { [void]$steps.Add('DISM ScanHealth') }
if ($config.RunDismScan -and $ReportOnly) { [void]$steps.Add('DISM ScanHealth (report)') }
if ($config.RunDismRestore -and -not $ReportOnly) { [void]$steps.Add('DISM RestoreHealth') }
if ($config.RunSfc) { [void]$steps.Add('SFC') }
if ($config.RunChkdsk -and $CheckDisk -and -not $ReportOnly) { [void]$steps.Add('Disk check') }
if ($config.RunComponentCleanup -and -not $ReportOnly) { [void]$steps.Add('Component cleanup') }
if ($config.RunWindowsUpdateCache -and -not $ReportOnly) { [void]$steps.Add('Windows Update cache') }
if ($config.RunTempCleanup -and -not $ReportOnly) { [void]$steps.Add('Temp files') }
if ($EmptyRecycleBin -and -not $ReportOnly) { [void]$steps.Add('Recycle bin') }
$script:totalSteps = $steps.Count

function Write-Log {
    [CmdletBinding()]
    param(
        [string]$Message = '',
        [ValidateSet('Gray', 'Green', 'Yellow', 'Red', 'Cyan', 'Magenta')][string]$Color = 'Gray'
    )
    if ([string]::IsNullOrEmpty($Message)) {
        Write-Host ''
        try { Add-Content -Path $LogFile -Value '' -Encoding UTF8 -ErrorAction Stop } catch { }
        if ($JsonLog -and $JsonLogFile) {
            try {
                $j = @{ timestamp = (Get-Date).ToString('o'); level = $Color; message = '' } | ConvertTo-Json -Compress
                Add-Content -Path $JsonLogFile -Value $j -Encoding UTF8 -ErrorAction Stop
            } catch { }
        }
        return
    }
    $stamp = '[{0:HH:mm:ss}] ' -f (Get-Date)
    try { Add-Content -Path $LogFile -Value ($stamp + $Message) -Encoding UTF8 -ErrorAction Stop } catch { }
    if ($JsonLog -and $JsonLogFile) {
        try {
            $j = @{ timestamp = (Get-Date).ToString('o'); level = $Color; message = $Message } | ConvertTo-Json -Compress
            Add-Content -Path $JsonLogFile -Value $j -Encoding UTF8 -ErrorAction Stop
        } catch { }
    }
    Write-Host ($stamp + $Message) -ForegroundColor $Color
}

function Show-Progress {
    param([string]$Label)
    $script:stepPos++
    if ($script:totalSteps -le 0) { return }
    if ($Host.Name -ne 'ConsoleHost') { return }
    $pct = [Math]::Floor(100 * $script:stepPos / $script:totalSteps)
    $barLen = 20
    $filled = [Math]::Floor($barLen * $script:stepPos / $script:totalSteps)
    $bar = ('#' * $filled).PadRight($barLen, '-')
    $elapsedM = 0
    try { if ($null -ne $totalRunStart) { $elapsedM = [Math]::Floor(((Get-Date) - $totalRunStart).TotalMinutes) } } catch { $elapsedM = 0 }
    Write-Host ('[{0}] {1,3}% {2}  (step {3}/{4}, {5}m elapsed)' -f $bar, $pct, $Label, $script:stepPos, $script:totalSteps, $elapsedM)
    try { $Host.UI.RawUI.WindowTitle = '{0}% - {1} - Windows Health Repair Utility ({2}m)' -f $pct, $Label, $elapsedM } catch { }
}

function Add-PhaseResult {
    param([string]$Name, [string]$Detail, [double]$Seconds)
    [void]$script:results.Add([pscustomobject]@{ Name = $Name; Detail = $Detail; Seconds = $Seconds })
    $isWarn = ($Detail -match 'exit [^0]') -or ($Detail -match 'skipped') -or ($Detail -match 'failed')
    if ($isWarn) {
        Write-Log ('  [WARN] {0} - {1} ({2})' -f $Name, $Detail, (Format-Duration $Seconds)) -Color Yellow
    }
    else {
        Write-Log ('  [OK]   {0} - {1} ({2})' -f $Name, $Detail, (Format-Duration $Seconds)) -Color Green
    }
}

function Format-Duration {
    param([double]$Seconds)
    $totalSec = [int][Math]::Floor($Seconds)
    '{0}m {1:D2}s' -f [Math]::Floor($totalSec / 60), ($totalSec % 60)
}

trap {
    Write-Log ('FATAL ERROR: ' + $_.Exception.Message) -Color Red
    exit 2
}

function Invoke-NativeTool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Phase,
        [int]$StallWarnMinutes = 10
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($ArgumentList | ForEach-Object {
        $e = $_ -replace '"', '\"'
        $e = $e -replace '(\\+)$', '$1$1'
        '"' + $e + '"'
    }) -join ' ')
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($config.UseHighPriority) {
        try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch { }
    }
    $lastCpu = $null
    $stallSeconds = 0
    $warned = $false
    $hardWarned = $false
    $gentleWarnSeconds = [Math]::Min(300, ($StallWarnMinutes * 60))
    while (-not $proc.WaitForExit(15000)) {
        try {
            $cpu = $proc.TotalProcessorTime.TotalSeconds
        }
        catch {
            $lastCpu = $null
            $stallSeconds = 0
            continue
        }
        if ($null -eq $lastCpu) {
            $lastCpu = $cpu
        }
        elseif ($cpu -eq $lastCpu) {
            $stallSeconds += 15
            if (-not $warned -and $stallSeconds -ge $gentleWarnSeconds) {
                $gentleM = [Math]::Floor($stallSeconds / 60)
                Write-Log ('NOTE: {0} shows no activity for {1} minute(s). This is often normal while it downloads or processes files. Do not close this window - let it finish.' -f $Phase, $gentleM) -Color Yellow
                $warned = $true
            }
            elseif ($warned -and -not $hardWarned -and $stallSeconds -ge ($StallWarnMinutes * 60)) {
                Write-Log ('WARNING: {0} has had no CPU activity for {1} minutes - longer than usual. Long pauses are normally fine, but keep an eye on it. Still do not kill it - let it finish.' -f $Phase, $StallWarnMinutes) -Color Red
                $hardWarned = $true
            }
        }
        else {
            $lastCpu = $cpu
            $stallSeconds = 0
        }
    }
    $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
    return $exitCode
}

function Add-LogTail {
    param([string]$Path, [int]$Lines = 12, [string]$Label)
    try {
        $content = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop
        Add-Content -Path $LogFile -Value ('--- ' + $Label + ' (last ' + $Lines + ' lines) ---') -Encoding UTF8
        $content | Add-Content -Path $LogFile -Encoding UTF8
    }
    catch {
        Add-Content -Path $LogFile -Value ('--- ' + $Label + ': not available ---') -Encoding UTF8
    }
}

function Get-DirSizeBytes {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return $sum
}

function Remove-TreeFast {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }
    $escapedPath = $Path -replace '"', '""'
    & cmd.exe /c ('rmdir /s /q "' + $escapedPath + '"') 2>$null | Out-Null
}

function Test-ProtectedPath {
    param([string]$ItemPath, [string[]]$SkipPaths)
    foreach ($skip in $SkipPaths) {
        if ($skip -eq $ItemPath -or
            $skip.StartsWith($ItemPath + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            $ItemPath.StartsWith($skip + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-CbsLinesSince {
    param([string[]]$Lines, [datetime]$Since)
    if ($null -eq $Since -or $Since -eq [datetime]::MinValue) { return $Lines }
    $parsed = @($Lines | ForEach-Object {
        $m = [regex]::Match($_, '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
        if ($m.Success) {
            $ts = [datetime]::MinValue
            if ([datetime]::TryParseExact($m.Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$ts)) {
                [pscustomobject]@{ Ts = $ts; Text = $_ }
            }
        }
    } | Where-Object { $null -ne $_ })
    if ($parsed.Count -gt 0) {
        return @($parsed | Where-Object { $_.Ts -ge $Since } | ForEach-Object { $_.Text })
    }
    return $Lines
}

function Get-SfcCbsResult {
    param(
        [datetime]$Since = [datetime]::MinValue,
        [string]$CbsPath = "$env:SystemRoot\Logs\CBS\CBS.log"
    )
    $result = @{ RepairingTotal = 0; RepairedFiles = 0 }
    if (-not (Test-Path -LiteralPath $CbsPath)) { return $result }
    $lines = @(Get-Content -LiteralPath $CbsPath -Tail 5000)
    $lines = Get-CbsLinesSince -Lines $lines -Since $Since
    $repairing = $lines | Select-String -Pattern '\[SR\] Repairing (\d+) components' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value }
    if ($repairing) { $result.RepairingTotal = ($repairing | Measure-Object -Sum).Sum }
    $result.RepairedFiles = ($lines | Select-String -Pattern '\[SR\] Repaired ').Count
    return $result
}

function Get-DismLocalSource {
    param([string]$ManualSource)
    if ($ManualSource) {
        if (Test-Path -LiteralPath $ManualSource) {
            $item = Get-Item -LiteralPath $ManualSource
            if ($item.PSIsContainer) {
                $wim = Join-Path $ManualSource 'sources\install.wim'
                if (Test-Path -LiteralPath $wim) { return $wim }
                $esd = Join-Path $ManualSource 'sources\install.esd'
                if (Test-Path -LiteralPath $esd) { return $esd }
                return ''
            }
            if ($item.Extension -match '(?i)^\.(wim|esd)$') { return $ManualSource }
            return ''
        }
        return ''
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { -not [string]::IsNullOrEmpty($_.Root) })) {
        $wim = Join-Path $drive.Root 'sources\install.wim'
        if (Test-Path -LiteralPath $wim) { return $wim }
        $esd = Join-Path $drive.Root 'sources\install.esd'
        if (Test-Path -LiteralPath $esd) { return $esd }
    }
    return ''
}

function Get-PendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    try {
        $pfro = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($null -ne $pfro -and $null -ne $pfro.PendingFileRenameOperations) {
            $val = $pfro.PendingFileRenameOperations
            if ($val -is [array]) {
                if ($val.Count -gt 0) { return $true }
            }
            elseif (-not [string]::IsNullOrEmpty($val)) { return $true }
        }
    }
    catch { }
    return $false
}

function Get-UnrepairableSfcFiles {
    param(
        [datetime]$Since = [datetime]::MinValue,
        [string]$CbsPath = "$env:SystemRoot\Logs\CBS\CBS.log"
    )
    if (-not (Test-Path -LiteralPath $CbsPath)) { return @() }
    $lines = @(Get-Content -LiteralPath $CbsPath -Tail 5000)
    $lines = Get-CbsLinesSince -Lines $lines -Since $Since
    $names = @($lines |
        Select-String -Pattern '\[SR\] Cannot repair member file.*?"([^"]+)"' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Where-Object { $_ -ne '??' } | Select-Object -Unique)
    if ($null -eq $names) { return @() }
    return $names
}

function Get-ChkdskExitText {
    param([int]$ExitCode)
    if ($ExitCode -eq 0) { return 'No errors found' }
    if ($ExitCode -eq 1) { return 'Errors found and fixed' }
    if ($ExitCode -eq 2) { return 'Disk cleanup performed or not run' }
    if ($ExitCode -eq 3) { return 'Could not check the disk' }
    return 'Unknown result'
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$driveName = ($env:SystemDrive -replace ':$', '')
$freeBefore = (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue).Free
$restartRecommended = $false
$hadError = $false
$sfcResultText = 'See log'
$totalRunStart = Get-Date

$installText = ''
if ($null -ne $os.InstallDate) {
    $installAge = [Math]::Floor(((Get-Date) - $os.InstallDate).TotalDays)
    $installText = $os.InstallDate.ToString('yyyy-MM-dd') + ' (' + $installAge + ' days ago)'
}

Write-Log '====================================================================' -Color Cyan
Write-Log '  WINDOWS HEALTH REPAIR UTILITY BY KINGSTAN' -Color Cyan
Write-Log '====================================================================' -Color Cyan
Write-Log ('  Started : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Log ('  System  : ' + $os.Caption + ' (' + $os.Version + ')')
Write-Log ('  Machine : ' + $env:COMPUTERNAME)
Write-Log ('  Shell   : PowerShell ' + $PSVersionTable.PSVersion.ToString())
Write-Log ('  Config  : ' + $configSource)
if ($installText) { Write-Log ('  Installed : ' + $installText) }
Write-Log ('  Log     : ' + $LogFile)
Write-Log '====================================================================' -Color Cyan
Write-Log ''
Write-Log 'What this tool does: repairs the Windows component store (DISM),' -Color Magenta
Write-Log 'protected system files (SFC), then safely cleans up disk space.' -Color Magenta
Write-Log 'Total time: usually 10-30 minutes. Watch the progress below -' -Color Magenta
Write-Log 'do not close this window until it finishes.' -Color Magenta
if ($config.UseHighPriority) {
    Write-Log 'Running at High CPU priority - the machine may feel slower while it works.' -Color Magenta
}
if ($unknownConfigKeys.Count -gt 0) {
    Write-Log ('WARNING: Unknown config keys ignored: ' + ($unknownConfigKeys -join ', ')) -Color Yellow
}
Write-Log ''

Show-Progress 'Pre-flight'

Write-Log 'SYSTEM BASELINE:' -Color Cyan
try {
    $uptime = (Get-Date) - $os.LastBootUpTime
    if ($uptime -gt [TimeSpan]::Zero) {
        Write-Log ('  Uptime : ' + '{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)
    }
}
catch { }
try {
    $availMemGb = $os.FreePhysicalMemory / 1MB
    $totalMemGb = $os.TotalVisibleMemorySize / 1MB
    Write-Log ('  Memory : {0:N1} GB free of {1:N1} GB ({2:P0} free)' -f $availMemGb, $totalMemGb, ($availMemGb / $totalMemGb))
}
catch { }
try {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { -not [string]::IsNullOrEmpty($_.Root) -and $null -ne $_.Free })) {
        Write-Log ('  Drive  : {0} {1:N1} GB free of {2:N1} GB' -f $d.Name, ($d.Free / 1GB), (($d.Used + $d.Free) / 1GB))
    }
}
catch { }
try {
    $pending = Get-PendingReboot
    $pendingText = 'No'
    if ($pending) { $pendingText = 'Yes'; $restartRecommended = $true }
    Write-Log ('  Pending reboot : ' + $pendingText)
}
catch { }
try {
    $errSince = (Get-Date).AddHours(-24)
    $sysErrors = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $errSince } -ErrorAction SilentlyContinue)
    Write-Log ('  System errors (last 24h) : ' + $sysErrors.Count)
    if ($sysErrors.Count -gt 0) {
        try {
            $topErrors = $sysErrors | Group-Object -Property ProviderName | Sort-Object Count -Descending | Select-Object -First 3
            foreach ($g in $topErrors) {
                $sample = $g.Group[0]
                Write-Log ('    - {0} (ID {1}): {2} occurrence(s)' -f $g.Name, $sample.Id, $g.Count)
            }
        } catch { }
    }
}
catch { Write-Log '  System errors (last 24h) : unavailable' }
Write-Log ''

Write-Log 'PRE-FLIGHT: Admin mode confirmed. Running DISM quick health check (CheckHealth)...' -Color Cyan
$checkSw = [System.Diagnostics.Stopwatch]::StartNew()
$checkExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/CheckHealth') -Phase 'DISM CheckHealth' -StallWarnMinutes $config.StallWarnMinutes
$checkSw.Stop()
Write-Log ('CheckHealth exit code: ' + $checkExit + ' (0 = no known corruption flag)')
Add-PhaseResult -Name 'CheckHealth' -Detail ('exit ' + $checkExit) -Seconds $checkSw.Elapsed.TotalSeconds

$tcp = New-Object System.Net.Sockets.TcpClient
$connected = $false
try {
    $connected = $tcp.ConnectAsync('www.msftconnecttest.com', 443).Wait($config.TcpCheckTimeoutSeconds * 1000)
}
catch {
    $connected = $false
}
finally {
    $tcp.Dispose()
}
if (-not $connected -and -not $config.SafeRestoreOnly) {
    Write-Log 'WARNING: No internet connection detected. DISM RestoreHealth needs Windows Update to download repair files and may fail.' -Color Yellow
}

$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -lt 10) {
    Write-Log 'WARNING: This script targets Windows 10/11. Some commands may behave differently on this version.' -Color Yellow
}
if ($null -ne $freeBefore -and (($freeBefore / 1GB) -lt 5)) {
    Write-Log ('WARNING: Only {0:N1} GB free on the system drive. DISM RestoreHealth may need about 5 GB to download repair files.' -f ($freeBefore / 1GB)) -Color Yellow
}
if ($ReportOnly) {
    Write-Log 'REPORT-ONLY mode: no repairs or cleanup will be performed.' -Color Yellow
}

Write-Log ''
Write-Log '====================================================================' -Color Cyan
Write-Log 'PHASE 1: Repairing the Windows component store (DISM)' -Color Cyan
Write-Log '====================================================================' -Color Cyan

if ($config.RunDismScan) {
    if ($ReportOnly) { Show-Progress 'DISM ScanHealth (report)' } else { Show-Progress 'DISM ScanHealth' }
    Write-Log 'Running DISM ScanHealth - deep scan of the component store (no repairs).' -Color Green
    Write-Log 'Usually takes 1-10 minutes. It prints its own progress - a pause at one percentage is normal. Do not close this window.'
    $scanSw = [System.Diagnostics.Stopwatch]::StartNew()
    $dismScanExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/ScanHealth') -Phase 'DISM ScanHealth' -StallWarnMinutes $config.StallWarnMinutes
    $scanSw.Stop()
    Write-Log ('DISM ScanHealth finished with exit code ' + $dismScanExit)
    if ($null -ne $dismScanExit -and $dismScanExit -ne 0) { $hadError = $true }
    Add-PhaseResult -Name 'DISM ScanHealth' -Detail ('exit ' + $dismScanExit) -Seconds $scanSw.Elapsed.TotalSeconds
}
else {
    $dismScanExit = $null
    Write-Log 'DISM ScanHealth skipped (config: RunDismScan = false).' -Color Yellow
}

if ($config.RunDismRestore -and -not $ReportOnly) {
    Show-Progress 'DISM RestoreHealth'
    Write-Log 'Running DISM RestoreHealth - repairs the component store (SFC copies files from here).' -Color Green
    Write-Log 'This is the longest step: 10-30 minutes. It may pause at the same percentage while downloading repair files - that is normal. Do not close this window.'
    $repairSw = [System.Diagnostics.Stopwatch]::StartNew()
    $localSource = Get-DismLocalSource -ManualSource $Source
    $dismRepairExit = $null
    $restoreDetail = ''
    if ($config.SafeRestoreOnly) {
        if (-not $localSource) {
            $repairSw.Stop()
            $hadError = $true
            $restoreDetail = 'skipped (SafeRestoreOnly, no local source)'
            Write-Log 'SafeRestoreOnly is enabled: DISM RestoreHealth may only use a local source, but no install.wim/install.esd was found. Pass -Source or mount a Windows ISO. Skipping - nothing was downloaded from Windows Update.' -Color Yellow
        }
        else {
            Write-Log ('SafeRestoreOnly is enabled: restoring from local source only (no Windows Update): ' + $localSource) -Color Yellow
            $dismRepairExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth', ('/Source:' + $localSource), '/LimitAccess') -Phase 'DISM RestoreHealth (local source)' -StallWarnMinutes $config.StallWarnMinutes
        }
    }
    else {
        Write-Log 'Using Windows Update as the repair source. This requires an internet connection.' -Color Green
        $dismRepairExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth') -Phase 'DISM RestoreHealth' -StallWarnMinutes $config.StallWarnMinutes
        if ($null -ne $dismRepairExit -and $dismRepairExit -ne 0) {
            if ($localSource) {
                Write-Log ('Windows Update source failed; retrying with local source: ' + $localSource) -Color Yellow
                $dismRepairExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth', ('/Source:' + $localSource), '/LimitAccess') -Phase 'DISM RestoreHealth (local source)' -StallWarnMinutes $config.StallWarnMinutes
            }
        }
    }
    $repairSw.Stop()
    if ($null -ne $dismRepairExit) {
        Write-Log ('DISM RestoreHealth finished with exit code ' + $dismRepairExit)
        $restoreDetail = 'exit ' + $dismRepairExit
    }
    if ($null -ne $dismRepairExit -and $dismRepairExit -ne 0) {
        $hadError = $true
        if (-not $localSource) {
            Write-Log 'DISM reported an error and no local Windows ISO source was found (install.wim/install.esd). Mount a matching Windows ISO or run in Safe Mode with Networking, then try again.' -Color Yellow
        }
        else {
            Write-Log 'DISM failed even with a local source. The local ISO may not match this Windows build.' -Color Yellow
        }
        Add-LogTail -Path "$env:SystemRoot\Logs\DISM\dism.log" -Label 'DISM log'
    }
    Add-PhaseResult -Name 'DISM RestoreHealth' -Detail $restoreDetail -Seconds $repairSw.Elapsed.TotalSeconds
}
else {
    $dismRepairExit = $null
    if ($ReportOnly) {
        Write-Log 'DISM RestoreHealth skipped (report-only mode).' -Color Yellow
    }
    else {
        Write-Log 'DISM RestoreHealth skipped (config: RunDismRestore = false).' -Color Yellow
    }
}

Write-Log ''
Write-Log '====================================================================' -Color Cyan
Write-Log 'PHASE 2: Repairing protected system files (SFC)' -Color Cyan
Write-Log '====================================================================' -Color Cyan

if ($config.RunSfc) {
    Show-Progress 'SFC'
    $sfcArgs = '/scannow'
    if ($ReportOnly) {
        $sfcArgs = '/verifyonly'
        Write-Log 'Running sfc /verifyonly (report-only mode: verification, no repair). This can take 10-20 minutes.' -Color Green
    }
    else {
        Write-Log 'Running sfc /scannow - verifies and repairs protected system files.' -Color Green
        Write-Log 'Usually takes 10-20 minutes. It prints its own verification progress below. Do not close this window.'
    }
    $sfcSw = [System.Diagnostics.Stopwatch]::StartNew()
    $sfcExit = Invoke-NativeTool -FilePath 'sfc.exe' -ArgumentList $sfcArgs -Phase 'SFC' -StallWarnMinutes $config.SfcStallWarnMinutes
    Write-Log ('SFC finished with exit code ' + $sfcExit)

    $cbsResult = Get-SfcCbsResult -Since $totalRunStart
    $repairingAfterFirst = $cbsResult.RepairingTotal
    $repairedAfterFirst = $cbsResult.RepairedFiles
    if ($cbsResult.RepairingTotal -eq 0 -and $cbsResult.RepairedFiles -eq 0) {
        $sfcResultText = 'Healthy'
        Write-Log 'SFC result: verified via CBS.log - no components needed repair. System files are healthy.' -Color Green
    }
    elseif ($cbsResult.RepairingTotal -gt 0 -or $cbsResult.RepairedFiles -gt 0) {
        if ($ReportOnly) {
            $hadError = $true
            $sfcResultText = 'Violations found'
            Write-Log 'SFC result: verified via CBS.log - integrity violations were found. Run the script in normal mode to repair them.' -Color Yellow
        }
        else {
            $restartRecommended = $true
            $sfcResultText = 'Repaired'
            Write-Log 'SFC result: verified via CBS.log - repairs were applied. A restart is recommended.' -Color Green
        }
    }
    else {
        $sfcResultText = 'Undetermined'
        Write-Log 'SFC result: could not be determined from CBS.log. Details below.' -Color Yellow
        Add-LogTail -Path "$env:SystemRoot\Logs\CBS\CBS.log" -Label 'CBS log'
    }
    if ($ReportOnly -and $sfcExit -eq 1 -and $sfcResultText -eq 'Undetermined') {
        $hadError = $true
        $sfcResultText = 'Violations found'
        Write-Log 'SFC result: /verifyonly reported integrity violations (exit 1). Run the script in normal mode to repair them.' -Color Yellow
    }
    if (-not $ReportOnly -and $sfcResultText -eq 'Repaired') {
        Write-Log 'SFC reported repairs on the first pass. Running a second pass to catch dependent files the first pass may have missed...' -Color Yellow
        $sfcExit2 = Invoke-NativeTool -FilePath 'sfc.exe' -ArgumentList '/scannow' -Phase 'SFC (second pass)' -StallWarnMinutes $config.SfcStallWarnMinutes
        Write-Log ('SFC second pass finished with exit code ' + $sfcExit2)
        if ($null -ne $sfcExit2 -and $sfcExit2 -ne 0) { $sfcExit = $sfcExit2 }
        $cbsResult2 = Get-SfcCbsResult -Since $totalRunStart
        $newRepairing = [Math]::Max(0, $cbsResult2.RepairingTotal - $repairingAfterFirst)
        $newRepaired = [Math]::Max(0, $cbsResult2.RepairedFiles - $repairedAfterFirst)
        if ($newRepairing -eq 0 -and $newRepaired -eq 0) {
            $sfcResultText = 'Healthy'
            $sfcExit = $sfcExit2
            Write-Log 'SFC second pass: no components needed repair. System files are now healthy.' -Color Green
        }
        else {
            Write-Log 'SFC second pass: repairs were still applied. A restart is recommended.' -Color Green
        }
    }
    $sfcSw.Stop()
    if ($sfcExit -eq 2) {
        $restartRecommended = $true
        if ($sfcResultText -eq 'Healthy') { $sfcResultText = 'Pending reboot' }
        Write-Log 'SFC result: repairs are pending a reboot (exit 2). Restart to finish applying them.' -Color Yellow
    }
    elseif ($sfcExit -eq 3) {
        $hadError = $true
        Write-Log 'SFC result: could not repair some files (exit 3). Restart, then run this script again.' -Color Yellow
        $unrep = Get-UnrepairableSfcFiles -Since $totalRunStart
        if ($unrep.Count -gt 0) {
            Write-Log 'Files that could not be repaired:' -Color Yellow
            foreach ($f in $unrep) { Write-Log ('  - ' + $f) }
        }
        Write-Log 'Next steps: run chkdsk /scan to check the file system, then run this script again. If it still fails, the disk itself may be failing.' -Color Yellow
    }
    Add-PhaseResult -Name 'SFC' -Detail ($sfcResultText + ' (exit ' + $sfcExit + ')') -Seconds $sfcSw.Elapsed.TotalSeconds
}
else {
    Write-Log 'SFC skipped (config: RunSfc = false).' -Color Yellow
}

if ($config.RunChkdsk -and $CheckDisk -and -not $ReportOnly) {
    Show-Progress 'Disk check'
    Write-Log 'Running chkdsk /scan - online file-system check (no reboot needed).' -Color Green
    Write-Log 'Usually under 10 minutes. It prints its own progress. Do not close this window.'
    try {
        $dirtyOut = @(& fsutil.exe dirty query "$env:SystemDrive\" 2>$null)
        $dirtyText = $dirtyOut -join ' '
        if ($dirtyText -match '(?i:not dirty)') {
            Write-Log 'File system dirty bit: not set (no pending repair required).'
        }
        elseif ($dirtyText -match '(?i:dirty)') {
            Write-Log 'File system dirty bit: set - a repair is pending a reboot.' -Color Yellow
            $restartRecommended = $true
        }
        else {
            Write-Log 'File system dirty bit: could not be determined.'
        }
    }
    catch {
        Write-Log 'File system dirty bit: could not be determined.'
    }
    $chkSw = [System.Diagnostics.Stopwatch]::StartNew()
    $chkExit = Invoke-NativeTool -FilePath 'chkdsk.exe' -ArgumentList @("$env:SystemDrive", '/scan') -Phase 'Disk check (chkdsk)' -StallWarnMinutes $config.ChkdskStallWarnMinutes
    $chkSw.Stop()
    $chkText = Get-ChkdskExitText -ExitCode $chkExit
    Write-Log ('chkdsk finished with exit code ' + $chkExit + ' (' + $chkText + ')')
    if ($null -ne $chkExit -and $chkExit -ne 0) {
        $hadError = $true
        $restartRecommended = $true
        Write-Log 'File system errors were found. Run chkdsk /f during a reboot to repair them, then run this script again.' -Color Yellow
    }
    Add-PhaseResult -Name 'Disk check' -Detail ($chkText + ' (exit ' + $chkExit + ')') -Seconds $chkSw.Elapsed.TotalSeconds
}
else {
    if ($ReportOnly) {
        Write-Log 'Disk check skipped (report-only mode). Run with -CheckDisk to enable it.'
    }
    elseif (-not $CheckDisk) {
        Write-Log 'Disk check skipped (pass -CheckDisk to enable it).'
    }
    else {
        Write-Log 'Disk check skipped (config: RunChkdsk = false).'
    }
}

Write-Log ''
Write-Log '====================================================================' -Color Cyan
Write-Log 'PHASE 3: Disk cleanup' -Color Cyan
Write-Log '====================================================================' -Color Cyan

if ($config.RunComponentCleanup -and -not $ReportOnly) {
    Show-Progress 'Component cleanup'
    Write-Log 'Analyzing the component store (AnalyzeComponentStore) to report reclaimable space - usually under a minute.' -Color Green
    $analyzeSw = [System.Diagnostics.Stopwatch]::StartNew()
    $analyzeExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') -Phase 'AnalyzeComponentStore' -StallWarnMinutes $config.StallWarnMinutes
    $analyzeSw.Stop()
    Write-Log ('AnalyzeComponentStore finished with exit code ' + $analyzeExit)
    if ($null -ne $analyzeExit -and $analyzeExit -ne 0) { $hadError = $true }
    Add-PhaseResult -Name 'Component analysis' -Detail ('exit ' + $analyzeExit) -Seconds $analyzeSw.Elapsed.TotalSeconds
    Write-Log 'Cleaning up superseded components (StartComponentCleanup) - usually a few minutes. It prints its own progress. Do not close this window.' -Color Green
    $cleanupSw = [System.Diagnostics.Stopwatch]::StartNew()
    $cleanupExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/StartComponentCleanup') -Phase 'StartComponentCleanup' -StallWarnMinutes $config.StallWarnMinutes
    $cleanupSw.Stop()
    Write-Log ('StartComponentCleanup finished with exit code ' + $cleanupExit)
    if ($null -ne $cleanupExit -and $cleanupExit -ne 0) { $hadError = $true }
    Add-PhaseResult -Name 'Component cleanup' -Detail ('exit ' + $cleanupExit) -Seconds $cleanupSw.Elapsed.TotalSeconds
}
else {
    if ($ReportOnly) {
        Write-Log 'Component cleanup skipped (report-only mode).' -Color Yellow
    }
    else {
        Write-Log 'Component cleanup skipped (config: RunComponentCleanup = false).' -Color Yellow
    }
}

if ($config.RunWindowsUpdateCache -and -not $ReportOnly) {
    Show-Progress 'Windows Update cache'
    Write-Log 'Freeing Windows Update download cache...' -Color Green
    $wuSw = [System.Diagnostics.Stopwatch]::StartNew()
    $wuServices = @('wuauserv', 'dosvc', 'bits')
    $stopped = @()
    $alreadyStopped = @()
    $wasRunning = @{}
    foreach ($svc in $wuServices) {
        $svcObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $svcObj) {
            $wasRunning[$svc] = $false
            Write-Log ('Service ' + $svc + ' not present on this system.')
            continue
        }
        $wasRunning[$svc] = ($svcObj.Status -eq 'Running')
    }
    foreach ($svc in $wuServices) {
        if (-not $wasRunning[$svc]) {
            $alreadyStopped += $svc
            Write-Log ('Service ' + $svc + ' was already stopped - leaving it as-is.')
            continue
        }
        try {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            $stopped += $svc
            Write-Log ('Stopped service ' + $svc)
        }
        catch {
            Write-Log ('Could not stop service ' + $svc + ': ' + $_.Exception.Message) -Color Yellow
        }
    }
    $wuFreed = 0
    if ($stopped.Count + $alreadyStopped.Count -eq $wuServices.Count) {
        $wuCache = "$env:SystemRoot\SoftwareDistribution\Download"
        $wuSize = Get-DirSizeBytes -Path $wuCache
        Remove-TreeFast -Path $wuCache
        $wuFreed = (($wuSize - (Get-DirSizeBytes -Path $wuCache)) / 1MB)
        Write-Log ('Windows Update cache cleared (~{0:N1} MB freed)' -f [Math]::Max(0, $wuFreed))
    }
    else {
        Write-Log 'Skipping Windows Update cache (a service is still running; cache may be in use).' -Color Yellow
    }
    foreach ($svc in $wuServices) {
        if ($wasRunning[$svc]) {
            try {
                Start-Service -Name $svc -ErrorAction Stop
            }
            catch {
                Write-Log ('Could not restart service ' + $svc + ': ' + $_.Exception.Message) -Color Yellow
            }
        }
    }
    Write-Log 'Windows Update services restored to their previous state.'
    $wuSw.Stop()
    Add-PhaseResult -Name 'Windows Update cache' -Detail ('{0:N1} MB freed' -f [Math]::Max(0, $wuFreed)) -Seconds $wuSw.Elapsed.TotalSeconds
}
else {
    if ($ReportOnly) {
        Write-Log 'Windows Update cache cleanup skipped (report-only mode).' -Color Yellow
    }
    else {
        Write-Log 'Windows Update cache cleanup skipped (config: RunWindowsUpdateCache = false).' -Color Yellow
    }
}

if ($config.RunTempCleanup -and -not $ReportOnly) {
    Show-Progress 'Temp files'
    Write-Log 'Cleaning temporary files...' -Color Green
    $tempSw = [System.Diagnostics.Stopwatch]::StartNew()
    $tempTargets = @()
    if ($config.CleanCurrentUserTemp) { $tempTargets += $env:TEMP }
    if ($config.CleanSystemTemp) { $tempTargets += "$env:SystemRoot\Temp" }
    if ($config.CleanAllUsersTemp) {
        try {
            $usersRoot = Split-Path $env:USERPROFILE -Parent
            if (Test-Path -LiteralPath $usersRoot) {
                foreach ($userDir in (Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)) {
                    try {
                        $t = Join-Path $userDir.FullName 'AppData\Local\Temp'
                        if (Test-Path -LiteralPath $t) { $tempTargets += $t }
                    }
                    catch { }
                }
            }
        }
        catch { }
    }
    $totalFreed = [double]0
    $skipPaths = @($LogFile, $ScriptDir) + @($JsonLogFile | Where-Object { $_ })
    $skipPaths = @($skipPaths | ForEach-Object {
        $p = $_
        try { [System.IO.Path]::GetFullPath($p).TrimEnd('\') } catch { $p.TrimEnd('\') }
    })
    foreach ($target in ($tempTargets | Select-Object -Unique)) {
        $size = Get-DirSizeBytes -Path $target
        $items = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            $itemFull = $item.FullName.TrimEnd('\')
            if (Test-ProtectedPath -ItemPath $itemFull -SkipPaths $skipPaths) { continue }
            try {
                Remove-TreeFast -Path $item.FullName
            }
            catch { }
        }
        $freed = (($size - (Get-DirSizeBytes -Path $target)) / 1MB)
        $totalFreed += $freed
        Write-Log ('Cleaned ' + $target + ' (~{0:N1} MB freed)' -f [Math]::Max(0, $freed))
    }
    if ($totalFreed -gt 0) {
        Write-Log ('Total temporary files removed: ~{0:N1} MB' -f $totalFreed) -Color Green
    }
    $tempSw.Stop()
    Add-PhaseResult -Name 'Temp files' -Detail ('{0:N1} MB freed' -f [Math]::Max(0, $totalFreed)) -Seconds $tempSw.Elapsed.TotalSeconds
}
else {
    if ($ReportOnly) {
        Write-Log 'Temp cleanup skipped (report-only mode).' -Color Yellow
    }
    else {
        Write-Log 'Temp cleanup skipped (config: RunTempCleanup = false).' -Color Yellow
    }
}

if ($EmptyRecycleBin -and -not $ReportOnly) {
    Show-Progress 'Recycle bin'
    Write-Log 'Emptying the Recycle Bin...' -Color Green
    $rbSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Log 'Recycle Bin emptied.'
        $rbDetail = 'emptied'
    }
    catch {
        Write-Log ('Recycle Bin could not be emptied: ' + $_.Exception.Message) -Color Yellow
        $rbDetail = 'failed'
    }
    $rbSw.Stop()
    Add-PhaseResult -Name 'Recycle bin' -Detail $rbDetail -Seconds $rbSw.Elapsed.TotalSeconds
}
else {
    if ($ReportOnly) {
        Write-Log 'Recycle Bin left untouched (report-only mode).'
    }
    else {
        Write-Log 'Recycle Bin left untouched (run with -EmptyRecycleBin to clear it).'
    }
}

Write-Log ''
Write-Log '====================================================================' -Color Cyan
Write-Log 'SUMMARY' -Color Cyan
Write-Log '====================================================================' -Color Cyan
foreach ($r in $script:results) {
    Write-Log ('  {0,-22} {1,-36} {2}' -f $r.Name, $r.Detail, (Format-Duration $r.Seconds))
}
Write-Log '  --------------------------------------------------------------------'
$totalRun = ((Get-Date) - $totalRunStart).TotalSeconds
Write-Log ('  {0,-22} {1,-36} {2}' -f 'Total run time', '', (Format-Duration $totalRun))
$freeAfter = (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue).Free
if ($null -ne $freeBefore -and $null -ne $freeAfter) {
    $gbBefore = $freeBefore / 1GB
    $gbAfter = $freeAfter / 1GB
    $deltaNote = ''
    if ($gbAfter -lt $gbBefore) { $deltaNote = ' (delta includes concurrent system writes)' }
    Write-Log ('  {0,-22} {1,-36}{2}' -f 'Free disk space', ('{0:N1} GB -> {1:N1} GB' -f $gbBefore, $gbAfter), $deltaNote)
}
Write-Log ('  Full log saved to   : ' + $LogFile)
Write-Log '====================================================================' -Color Cyan

if ($config.CleanupOldLogs -and $config.LogRetentionCount -ge 1) {
    $oldLogs = @(Get-ChildItem -LiteralPath $LogDir -Filter 'WindowsHealthRepairUtility_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $config.LogRetentionCount)
    $oldJsonLogs = @(Get-ChildItem -LiteralPath $LogDir -Filter 'WindowsHealthRepairUtility_*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $config.LogRetentionCount)
    foreach ($l in ($oldLogs + $oldJsonLogs)) {
        Remove-Item -LiteralPath $l.FullName -Force -ErrorAction SilentlyContinue
    }
    $removed = $oldLogs.Count + $oldJsonLogs.Count
    if ($removed -gt 0) {
        Write-Log ('Log retention: removed ' + $removed + ' old log(s), keeping the last ' + $config.LogRetentionCount + '.')
    }
}

if ($hadError) {
    Write-Log ''
    Write-Log 'One or more phases reported errors. See the log for details.' -Color Yellow
}

if ($restartRecommended -and -not $ScheduledRun) {
    Write-Log ''
    Write-Log 'A restart is recommended to finish applying repairs.' -Color Yellow
    $answer = Read-Host 'Restart the computer now? (Y/N)'
    if ($answer -match '^[Yy]') {
        Restart-Computer -Force
    }
}
elseif ($restartRecommended -and $ScheduledRun) {
    Write-Log 'A restart is recommended to finish applying repairs (skipped prompt in scheduled mode).'
}

if ($config.ShowCompletionPopup -and -not $ScheduledRun) {
    $popupTitle = 'Windows Health Repair Utility - Complete'
    if ($hadError) { $popupTitle = 'Windows Health Repair Utility - Finished with errors' }
    $popupText = 'Windows Health Repair Utility has completed.' + [Environment]::NewLine
    $popupText += 'Full log: ' + $LogFile + [Environment]::NewLine
    if ($hadError) { $popupText += [Environment]::NewLine + 'Some phases reported errors - see the log for details.' }
    elseif ($restartRecommended) { $popupText += [Environment]::NewLine + 'A restart is recommended to finish applying repairs.' }
    try {
        (New-Object -ComObject WScript.Shell).Popup($popupText, 0, $popupTitle, 64) | Out-Null
    }
    catch { }
}

if ($Host.Name -eq 'ConsoleHost' -and -not $ScheduledRun) {
    Read-Host 'Press Enter to close'
}

if ($hadError) {
    exit 2
}
if ($restartRecommended) {
    exit 1
}
exit 0
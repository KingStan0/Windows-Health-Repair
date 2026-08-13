#Requires -Version 5.1

[CmdletBinding()]
param()

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    }
    catch {
        [Console]::WriteLine('This script requires Administrator privileges.')
        exit 1
    }
    exit
}

$LogDir = if ($PSScriptRoot) { $PSScriptRoot } else { $env:TEMP }
$LogFile = Join-Path $LogDir ('WindowsHealthRepair_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
try {
    Add-Content -Path $LogFile -Value '' -Encoding UTF8 -ErrorAction Stop
}
catch {
    $LogDir = $env:TEMP
    $LogFile = Join-Path $LogDir ('WindowsHealthRepair_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-Log {
    [CmdletBinding()]
    param(
        [string]$Message = '',
        [ValidateSet('Gray', 'Green', 'Yellow', 'Red', 'Cyan', 'Magenta')][string]$Color = 'Gray'
    )
    if ([string]::IsNullOrEmpty($Message)) {
        Write-Host ''
        return
    }
    $stamp = '[{0:HH:mm:ss}] ' -f (Get-Date)
    try { Add-Content -Path $LogFile -Value ($stamp + $Message) -Encoding UTF8 -ErrorAction Stop } catch { }
    Write-Host ($stamp + $Message) -ForegroundColor $Color
}

function Invoke-NativeTool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Phase,
        [int]$StallWarnMinutes = 10,
        [string]$OutputFile = ''
    )
    $useRedirect = [bool]$OutputFile
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $useRedirect
    if ($useRedirect) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $null
    $errTask = $null
    if ($useRedirect) {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
    }
    $lastCpu = $null
    $stallSeconds = 0
    $warned = $false
    while (-not $proc.WaitForExit(15000)) {
        $cpu = $proc.TotalProcessorTime.TotalSeconds
        if ($null -eq $lastCpu) {
            $lastCpu = $cpu
        }
        elseif ($cpu -eq $lastCpu) {
            $stallSeconds += 15
            if (-not $warned -and $stallSeconds -ge ($StallWarnMinutes * 60)) {
                Write-Log ('WARNING: {0} shows no CPU activity for {1} minutes. Long pauses are often normal during downloads. Do not kill it - let it finish.' -f $Phase, $StallWarnMinutes) -Color Yellow
                $warned = $true
            }
        }
        else {
            $lastCpu = $cpu
            $stallSeconds = 0
        }
    }
    if ($useRedirect -and $null -ne $outTask) {
        try { [System.IO.File]::WriteAllText($OutputFile, $outTask.Result) } catch { }
        try { [System.IO.File]::WriteAllText($OutputFile + '.err', $errTask.Result) } catch { }
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
    (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
}

function Get-SfcCbsResult {
    $result = @{ RepairingTotal = 0; RepairedFiles = 0 }
    $cbsPath = "$env:SystemRoot\Logs\CBS\CBS.log"
    if (-not (Test-Path -LiteralPath $cbsPath)) { return $result }
    $lines = Get-Content -LiteralPath $cbsPath -Tail 3000
    $repairing = $lines | Select-String -Pattern '\[SR\] Repairing (\d+) components' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value }
    if ($repairing) { $result.RepairingTotal = ($repairing | Measure-Object -Sum).Sum }
    $result.RepairedFiles = ($lines | Select-String -Pattern '\[SR\] Repaired ').Count
    return $result
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$restartRecommended = $false
$tempArtifacts = @()
$sfcResultText = 'See log'

Write-Log '=============================================================' -Color Cyan
Write-Log '  Windows Health Repair' -Color Cyan
Write-Log ('  Started: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Color Cyan
Write-Log ('  System : ' + $os.Caption + ' (' + $os.Version + ')') -Color Cyan
Write-Log ('  Log    : ' + $LogFile) -Color Cyan
Write-Log '=============================================================' -Color Cyan
Write-Log ''

Write-Log 'PRE-FLIGHT: Admin mode confirmed. Running DISM quick health check (CheckHealth)...' -Color Cyan
& dism.exe /Online /Cleanup-Image /CheckHealth | Out-Null
Write-Log ('CheckHealth exit code: ' + $LASTEXITCODE + ' (0 = no known corruption flag)')

$tcp = New-Object System.Net.Sockets.TcpClient
$connected = $false
try {
    $connected = $tcp.ConnectAsync('www.msftconnecttest.com', 443).Wait(5000)
}
catch {
    $connected = $false
}
finally {
    $tcp.Dispose()
}
if (-not $connected) {
    Write-Log 'WARNING: No internet connection detected. DISM RestoreHealth needs Windows Update to download repair files and may fail.' -Color Yellow
}

Write-Log ''
Write-Log '=============================================================' -Color Cyan
Write-Log 'PHASE 1: Repairing the Windows component store (DISM)' -Color Cyan
Write-Log '=============================================================' -Color Cyan

Write-Log 'Running DISM ScanHealth (deep scan, no repair) ...' -Color Green
$dismScanExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/ScanHealth') -Phase 'DISM ScanHealth'
Write-Log ('DISM ScanHealth finished with exit code ' + $dismScanExit)

Write-Log 'Running DISM RestoreHealth (scans and repairs, downloads from Windows Update). This can take 10-30 minutes and may look stuck at a percentage - that is normal.' -Color Green
$dismRepairExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth') -Phase 'DISM RestoreHealth' -StallWarnMinutes 12
Write-Log ('DISM RestoreHealth finished with exit code ' + $dismRepairExit)

if ($null -ne $dismRepairExit -and $dismRepairExit -ne 0) {
    $restartRecommended = $true
    Write-Log 'DISM reported an error. If the exit code or the log mentions 0x800f081f or 0x800f0906, Windows Update could not provide repair files. Next steps: boot into Safe Mode with Networking and run this script again, or re-run with a mounted Windows ISO as source.' -Color Yellow
    Add-LogTail -Path "$env:SystemRoot\Logs\DISM\dism.log" -Label 'DISM log'
}

Write-Log ''
Write-Log '=============================================================' -Color Cyan
Write-Log 'PHASE 2: Repairing protected system files (SFC)' -Color Cyan
Write-Log '=============================================================' -Color Cyan

Write-Log 'Running sfc /scannow. This usually takes 10-20 minutes.' -Color Green
$sfcTemp = Join-Path $env:TEMP ('sfc_out_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$tempArtifacts += @($sfcTemp, ($sfcTemp + '.err'))
$sfcOutput = ''
$sfcExit = -1
try {
    $sfcExit = Invoke-NativeTool -FilePath 'sfc.exe' -ArgumentList '/scannow' -Phase 'SFC' -StallWarnMinutes 15 -OutputFile $sfcTemp
    $sfcOutput = Get-Content -LiteralPath $sfcTemp -Raw -ErrorAction SilentlyContinue
    $sfcErr = Get-Content -LiteralPath ($sfcTemp + '.err') -Raw -ErrorAction SilentlyContinue
    $sfcCombined = [string]$sfcOutput + ' ' + [string]$sfcErr
    Write-Log ('SFC finished with exit code ' + $sfcExit)
}
finally {
    foreach ($artifact in $tempArtifacts) {
        Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
    }
}

if ($sfcCombined -match 'did not find any integrity violations') {
    $sfcResultText = 'Healthy'
    Write-Log 'SFC result: no integrity violations found. System files are healthy.' -Color Green
}
elseif ($sfcCombined -match 'found corrupt files and successfully repaired them') {
    $restartRecommended = $true
    $sfcResultText = 'Repaired'
    Write-Log 'SFC result: corrupt files were found and repaired. A restart is recommended.' -Color Green
}
elseif ($sfcCombined -match 'was unable to fix some of them') {
    $restartRecommended = $true
    $sfcResultText = 'Partially repaired'
    Write-Log 'SFC result: some corrupt files could not be repaired. Restart, then run this script again; if it persists, repair Phase 1 with a Windows ISO source.' -Color Yellow
}
else {
    $cbsResult = Get-SfcCbsResult
    if ($cbsResult.RepairingTotal -eq 0 -and $cbsResult.RepairedFiles -eq 0) {
        $sfcResultText = 'Healthy'
        Write-Log 'SFC result: verified via CBS.log - no components needed repair. System files are healthy.' -Color Green
    }
    elseif ($cbsResult.RepairingTotal -gt 0 -or $cbsResult.RepairedFiles -gt 0) {
        $restartRecommended = $true
        $sfcResultText = 'Repaired'
        Write-Log 'SFC result: verified via CBS.log - repairs were applied. A restart is recommended.' -Color Green
    }
    else {
        Write-Log 'SFC result: could not be determined from output or CBS.log. Details below.' -Color Yellow
        Add-LogTail -Path "$env:SystemRoot\Logs\CBS\CBS.log" -Label 'CBS log'
    }
}

Write-Log ''
Write-Log '=============================================================' -Color Cyan
Write-Log 'PHASE 3: Disk cleanup' -Color Cyan
Write-Log '=============================================================' -Color Cyan

Write-Log 'Cleaning up superseded components in the component store (StartComponentCleanup)...' -Color Green
$cleanupExit = Invoke-NativeTool -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/StartComponentCleanup') -Phase 'StartComponentCleanup'
Write-Log ('StartComponentCleanup finished with exit code ' + $cleanupExit)

Write-Log 'Freeing Windows Update download cache...' -Color Green
$wuServices = @('wuauserv', 'bits')
$stopped = @()
foreach ($svc in $wuServices) {
    try {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        $stopped += $svc
        Write-Log ('Stopped service ' + $svc)
    }
    catch {
        Write-Log ('Could not stop service ' + $svc + ': ' + $_.Exception.Message) -Color Yellow
    }
}
if ($stopped.Count -eq $wuServices.Count) {
    $wuCache = "$env:SystemRoot\SoftwareDistribution\Download"
    $wuSize = Get-DirSizeBytes -Path $wuCache
    Get-ChildItem -LiteralPath $wuCache -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $freed = (($wuSize - (Get-DirSizeBytes -Path $wuCache)) / 1MB)
    Write-Log ('Windows Update cache cleared (~{0:N1} MB freed)' -f [Math]::Max(0, $freed))
}
else {
    Write-Log 'Skipping Windows Update cache (a service could not be stopped; cache may be in use).' -Color Yellow
}
foreach ($svc in $wuServices) {
    Start-Service -Name $svc -ErrorAction SilentlyContinue
}
Write-Log 'Windows Update services restarted.'

Write-Log 'Cleaning temporary files...' -Color Green
$totalFreed = [double]0
foreach ($target in @($env:TEMP, "$env:SystemRoot\Temp")) {
    if (Test-Path -LiteralPath $target) {
        $size = Get-DirSizeBytes -Path $target
        Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $freed = (($size - (Get-DirSizeBytes -Path $target)) / 1MB)
        $totalFreed += $freed
        Write-Log ('Cleaned ' + $target + ' (~{0:N1} MB freed)' -f [Math]::Max(0, $freed))
    }
}
if ($totalFreed -gt 0) {
    Write-Log ('Total temporary files removed: ~{0:N1} MB' -f $totalFreed) -Color Green
}

Write-Log 'Emptying the Recycle Bin...' -Color Green
try {
    Clear-RecycleBin -Force -ErrorAction Stop
    Write-Log 'Recycle Bin emptied.'
}
catch {
    Write-Log ('Recycle Bin could not be emptied: ' + $_.Exception.Message) -Color Yellow
}

Write-Log ''
Write-Log '=============================================================' -Color Cyan
Write-Log 'SUMMARY' -Color Cyan
Write-Log '=============================================================' -Color Cyan
Write-Log ('DISM ScanHealth      : exit code ' + $dismScanExit)
Write-Log ('DISM RestoreHealth   : exit code ' + $dismRepairExit)
Write-Log ('SFC /scannow         : ' + $sfcResultText + ' (exit code ' + $sfcExit + ')')
Write-Log 'Disk cleanup         : completed (see details above)'
Write-Log ('Full log saved to   : ' + $LogFile)

if ($restartRecommended) {
    Write-Log ''
    Write-Log 'A restart is recommended to finish applying repairs.' -Color Yellow
    $answer = Read-Host 'Restart the computer now? (Y/N)'
    if ($answer -match '^[Yy]') {
        Restart-Computer -Force
    }
}

if ($Host.Name -eq 'ConsoleHost') {
    Read-Host 'Press Enter to close'
}
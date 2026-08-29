#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot '..\Repair-WindowsHealthUtility.ps1'
    $tokens = $null
    $parseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)

    function Get-DefinedFunction {
        param([string]$Name)
        $f = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object Name -eq $Name
        return $f
    }

    . ([scriptblock]::Create((Get-DefinedFunction 'Format-Duration').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-DismLocalSource').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-CbsLinesSince').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-SfcCbsResult').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Build-RelaunchArgs').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Coerce-ConfigValue').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-ChkdskExitText').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-UnrepairableSfcFiles').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-PendingReboot').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Test-ProtectedPath').Extent.Text))
}

Describe 'Script file sanity' {
    It 'parses without syntax errors' {
        $parseErrors.Count | Should -Be 0
    }

    It 'is ASCII-only (no BOM or non-ASCII characters)' {
        $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
        $nonAscii = $bytes | Where-Object { $_ -gt 127 }
        $nonAscii.Count | Should -Be 0
    }

    It 'contains no antivirus-flag heuristics (Bypass, Invoke-Expression, base64)' {
        $content = Get-Content -LiteralPath $ScriptPath -Raw
        $content | Should -Not -Match 'ExecutionPolicy[\s"''`]*Bypass'
        $content | Should -Not -Match 'Invoke-Expression'
        $content | Should -Not -Match 'FromBase64String'
    }

    It 'declares the parameter set' {
        $paramNames = $Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        foreach ($name in @('ReportOnly', 'Schedule', 'Unschedule', 'ScheduledRun', 'Source', 'EmptyRecycleBin', 'CheckDisk', 'LogPath', 'JsonLog')) {
            $paramNames | Should -Contain $name
        }
    }

    It 'supports WhatIf via SupportsShouldProcess' {
        $Ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } | ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' } | Should -Not -BeNullOrEmpty
        $body = $Ast.Extent.Text
        $body | Should -Match 'ShouldProcess'
    }

    It 'handles custom LogPath' {
        $body = $Ast.Extent.Text
        $body | Should -Match '\$LogPath'
        $body | Should -Match 'New-Item.*Directory'
    }

    It 'warns on unknown config keys' {
        $body = $Ast.Extent.Text
        $body | Should -Match 'unknownConfigKeys'
        $body | Should -Match 'Unknown config keys ignored'
    }

    It 'handles JsonLog switch' {
        $body = $Ast.Extent.Text
        $body | Should -Match '\$JsonLog'
        $body | Should -Match 'JsonLogFile'
    }

    It 'defines all required functions' {
        foreach ($name in @('Write-Log', 'Show-Progress', 'Add-PhaseResult', 'Format-Duration', 'Invoke-NativeTool', 'Get-SfcCbsResult', 'Get-CbsLinesSince', 'Get-DismLocalSource', 'Get-DirSizeBytes', 'Add-LogTail', 'Build-RelaunchArgs', 'Coerce-ConfigValue', 'Get-ChkdskExitText', 'Get-UnrepairableSfcFiles', 'Get-PendingReboot')) {
            Get-DefinedFunction $name | Should -Not -BeNullOrEmpty
        }
    }

    It 'adds the new config keys to defaults' {
        $defaultBlock = ($Ast.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
            Where-Object { $_.Extent.Text -match 'LogRetentionCount' } | Select-Object -First 1).Extent.Text
        $defaultBlock | Should -Match 'RunChkdsk'
        $defaultBlock | Should -Match 'ChkdskStallWarnMinutes'
        $defaultBlock | Should -Match 'SafeRestoreOnly'
    }

    It 'stops Delivery Optimization (dosvc) alongside wuauserv and bits' {
        $wuBlock = [regex]::Match($Ast.Extent.Text, 'wuServices = @\([^)]*\)').Value
        $wuBlock | Should -Match 'wuauserv'
        $wuBlock | Should -Match 'dosvc'
        $wuBlock | Should -Match 'bits'
    }

    It 'SafeRestoreOnly gates RestoreHealth behind a local source with /LimitAccess' {
        $body = $Ast.Extent.Text
        $body | Should -Match '\$config\.SafeRestoreOnly'
        $body | Should -Match 'Get-DismLocalSource -ManualSource \$Source'
        $body | Should -Match 'skipped \(SafeRestoreOnly, no local source\)'
    }

    It 'wraps all-users temp enumeration and deletion in try/catch' {
        $body = $Ast.Extent.Text
        $enum = [regex]::Match($body, '(?s)if \(\$config\.CleanAllUsersTemp\).*?Get-ChildItem -LiteralPath \$usersRoot -Directory')
        $enum.Success | Should -Be $true
        $enum.Value | Should -Match 'try \{'
        $del = [regex]::Match($body, '(?s)Remove-TreeFast -Path \$item\.FullName.*?catch')
        $del.Success | Should -Be $true
    }

    It 'never uses chkdsk /f or /r (which lock the volume or need a reboot)' {
        $chkLines = ($Ast.Extent.Text -split "`n") | Where-Object { $_ -match 'chkdsk' }
        ($chkLines -join "`n") | Should -Not -Match "chkdsk.*'/f'"
        ($chkLines -join "`n") | Should -Not -Match "chkdsk.*'/r'"
    }

    It 'has a fatal-error trap after the log function' {
        $trapNodes = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TrapStatementAst] }, $true)
        $trapNodes.Count | Should -Be 1
    }

    It 'uses the .NET Process API, not Start-Process, for tool execution' {
        $invoke = Get-DefinedFunction 'Invoke-NativeTool'
        $invoke.Extent.Text | Should -Not -Match 'Start-Process'
        $invoke.Extent.Text | Should -Match 'System.Diagnostics.ProcessStartInfo'
    }

    It 'null-guards all native exit-code comparisons' {
        $invoke = Get-DefinedFunction 'Invoke-NativeTool'
        $invoke.Extent.Text | Should -Match 'null -ne .*ExitCode'
    }

    It 'never redirects SFC output (so its native progress bar shows)' {
        $sfcLines = $Ast.Extent.Text -split "`n"
        $sfcCall = ($sfcLines | Where-Object { $_ -match 'sfc\.exe' }) -join "`n"
        $sfcCall | Should -Not -Match 'OutputFile'
    }

    It 'forwards bound parameters through the UAC relaunch' {
        $relaunch = (Get-DefinedFunction 'Build-RelaunchArgs').Extent.Text
        $relaunch | Should -Match 'BoundParameters'
        $relaunch | Should -Match 'RemoteSigned'
    }

    It 'handles SFC exit codes 2 (pending reboot) and 3 (failure)' {
        $body = $Ast.Extent.Text
        $body | Should -Match 'sfcExit -eq 2'
        $body | Should -Match 'sfcExit -eq 3'
    }

    It 'quotes native tool arguments (paths with spaces)' {
        $invoke = Get-DefinedFunction 'Invoke-NativeTool'
        $invoke.Extent.Text | Should -Match '-replace .*"'
    }

    It 'doubles trailing backslashes in native tool arguments' {
        $invoke = Get-DefinedFunction 'Invoke-NativeTool'
        $invoke.Extent.Text | Should -Match '\(\\\\\+\)\$'
    }

    It 'guards Show-Progress against zero totalSteps' {
        $sp = Get-DefinedFunction 'Show-Progress'
        $sp.Extent.Text | Should -Match 'totalSteps -le 0'
    }

    It 'writes blank lines to both console and log' {
        $wl = Get-DefinedFunction 'Write-Log'
        $wl.Extent.Text | Should -Match 'Add-Content.*LogFile'
        $wl.Extent.Text | Should -Match 'IsNullOrEmpty'
    }

    It 'validates DISM source file extensions' {
        $src = Get-DefinedFunction 'Get-DismLocalSource'
        $src.Extent.Text | Should -Match 'wim.*esd'
    }

    It 'checks additional reboot pending locations' {
        $body = $Ast.Extent.Text
        $body | Should -Match 'PackagesPending'
        $body | Should -Match 'PendingFileRenameOperations'
    }
}

Describe 'Build-RelaunchArgs' {
    It 'returns the base command when no parameters are bound' {
        $args = Build-RelaunchArgs -BoundParameters @{} -CommandPath 'C:\tools\Repair-WindowsHealthUtility.ps1'
        $args[0..3] | Should -Be @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File')
        $args[4] | Should -Be '"C:\tools\Repair-WindowsHealthUtility.ps1"'
        $args.Count | Should -Be 5
    }

    It 'appends bound switches as -Name' {
        $args = Build-RelaunchArgs -BoundParameters @{ ReportOnly = $true; EmptyRecycleBin = $false } -CommandPath 'C:\test.ps1'
        $args | Should -Contain '-ReportOnly'
        $args | Should -Not -Contain '-EmptyRecycleBin'
    }

    It 'appends bound values quoted' {
        $args = Build-RelaunchArgs -BoundParameters @{ Source = 'C:\My ISO\sources\install.wim' } -CommandPath 'C:\test.ps1'
        $args | Should -Contain '-Source'
        $args | Should -Contain '"C:\My ISO\sources\install.wim"'
    }

    It 'doubles trailing backslashes so the closing quote is not escaped' {
        $args = Build-RelaunchArgs -BoundParameters @{ Source = 'C:\My Path\' } -CommandPath 'C:\test.ps1'
        $args | Should -Contain '"C:\My Path\\"'
        $args2 = Build-RelaunchArgs -BoundParameters @{} -CommandPath 'C:\My Path\'
        $args2[4] | Should -Be '"C:\My Path\\"'
    }

    It 'escapes embedded double quotes' {
        $args = Build-RelaunchArgs -BoundParameters @{ Source = 'C:\My "Path' } -CommandPath 'C:\test.ps1'
        ($args -join ' ') | Should -Match '\\"'
    }
}

Describe 'Coerce-ConfigValue' {
    It 'converts string true/false to booleans' {
        Coerce-ConfigValue -DefaultValue $true -LoadedValue 'false' | Should -Be $false
        Coerce-ConfigValue -DefaultValue $false -LoadedValue 'true' | Should -Be $true
        Coerce-ConfigValue -DefaultValue $false -LoadedValue 'FALSE' | Should -Be $false
        Coerce-ConfigValue -DefaultValue $true -LoadedValue '1' | Should -Be $true
        Coerce-ConfigValue -DefaultValue $true -LoadedValue '0' | Should -Be $false
        Coerce-ConfigValue -DefaultValue $true -LoadedValue ' true ' | Should -Be $true
        Coerce-ConfigValue -DefaultValue $true -LoadedValue ' FALSE ' | Should -Be $false
        Coerce-ConfigValue -DefaultValue $true -LoadedValue ' 1 ' | Should -Be $true
        Coerce-ConfigValue -DefaultValue $true -LoadedValue ' yes ' | Should -Be $true
        Coerce-ConfigValue -DefaultValue $true -LoadedValue ' no ' | Should -Be $false
    }

    It 'converts string integers to integers with trimming' {
        Coerce-ConfigValue -DefaultValue 10 -LoadedValue ' 20 ' | Should -Be 20
        Coerce-ConfigValue -DefaultValue 10 -LoadedValue '0' | Should -Be 0
    }

    It 'passes through JSON booleans and other types unchanged' {
        Coerce-ConfigValue -DefaultValue $true -LoadedValue $false | Should -Be $false
        Coerce-ConfigValue -DefaultValue 10 -LoadedValue '10' | Should -Be 10
        Coerce-ConfigValue -DefaultValue 10 -LoadedValue 'notanint' | Should -Be 'notanint'
    }
}

Describe 'Get-SfcCbsResult' {
    BeforeAll {
        $cutoff = [datetime]'2026-08-14 12:00:00'
        $Cbs = Join-Path $TestDrive 'CBS.log'
        $before = '2026-08-14 11:00:00, Info                  [SR] Repairing 3 components'
        $afterRepair = '2026-08-14 13:00:00, Info                  [SR] Repairing 5 components'
        $afterDone = '2026-08-14 13:00:05, Info                  [SR] Repaired 2 files'
        $noMatch = '2026-08-14 14:00:00, Info                  some unrelated entry'
        Set-Content -LiteralPath $Cbs -Value @($before, $afterRepair, $afterDone, $noMatch) -Encoding UTF8
    }

    It 'only counts [SR] markers timestamped after the run start' {
        $r = Get-SfcCbsResult -Since $cutoff -CbsPath $Cbs
        $r.RepairingTotal | Should -Be 5
        $r.RepairedFiles | Should -Be 1
    }

    It 'counts nothing for a cutoff later than all entries' {
        $r = Get-SfcCbsResult -Since ([datetime]'2026-08-14 15:00:00') -CbsPath $Cbs
        $r.RepairingTotal | Should -Be 0
        $r.RepairedFiles | Should -Be 0
    }

    It 'falls back to the full tail when timestamps cannot be parsed' {
        $CbsNoTs = Join-Path $TestDrive 'CBS_nots.log'
        Set-Content -LiteralPath $CbsNoTs -Value @('no timestamp line [SR] Repairing 7 components') -Encoding UTF8
        $r = Get-SfcCbsResult -Since $cutoff -CbsPath $CbsNoTs
        $r.RepairingTotal | Should -Be 7
    }
}

Describe 'Get-CbsLinesSince' {
    It 'returns all lines when Since is MinValue' {
        $lines = @('2026-08-14 11:00:00, Info [SR] Repairing 1 components', '2026-08-14 13:00:00, Info [SR] Repairing 2 components')
        $r = Get-CbsLinesSince -Lines $lines -Since ([datetime]::MinValue)
        $r.Count | Should -Be 2
    }

    It 'filters to lines timestamped after Since' {
        $lines = @('2026-08-14 11:00:00, Info [SR] Repairing 1 components', '2026-08-14 13:00:00, Info [SR] Repairing 2 components')
        $r = Get-CbsLinesSince -Lines $lines -Since ([datetime]'2026-08-14 12:00:00')
        @($r).Count | Should -Be 1
        ($r -join ' ') | Should -Match '13:00:00'
    }

    It 'falls back to original lines when no timestamps are parseable' {
        $lines = @('no timestamp [SR] Repairing 5 components', 'also no ts [SR] Repaired 1 files')
        $r = Get-CbsLinesSince -Lines $lines -Since ([datetime]'2026-08-14 12:00:00')
        $r.Count | Should -Be 2
    }
}

Describe 'Format-Duration' {
    It 'formats seconds as minutes and seconds' {
        Format-Duration 90 | Should -Be '1m 30s'
        Format-Duration 5 | Should -Be '0m 05s'
        Format-Duration 0 | Should -Be '0m 00s'
        Format-Duration 3723 | Should -Be '62m 03s'
        Format-Duration 89.7 | Should -Be '1m 29s'
    }
}

Describe 'Get-DismLocalSource' {
    BeforeAll {
        $fake = Join-Path $TestDrive 'iso'
        New-Item -ItemType Directory -Path (Join-Path $fake 'sources') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $fake 'sources\install.wim') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $fake 'sources\install.esd') -Force | Out-Null
    }

    It 'returns the wim path for a folder containing sources\install.wim' {
        Get-DismLocalSource -ManualSource $fake | Should -Be (Join-Path $fake 'sources\install.wim')
    }

    It 'returns the file path when given a wim file directly' {
        Get-DismLocalSource -ManualSource (Join-Path $fake 'sources\install.wim') | Should -Be (Join-Path $fake 'sources\install.wim')
    }

    It 'returns empty for a missing path' {
        Get-DismLocalSource -ManualSource (Join-Path $fake 'nope') | Should -Be ''
    }

    It 'returns empty for a folder without an install image' {
        Get-DismLocalSource -ManualSource (Join-Path $fake 'sources') | Should -Be ''
    }

    It 'returns empty when no manual source is given' {
        Get-DismLocalSource -ManualSource '' | Should -Be ''
    }

    It 'returns empty for a file with an unsupported extension' {
        $bad = Join-Path $TestDrive 'bad.txt'
        Set-Content -LiteralPath $bad -Value 'dummy' -Encoding UTF8
        Get-DismLocalSource -ManualSource $bad | Should -Be ''
    }
}

Describe 'Get-ChkdskExitText' {
    It 'maps chkdsk exit codes to result text' {
        Get-ChkdskExitText -ExitCode 0 | Should -Be 'No errors found'
        Get-ChkdskExitText -ExitCode 1 | Should -Be 'Errors found and fixed'
        Get-ChkdskExitText -ExitCode 2 | Should -Be 'Disk cleanup performed or not run'
        Get-ChkdskExitText -ExitCode 3 | Should -Be 'Could not check the disk'
        Get-ChkdskExitText -ExitCode 99 | Should -Be 'Unknown result'
    }
}

Describe 'Test-ProtectedPath' {
    It 'protects an item that equals a skip path' {
        Test-ProtectedPath -ItemPath 'C:\x\script.ps1' -SkipPaths @('C:\x\script.ps1') | Should -Be $true
    }

    It 'protects an ancestor of a skip path' {
        Test-ProtectedPath -ItemPath 'C:\x' -SkipPaths @('C:\x\y\z') | Should -Be $true
    }

    It 'protects an item inside a skip path (script run from inside a temp target)' {
        Test-ProtectedPath -ItemPath 'C:\x\script.ps1' -SkipPaths @('C:\x') | Should -Be $true
    }

    It 'does not protect unrelated items' {
        Test-ProtectedPath -ItemPath 'C:\other' -SkipPaths @('C:\x') | Should -Be $false
    }

    It 'is case-insensitive' {
        Test-ProtectedPath -ItemPath 'c:\X\script.ps1' -SkipPaths @('C:\x') | Should -Be $true
    }
}

Describe 'Get-UnrepairableSfcFiles' {
    It 'extracts unique unrepairable file names from CBS.log lines' {
        $Cbs = Join-Path $TestDrive 'CBS.log'
        Set-Content -LiteralPath $Cbs -Value @(
            '2026-08-14 13:00:00, Info CSI 00000001 [SR] Cannot repair member file [l:12]""C:\Windows\System32\bad1.dll"" of Component'
            '2026-08-14 13:00:05, Info CSI 00000002 [SR] Cannot repair member file [l:12]""C:\Windows\System32\bad2.dll"" of Component'
            '2026-08-14 13:00:06, Info CSI 00000003 [SR] Cannot repair member file [l:12]""C:\Windows\System32\bad1.dll"" of Component'
            '2026-08-14 13:00:07, Info CSI 00000004 [SR] Repaired 1 files'
        ) -Encoding UTF8
        $r = Get-UnrepairableSfcFiles -CbsPath $Cbs
        $r | Should -Contain 'C:\Windows\System32\bad1.dll'
        $r | Should -Contain 'C:\Windows\System32\bad2.dll'
        ($r | Where-Object { $_ -eq 'C:\Windows\System32\bad1.dll' }).Count | Should -Be 1
    }

    It 'returns empty for a missing CBS.log' {
        $r = Get-UnrepairableSfcFiles -CbsPath (Join-Path $TestDrive 'nope.log')
        $r | Should -BeNullOrEmpty
    }

    It 'ignores the AppX ?? placeholder in Cannot repair member file lines' {
        $Cbs = Join-Path $TestDrive 'CBS2.log'
        Set-Content -LiteralPath $Cbs -Value @(
            '2026-08-14 13:00:00, Info CSI 00000001 [SR] Cannot repair member file [l:34{17}]"??" of AppX Microsoft.Windows.Cortana_1.0.0.0'
            '2026-08-14 13:00:05, Info CSI 00000002 [SR] Cannot repair member file [l:12]""C:\Windows\System32\bad3.dll"" of Component'
        ) -Encoding UTF8
        $r = Get-UnrepairableSfcFiles -CbsPath $Cbs
        $r | Should -Not -Contain '??'
        $r | Should -Contain 'C:\Windows\System32\bad3.dll'
    }

    It 'only returns unrepairable files timestamped after the run start' {
        $Cbs = Join-Path $TestDrive 'CBS_time.log'
        $cutoff = [datetime]'2026-08-14 12:00:00'
        Set-Content -LiteralPath $Cbs -Value @(
            '2026-08-14 11:00:00, Info CSI 00000001 [SR] Cannot repair member file [l:12]""C:\old.dll"" of Component'
            '2026-08-14 13:00:00, Info CSI 00000002 [SR] Cannot repair member file [l:12]""C:\new.dll"" of Component'
        ) -Encoding UTF8
        $r = Get-UnrepairableSfcFiles -Since $cutoff -CbsPath $Cbs
        $r | Should -Contain 'C:\new.dll'
        $r | Should -Not -Contain 'C:\old.dll'
    }
}

Describe 'Launcher batch file' {
    It 'forwards arguments passed to the .bat to the PowerShell script' {
        $bat = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Repair Windows Health Utility.bat') -Raw
        $bat | Should -Match '-File .*Repair-WindowsHealthUtility\.ps1" %\*'
    }

    It 'uses single quotes for Unblock-File (CMD-safe with spaces)' {
        $bat = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Repair Windows Health Utility.bat') -Raw
        $bat | Should -Match "Unblock-File -LiteralPath '.*'"
    }
}

#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot '..\Repair-WindowsHealth.ps1'
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
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-SfcCbsResult').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Build-RelaunchArgs').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Coerce-ConfigValue').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-ChkdskExitText').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-UnrepairableSfcFiles').Extent.Text))
    . ([scriptblock]::Create((Get-DefinedFunction 'Get-PendingReboot').Extent.Text))
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
        foreach ($name in @('ReportOnly', 'Schedule', 'Unschedule', 'ScheduledRun', 'Source', 'EmptyRecycleBin', 'CheckDisk')) {
            $paramNames | Should -Contain $name
        }
    }

    It 'defines all required functions' {
        foreach ($name in @('Write-Log', 'Show-Progress', 'Add-PhaseResult', 'Format-Duration', 'Invoke-NativeTool', 'Get-SfcCbsResult', 'Get-DismLocalSource', 'Get-DirSizeBytes', 'Add-LogTail', 'Build-RelaunchArgs', 'Coerce-ConfigValue', 'Get-ChkdskExitText', 'Get-UnrepairableSfcFiles', 'Get-PendingReboot')) {
            Get-DefinedFunction $name | Should -Not -BeNullOrEmpty
        }
    }

    It 'adds the Chkdsk config keys to defaults' {
        $defaultBlock = ($Ast.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
            Where-Object { $_.Extent.Text -match 'LogRetentionCount' } | Select-Object -First 1).Extent.Text
        $defaultBlock | Should -Match 'RunChkdsk'
        $defaultBlock | Should -Match 'ChkdskStallWarnMinutes'
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
}

Describe 'Build-RelaunchArgs' {
    It 'returns the base command when no parameters are bound' {
        $args = Build-RelaunchArgs -BoundParameters @{} -CommandPath 'C:\tools\Repair-WindowsHealth.ps1'
        $args[0..3] | Should -Be @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File')
        $args[4] | Should -Be '"C:\tools\Repair-WindowsHealth.ps1"'
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
}

Describe 'Coerce-ConfigValue' {
    It 'converts string true/false to booleans' {
        Coerce-ConfigValue -DefaultValue $true -LoadedValue 'false' | Should -Be $false
        Coerce-ConfigValue -DefaultValue $false -LoadedValue 'true' | Should -Be $true
        Coerce-ConfigValue -DefaultValue $false -LoadedValue 'FALSE' | Should -Be $false
        Coerce-ConfigValue -DefaultValue $true -LoadedValue '1' | Should -Be $true
        Coerce-ConfigValue -DefaultValue $true -LoadedValue '0' | Should -Be $false
    }

    It 'passes through JSON booleans and other types unchanged' {
        Coerce-ConfigValue -DefaultValue $true -LoadedValue $false | Should -Be $false
        Coerce-ConfigValue -DefaultValue 10 -LoadedValue '10' | Should -Be '10'
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
        Get-UnrepairableSfcFiles -CbsPath (Join-Path $TestDrive 'nope.log') | Should -Be $null
    }
}

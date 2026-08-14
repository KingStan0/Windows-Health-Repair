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

    It 'declares the v1.1 parameter set' {
        $paramNames = $Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        foreach ($name in @('ReportOnly', 'Schedule', 'Unschedule', 'ScheduledRun', 'Source', 'EmptyRecycleBin')) {
            $paramNames | Should -Contain $name
        }
    }

    It 'defines all required functions' {
        foreach ($name in @('Write-Log', 'Show-Progress', 'Add-PhaseResult', 'Format-Duration', 'Invoke-NativeTool', 'Get-SfcCbsResult', 'Get-DismLocalSource', 'Get-DirSizeBytes', 'Add-LogTail')) {
            Get-DefinedFunction $name | Should -Not -BeNullOrEmpty
        }
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

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
Describe 'clean-exports.ps1' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) "exports [$([guid]::NewGuid())]"
        # Brackets in the folder name: the script must use -LiteralPath.
        [IO.Directory]::CreateDirectory($Dir) | Out-Null
        foreach ($age in 40, 20) {
            $file = Join-Path $Dir "export-$age.csv"
            [IO.File]::WriteAllText($file, 'a')
            [IO.File]::SetLastWriteTime($file, (Get-Date).AddDays(-$age))
        }
        $script:Script = Join-Path $PSScriptRoot '..' 'clean-exports.ps1'
    }
    AfterEach { [IO.Directory]::Delete($script:Dir, $true) }

    It 'deletes the exports older than -Days' {
        & $Script -Days 10 -Path $Dir | Out-Null
        Test-Path -LiteralPath (Join-Path $Dir 'export-40.csv') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Dir 'export-20.csv') | Should -BeFalse
    }
    It 'keeps the exports younger than 30 days by default' {
        & $Script -Path $Dir | Out-Null
        Test-Path -LiteralPath (Join-Path $Dir 'export-40.csv') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Dir 'export-20.csv') | Should -BeTrue
    }
    It 'deletes nothing with -WhatIf, and lists what it would delete' {
        $out = & $Script -Path $Dir -WhatIf 6>&1 | Out-String
        Test-Path -LiteralPath (Join-Path $Dir 'export-40.csv') | Should -BeTrue
        $out | Should -Match '1 export'
    }
}

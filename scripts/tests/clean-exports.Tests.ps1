#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
Describe 'clean-exports.ps1' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) "exports-$([guid]::NewGuid())"
        New-Item -ItemType Directory $Dir | Out-Null
        $old = New-Item (Join-Path $Dir 'old.csv') -Value 'a'
        $old.LastWriteTime = (Get-Date).AddDays(-40)
        New-Item (Join-Path $Dir 'new.csv') -Value 'b' | Out-Null
        $script:Script = Join-Path $PSScriptRoot '..' 'clean-exports.ps1'
    }
    AfterEach { [IO.Directory]::Delete($script:Dir, $true) }

    It 'supprime les exports plus vieux que -Days' {
        & $Script -Days 30 -Path $Dir | Out-Null
        Test-Path (Join-Path $Dir 'old.csv') | Should -BeFalse
        Test-Path (Join-Path $Dir 'new.csv') | Should -BeTrue
    }
    It 'ne supprime rien avec -WhatIf' {
        & $Script -Days 30 -Path $Dir -WhatIf | Out-Null
        Test-Path (Join-Path $Dir 'old.csv') | Should -BeTrue
    }
}

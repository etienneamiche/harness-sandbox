BeforeAll { . $PSScriptRoot/Get-PageCount.ps1 }

Describe 'Get-PageCount' {
    It 'returns 0 when there is nothing to export' {
        Get-PageCount -Total 0 -PageSize 100 | Should -Be 0
    }
    It 'returns one page per full batch' {
        Get-PageCount -Total 500 -PageSize 100 | Should -Be 5
    }
}

BeforeAll { . $PSScriptRoot/Invoke-Retry.ps1 }

Describe 'Invoke-Retry' {
    It 'returns the result when the action succeeds at once' {
        Invoke-Retry -Action { 42 } -DelayMs 0 | Should -Be 42
    }
    It 'retries until the action succeeds' {
        $script:calls = 0
        $result = Invoke-Retry -DelayMs 0 -Action {
            $script:calls++
            if ($script:calls -lt 3) { throw 'not yet' }
            'ok'
        }
        $result | Should -Be 'ok'
        $script:calls | Should -Be 3
    }
}

#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }

BeforeAll {
    # Set before the import: the module loads its texts when imported.
    $script:previousCulture = [CultureInfo]::CurrentUICulture
    [CultureInfo]::CurrentUICulture = 'en-US'
    Import-Module (Join-Path $PSScriptRoot 'Pomodoro.psm1') -Force
    $script:scriptPath = Join-Path $PSScriptRoot 'pomodoro.ps1'
}

AfterAll {
    Remove-Module Pomodoro
    [CultureInfo]::CurrentUICulture = $script:previousCulture
}

Describe 'Pomodoro' {
    BeforeAll {
        Mock Start-Sleep -ModuleName Pomodoro { throw 'A test must never really sleep.' }
    }

    BeforeEach {
        $script:now = [DateTimeOffset]::new(2026, 1, 1, 9, 0, 0, [TimeSpan]::Zero)
        $script:clockCalls = 0
        $script:waits = [System.Collections.Generic.List[TimeSpan]]::new()
        $script:displays = [System.Collections.Generic.List[object]]::new()
        # Simulated time passing per second waited: keeps long sessions down to a few iterations.
        $script:scale = 60

        $script:clock = { $script:clockCalls++; $script:now }
        $script:wait = {
            param([TimeSpan] $Duration)
            $script:waits.Add($Duration)
            $script:now = $script:now.Add($Duration.Multiply($script:scale))
        }

        Mock Write-Host -ModuleName Pomodoro {
            $script:displays.Add([pscustomobject]@{ Text = $Object; NoNewline = [bool] $NoNewline })
        }
    }

    Context 'Duration' {
        It 'runs 25 minutes by default' {
            $session = Start-PomodoroSession -Clock $script:clock -Wait $script:wait

            $script:displays[0].Text | Should -Be "`r25:00"
            $session.PlannedMinutes | Should -Be 25
            ($session.EndedAt - $session.StartedAt) | Should -Be ([TimeSpan]::FromMinutes(25))
        }

        It 'runs the chosen duration' {
            $session = Start-PomodoroSession -Minutes 10 -Clock $script:clock -Wait $script:wait

            $script:displays[0].Text | Should -Be "`r10:00"
            ($session.EndedAt - $session.StartedAt) | Should -Be ([TimeSpan]::FromMinutes(10))
        }

        It 'accepts a duration given as text and returns it as an integer' {
            $session = Start-PomodoroSession -Minutes '10' -Clock $script:clock -Wait $script:wait

            $script:displays[0].Text | Should -Be "`r10:00"
            $session.PlannedMinutes | Should -Be 10
            $session.PlannedMinutes | Should -BeOfType [int]
        }

        It 'refuses <Value> before any start' -ForEach @(
            @{ Value = 0 }, @{ Value = -5 }, @{ Value = 181 }, @{ Value = 'abc' },
            @{ Value = 1.5 }, @{ Value = 2.5 }, @{ Value = '1.5' }, @{ Value = '1,5' }
        ) {
            { Start-PomodoroSession -Minutes $Value -Clock $script:clock -Wait $script:wait } | Should -Throw

            $script:clockCalls | Should -Be 0
            $script:waits.Count | Should -Be 0
        }
    }

    Context 'Remaining time' {
        It 'formats it as mm:ss beyond one hour' {
            $null = Start-PomodoroSession -Minutes 90 -Clock $script:clock -Wait $script:wait

            $script:displays[0].Text | Should -Be "`r90:00"
        }

        It 'rewrites it on the same line' {
            $null = Start-PomodoroSession -Minutes 2 -Clock $script:clock -Wait $script:wait

            $countdown = $script:displays | Select-Object -SkipLast 1
            $countdown.Text | Should -Be @("`r02:00", "`r01:00")
            $countdown.NoNewline | Should -Not -Contain $false
        }

        It 'never waits longer than one second' {
            $script:scale = 1

            $null = Start-PomodoroSession -Minutes 1 -Clock $script:clock -Wait $script:wait

            $script:waits.Count | Should -Be 60
            ($script:waits | Measure-Object -Property TotalSeconds -Maximum).Maximum | Should -BeLessOrEqual 1
        }

        It 'waits only for what remains and rounds the display up' {
            $script:scale = 59.5

            $null = Start-PomodoroSession -Minutes 1 -Clock $script:clock -Wait $script:wait

            $script:waits[1] | Should -Be ([TimeSpan]::FromSeconds(0.5))
            $script:displays[1].Text | Should -Be "`r00:01"
        }

        It 'follows the clock rather than the number of waits' {
            $script:scale = 300

            $null = Start-PomodoroSession -Clock $script:clock -Wait $script:wait

            $script:displays[1].Text | Should -Be "`r20:00"
        }
    }

    Context 'End of session' {
        It 'announces the end, and only the end' {
            $null = Start-PomodoroSession -Minutes 1 -Clock $script:clock -Wait $script:wait

            $script:displays[-1].Text | Should -Be "`rSéance terminée"
            $script:displays.Text | Should -Not -Contain "`rSéance interrompue"
        }

        It 'returns exactly one object with the session contract' {
            $sessions = @(Start-PomodoroSession -Minutes 1 -Clock $script:clock -Wait $script:wait)

            $sessions.Count | Should -Be 1
            $sessions[0].PSObject.Properties.Name | Should -Be @('PlannedMinutes', 'StartedAt', 'EndedAt')
            $sessions[0].PlannedMinutes | Should -BeOfType [int]
            $sessions[0].StartedAt | Should -BeOfType [DateTimeOffset]
            $sessions[0].EndedAt | Should -BeOfType [DateTimeOffset]
        }
    }

    Context 'Interruption' {
        BeforeEach {
            $script:interrupt = { throw 'Simulated Ctrl+C' }
        }

        It 'announces the interruption' {
            try { $null = Start-PomodoroSession -Clock $script:clock -Wait $script:interrupt } catch { $null = $_ }

            $script:displays[-1].Text | Should -Be "`rSéance interrompue"
        }

        It 'returns no object' {
            $sessions = [System.Collections.Generic.List[object]]::new()

            # Through a pipeline: an assignment would drop anything emitted before the throw.
            try { Start-PomodoroSession -Clock $script:clock -Wait $script:interrupt | ForEach-Object { $sessions.Add($_) } }
            catch { $null = $_ }

            $sessions.Count | Should -Be 0
        }

        It 'lets the exception reach the caller' {
            { Start-PomodoroSession -Clock $script:clock -Wait $script:interrupt } | Should -Throw 'Simulated Ctrl+C'
        }
    }

    Context 'Language' {
        It 'stays in French under an en-US interface culture' {
            $null = Start-PomodoroSession -Minutes 1 -Clock $script:clock -Wait $script:wait

            [CultureInfo]::CurrentUICulture.Name | Should -Be 'en-US'
            $script:displays[-1].Text | Should -Match 'Séance terminée'
        }
    }

    Context 'pomodoro.ps1' {
        BeforeEach {
            # Without this the mock keeps the module's validators and hides a script that lost its own.
            Mock Start-PomodoroSession { } -RemoveParameterValidation Minutes
        }

        It 'leaves the default duration to the module' {
            & $script:scriptPath

            Should -Invoke Start-PomodoroSession -Exactly 1 -ParameterFilter { $PesterBoundParameters.Count -eq 0 }
        }

        It 'forwards the chosen duration' {
            & $script:scriptPath -Minutes 10

            Should -Invoke Start-PomodoroSession -Exactly 1 -ParameterFilter { $Minutes -eq 10 }
        }

        It 'refuses <Value> before any start' -ForEach @(
            @{ Value = 0 }, @{ Value = -5 }, @{ Value = 181 }, @{ Value = 'abc' },
            @{ Value = 1.5 }, @{ Value = 2.5 }, @{ Value = '1.5' }, @{ Value = '1,5' }
        ) {
            { & $script:scriptPath -Minutes $Value } | Should -Throw

            Should -Invoke Start-PomodoroSession -Exactly 0
        }
    }

    # Keep last: it reads the calls recorded by every test above.
    It 'never called the real Start-Sleep' {
        Should -Invoke Start-Sleep -ModuleName Pomodoro -Exactly 0 -Scope Describe
    }
}

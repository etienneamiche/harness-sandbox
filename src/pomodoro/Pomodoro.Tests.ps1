#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }

BeforeAll {
    # Set before the import: the module loads its texts when imported.
    $script:previousCulture = [CultureInfo]::CurrentUICulture
    [CultureInfo]::CurrentUICulture = 'en-US'
    Import-Module (Join-Path $PSScriptRoot 'Pomodoro.psm1') -Force
    $script:scriptPath = Join-Path $PSScriptRoot 'pomodoro.ps1'
    $script:realLogPath = & (Get-Module Pomodoro) { $script:LogPath }
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

        $script:logPath = Join-Path $TestDrive "$([Guid]::NewGuid().ToString('N')).jsonl"
        $script:session = [pscustomobject]@{
            PlannedMinutes = 25
            EndedAt        = [DateTimeOffset]::new(2026, 11, 7, 14, 25, 0, [TimeSpan]::FromHours(1))
        }

        # Every test runs against a throwaway default journal: none can reach the user's real one.
        $script:defaultLogPath = Join-Path $TestDrive "$([Guid]::NewGuid().ToString('N'))-default.jsonl"
        & (Get-Module Pomodoro) { param($Path) $script:LogPath = $Path } $script:defaultLogPath

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
            & $script:scriptPath -LogPath $script:logPath

            Should -Invoke Start-PomodoroSession -Exactly 1 -ParameterFilter { $PesterBoundParameters.Count -eq 0 }
        }

        It 'forwards the chosen duration' {
            & $script:scriptPath -Minutes 10 -LogPath $script:logPath

            Should -Invoke Start-PomodoroSession -Exactly 1 -ParameterFilter { $Minutes -eq 10 }
        }

        It 'refuses <Value> before any start' -ForEach @(
            @{ Value = 0 }, @{ Value = -5 }, @{ Value = 181 }, @{ Value = 'abc' },
            @{ Value = 1.5 }, @{ Value = 2.5 }, @{ Value = '1.5' }, @{ Value = '1,5' }
        ) {
            { & $script:scriptPath -Minutes $Value -LogPath $script:logPath } | Should -Throw

            Should -Invoke Start-PomodoroSession -Exactly 0
        }
    }

    Context 'pomodoro.ps1 session log' {
        BeforeEach {
            # Inside pomodoro.ps1, $script: points at the script and the mock sees no test variable: state goes through a closure.
            $calls = @{ Clock = 0; Wait = 0; Interrupt = $false; Now = [DateTimeOffset]::new(2026, 1, 1, 9, 0, 0, [TimeSpan]::Zero) }
            $clock = { $calls.Clock++; $calls.Now }.GetNewClosure()
            $wait = {
                param([TimeSpan] $Duration)
                $calls.Wait++
                if ($calls.Interrupt) { throw 'Simulated Ctrl+C' }
                $calls.Now = $calls.Now.Add($Duration.Multiply(60))
            }.GetNewClosure()
            & (Get-Module Pomodoro) { param($Clock, $Wait) $script:TestClock = $Clock; $script:TestWait = $Wait } $clock $wait

            Mock Write-Host -ModuleName Pomodoro { }
            # The script does not expose -Clock and -Wait (ADR 0001): the real session runs behind it with the injected ones.
            Mock Start-PomodoroSession {
                & (Get-Module Pomodoro) { Start-PomodoroSession -Minutes 1 -Clock $script:TestClock -Wait $script:TestWait }
            }
        }

        It 'logs a finished session with its tag' {
            & $script:scriptPath -Tag ' dev ' -LogPath $script:logPath

            $entries = @(Get-PomodoroLog -Path $script:logPath)
            $entries.Count | Should -Be 1
            $entries[0].Minutes | Should -Be 1
            $entries[0].Tag | Should -Be 'dev'
        }

        It 'logs to the default journal without -LogPath' {
            & $script:scriptPath

            @(Get-PomodoroLog).Count | Should -Be 1
            $script:defaultLogPath | Should -Exist
        }

        It 'refuses the tag <Label> before the clock or the wait are called' -ForEach @(
            @{ Label = 'empty'; Value = '' }
            @{ Label = 'blank'; Value = '   ' }
            @{ Label = 'too long'; Value = 'x' * 51 }
            @{ Label = 'with a line feed'; Value = "a`nb" }
        ) {
            { & $script:scriptPath -Tag $Value -LogPath $script:logPath } | Should -Throw

            Should -Invoke Start-PomodoroSession -Exactly 0
            $calls.Clock | Should -Be 0
            $calls.Wait | Should -Be 0
            $script:logPath | Should -Not -Exist
        }

        It 'does not log a session interrupted by the wait' {
            $calls.Interrupt = $true

            { & $script:scriptPath -LogPath $script:logPath } | Should -Throw 'Simulated Ctrl+C'

            $calls.Wait | Should -Be 1
            $script:logPath | Should -Not -Exist
        }
    }

    Context 'pomodoro.ps1 exit code' {
        BeforeEach {
            # The child process inherits this folder: nothing it could write reaches the repository.
            Push-Location $TestDrive
        }

        AfterEach {
            Pop-Location
        }

        # -Minutes 1 bounds the run if a regression ever lets the session start.
        It 'exits with code 1 for a blank tag and writes nothing' {
            $null = pwsh -NoProfile -File $script:scriptPath -Minutes 1 -Tag '   ' -LogPath $script:logPath 2>&1

            $LASTEXITCODE | Should -Be 1
            $script:logPath | Should -Not -Exist
        }

        It 'exits with code 1 for an empty log path' {
            $null = pwsh -NoProfile -File $script:scriptPath -Minutes 1 -LogPath '' 2>&1

            $LASTEXITCODE | Should -Be 1
        }
    }

    Context 'Add-PomodoroLogEntry' {
        It 'creates no file without an input object' {
            @() | Add-PomodoroLogEntry -Path $script:logPath

            $script:logPath | Should -Not -Exist
        }

        It 'creates no file when the wait throws in the chain' {
            try {
                Start-PomodoroSession -Clock $script:clock -Wait { throw 'Simulated Ctrl+C' } |
                    Add-PomodoroLogEntry -Path $script:logPath
            }
            catch { $null = $_ }

            $script:logPath | Should -Not -Exist
        }

        It 'appends exactly one line and leaves the others byte for byte' {
            $existing = [Text.Encoding]::UTF8.GetBytes("{`"a`":1}`n{`"b`":`"é`"}`n")
            [IO.File]::WriteAllBytes($script:logPath, $existing)

            $script:session | Add-PomodoroLogEntry -Path $script:logPath

            $after = [IO.File]::ReadAllBytes($script:logPath)
            [Text.Encoding]::UTF8.GetString($after).Split("`n").Count - 1 | Should -Be 3
            [Convert]::ToHexString($after, 0, $existing.Length) | Should -Be ([Convert]::ToHexString($existing))
        }

        It 'starts on a new line when the journal does not end with a line feed' {
            $existing = [Text.Encoding]::UTF8.GetBytes('{"endedAt":"2026-11-07T14:25:00+01:00","minutes":25,"tag":"é"}')
            [IO.File]::WriteAllBytes($script:logPath, $existing)

            $script:session | Add-PomodoroLogEntry -Path $script:logPath

            $entries = @(Get-PomodoroLog -Path $script:logPath -WarningVariable warnings -WarningAction SilentlyContinue)
            $entries.Count | Should -Be 2
            $warnings.Count | Should -Be 0
            $entries[0].Tag | Should -BeExactly 'é'
            $after = [IO.File]::ReadAllBytes($script:logPath)
            [Convert]::ToHexString($after, 0, $existing.Length) | Should -Be ([Convert]::ToHexString($existing))
            $after[$existing.Length] | Should -Be 10
        }

        It 'starts on the first byte of an existing empty journal' {
            [IO.File]::WriteAllBytes($script:logPath, [byte[]]::new(0))

            $script:session | Add-PomodoroLogEntry -Path $script:logPath

            [IO.File]::ReadAllBytes($script:logPath)[0] | Should -Be ([byte][char]'{')
            @(Get-PomodoroLog -Path $script:logPath).Count | Should -Be 1
        }

        It 'writes one compact UTF-8 line without BOM' {
            $script:session | Add-PomodoroLogEntry -Tag 'dev' -Path $script:logPath

            $bytes = [IO.File]::ReadAllBytes($script:logPath)
            $bytes[0] | Should -Be ([byte][char]'{')
            $bytes[-1] | Should -Be 10
            [Text.Encoding]::UTF8.GetString($bytes) |
                Should -BeExactly "{`"endedAt`":`"2026-11-07T14:25:00.0000000+01:00`",`"minutes`":25,`"tag`":`"dev`"}`n"
        }

        It 'writes a null tag without -Tag' {
            $script:session | Add-PomodoroLogEntry -Path $script:logPath

            [IO.File]::ReadAllText($script:logPath) | Should -BeLike '*,"tag":null}*'
        }

        It 'keeps the tag as typed, without its outer spaces' {
            $script:session | Add-PomodoroLogEntry -Tag '  Écrire le "plan"  ' -Path $script:logPath

            (Get-PomodoroLog -Path $script:logPath).Tag | Should -BeExactly 'Écrire le "plan"'
        }

        It 'accepts a tag of 50 characters' {
            $script:session | Add-PomodoroLogEntry -Tag ('x' * 50) -Path $script:logPath

            (Get-PomodoroLog -Path $script:logPath).Tag.Length | Should -Be 50
        }

        It 'accepts a tag of 50 <Label>' -ForEach @(
            @{ Label = 'emoji'; Character = "`u{1F345}" }
            @{ Label = 'joined emoji'; Character = "`u{1F468}`u{200D}`u{1F469}" }
        ) {
            $tag = $Character * 50

            $script:session | Add-PomodoroLogEntry -Tag $tag -Path $script:logPath

            (Get-PomodoroLog -Path $script:logPath).Tag | Should -BeExactly $tag
        }

        It 'refuses the tag <Label> and writes nothing' -ForEach @(
            @{ Label = 'empty'; Value = '' }
            @{ Label = 'blank'; Value = '   ' }
            @{ Label = 'too long'; Value = 'x' * 51 }
            @{ Label = 'of 51 emoji'; Value = "`u{1F345}" * 51 }
            @{ Label = 'with an inner line feed'; Value = "a`nb" }
            @{ Label = 'with a final line feed'; Value = "a`n" }
            @{ Label = 'with a tab'; Value = "`ta" }
        ) {
            { $script:session | Add-PomodoroLogEntry -Tag $Value -Path $script:logPath } |
                Should -Throw -ExpectedMessage "*étiquette*"

            $script:logPath | Should -Not -Exist
        }

        It 'creates a missing parent folder' {
            $nested = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')) 'sub' 'sessions.jsonl'

            $script:session | Add-PomodoroLogEntry -Path $nested

            $nested | Should -Exist
        }

        It 'throws a translated error citing the path when it cannot write' {
            { $script:session | Add-PomodoroLogEntry -Path $TestDrive } |
                Should -Throw -ExpectedMessage "Impossible d'écrire dans le journal : $TestDrive"
        }

        It 'refuses a path outside the file system and creates nothing' {
            $path = 'HKCU:\pomodoro-test\sessions.jsonl'
            # A regression writes relative to the process folder: it must land in the test drive, not in the repository.
            $previous = [Environment]::CurrentDirectory
            [Environment]::CurrentDirectory = $TestDrive
            try {
                { $script:session | Add-PomodoroLogEntry -Path $path } |
                    Should -Throw -ExpectedMessage "Impossible d'écrire dans le journal : $path"
            }
            finally { [Environment]::CurrentDirectory = $previous }

            Join-Path $TestDrive 'HKEY_CURRENT_USER' | Should -Not -Exist
        }
    }

    Context 'Default journal path' {
        It 'lives in the local application data' {
            $expected = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'pomodoro', 'sessions.jsonl')

            $script:realLogPath | Should -Be $expected
        }

        It 'is shared by writing and reading' {
            $script:session | Add-PomodoroLogEntry

            $script:defaultLogPath | Should -Exist
            @(Get-PomodoroLog).Count | Should -Be 1
        }
    }

    Context 'Get-PomodoroLog' {
        It 'reads back what was written, in order and with the right types' {
            $second = [pscustomobject]@{
                EndedAt        = [DateTimeOffset]::new(2026, 11, 8, 8, 0, 0, [TimeSpan]::FromHours(9))
                PlannedMinutes = 50
            }
            $script:session | Add-PomodoroLogEntry -Tag 'dev' -Path $script:logPath
            $second | Add-PomodoroLogEntry -Path $script:logPath

            $entries = @(Get-PomodoroLog -Path $script:logPath)

            $entries.Count | Should -Be 2
            $entries[0].EndedAt | Should -BeOfType [DateTimeOffset]
            $entries[0].Minutes | Should -BeOfType [int]
            ($entries[0].EndedAt -eq $script:session.EndedAt) | Should -BeTrue
            $entries[0].Minutes | Should -Be 25
            $entries[0].Tag | Should -BeExactly 'dev'
            $entries[0].Tag | Should -BeOfType [string]
            ($entries[1].EndedAt -eq $second.EndedAt) | Should -BeTrue
            $entries[1].Minutes | Should -Be 50
            $entries[1].Tag | Should -BeNullOrEmpty
            $null -eq $entries[1].Tag | Should -BeTrue
        }

        It 'keeps the instant of a time repeated by the change to winter time' {
            # 02:30 happens twice that night in Central Europe: only the offset tells them apart.
            $ended = [DateTimeOffset]::new(2026, 10, 25, 2, 30, 0, [TimeSpan]::FromHours(2))
            [pscustomobject]@{ EndedAt = $ended; PlannedMinutes = 25 } | Add-PomodoroLogEntry -Path $script:logPath

            ((Get-PomodoroLog -Path $script:logPath).EndedAt -eq $ended) | Should -BeTrue
        }

        It 'leaves a tag that looks like a date as text' {
            $script:session | Add-PomodoroLogEntry -Tag '2026-11-07T14:25:00+01:00' -Path $script:logPath

            (Get-PomodoroLog -Path $script:logPath).Tag | Should -BeExactly '2026-11-07T14:25:00+01:00'
        }

        It 'renders a line without tag with a null Tag' {
            [IO.File]::WriteAllText($script:logPath, "{`"endedAt`":`"2026-11-07T14:25:00+01:00`",`"minutes`":25}`n")

            $entries = @(Get-PomodoroLog -Path $script:logPath)

            $entries.Count | Should -Be 1
            $null -eq $entries[0].Tag | Should -BeTrue
        }

        It 'returns nothing and no error when the journal is missing' {
            $entries = @(Get-PomodoroLog -Path $script:logPath -ErrorVariable errors)

            $entries.Count | Should -Be 0
            $errors.Count | Should -Be 0
        }

        It 'skips a line of invalid JSON with a translated warning citing its number' {
            $valid = "{`"endedAt`":`"2026-11-07T14:25:00+01:00`",`"minutes`":25,`"tag`":null}"
            [IO.File]::WriteAllText($script:logPath, "$valid`n{oops`n$valid`n")

            $entries = @(Get-PomodoroLog -Path $script:logPath -WarningVariable warnings -WarningAction SilentlyContinue)

            $entries.Count | Should -Be 2
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Be 'Journal : ligne 2 illisible, ignorée.'
        }

        It 'skips a line with <Label>' -ForEach @(
            @{ Label = 'no endedAt'; Line = '{"minutes":25,"tag":null}' }
            @{ Label = 'an unreadable endedAt'; Line = '{"endedAt":"soon","minutes":25,"tag":null}' }
            @{ Label = 'a numeric endedAt'; Line = '{"endedAt":5,"minutes":25,"tag":null}' }
            @{ Label = 'no minutes'; Line = '{"endedAt":"2026-11-07T14:25:00+01:00","tag":null}' }
            @{ Label = 'zero minutes'; Line = '{"endedAt":"2026-11-07T14:25:00+01:00","minutes":0,"tag":null}' }
            @{ Label = 'fractional minutes'; Line = '{"endedAt":"2026-11-07T14:25:00+01:00","minutes":1.5,"tag":null}' }
            @{ Label = 'minutes as text'; Line = '{"endedAt":"2026-11-07T14:25:00+01:00","minutes":"25","tag":null}' }
            @{ Label = 'a JSON value that is not an object'; Line = '5' }
        ) {
            [IO.File]::WriteAllText($script:logPath, "$Line`n")

            $entries = @(Get-PomodoroLog -Path $script:logPath -WarningVariable warnings -WarningAction SilentlyContinue)

            $entries.Count | Should -Be 0
            $warnings.Count | Should -Be 1
        }
    }

    Context 'Weekly summary' {
        BeforeAll {
            $script:fixedClock = { [DateTimeOffset]'2026-11-07T10:00:00+01:00' }

            function New-LogLine {
                param([string] $EndedAt, [int] $Minutes = 25, [AllowNull()] [object] $Tag = $null)
                [ordered]@{ endedAt = $EndedAt; minutes = $Minutes; tag = $Tag } | ConvertTo-Json -Compress
            }

            function Set-TestLog {
                param([string[]] $Line)
                [IO.File]::WriteAllText($script:logPath, (($Line -join "`n") + "`n"))
            }

            function Get-TestSummary {
                Get-PomodoroSummary -Path $script:logPath -Clock $script:fixedClock
            }
        }

        Context 'Window' {
            It 'goes from today minus 6 to today' {
                $summary = Get-TestSummary

                $summary.From | Should -Be ([datetime]'2026-11-01')
                $summary.To | Should -Be ([datetime]'2026-11-07')
            }

            It 'takes today in the offset of the clock' {
                # Already November 8th in UTC.
                $summary = Get-PomodoroSummary -Path $script:logPath -Clock { [DateTimeOffset]'2026-11-07T23:30:00-05:00' }

                $summary.To | Should -Be ([datetime]'2026-11-07')
            }

            It 'excludes <EndedAt>' -ForEach @(
                @{ EndedAt = '2026-10-31T23:59+01:00' }
                @{ EndedAt = '2026-11-08T00:10+01:00' }
            ) {
                Set-TestLog (New-LogLine $EndedAt)

                (Get-TestSummary).Sessions | Should -Be 0
            }

            It 'counts <EndedAt> on the day it was recorded' -ForEach @(
                @{ EndedAt = '2026-11-01T00:00+01:00'; Index = 0 }
                @{ EndedAt = '2026-11-07T23:59+01:00'; Index = 6 }
                # 2026-10-31 at 22:30 UTC: only the recorded offset puts it on November 1st.
                @{ EndedAt = '2026-11-01T00:30+02:00'; Index = 0 }
            ) {
                Set-TestLog (New-LogLine $EndedAt -Minutes 25)

                $summary = Get-TestSummary

                $summary.Sessions | Should -Be 1
                $summary.Days[$Index].Sessions | Should -Be 1
                $summary.Days[$Index].Minutes | Should -Be 25
            }

            It 'includes a session dated today but later than the clock' {
                Set-TestLog (New-LogLine '2026-11-07T18:00+01:00')

                (Get-TestSummary).Days[6].Sessions | Should -Be 1
            }
        }

        Context 'Offset on reading' {
            It 'keeps the offset <Offset> written in the line' -ForEach @(
                # Two offsets: at least one differs from the time zone of the machine.
                @{ Offset = '+02:00'; Expected = [TimeSpan]::FromHours(2) }
                @{ Offset = '-05:00'; Expected = [TimeSpan]::FromHours(-5) }
            ) {
                Set-TestLog (New-LogLine "2026-11-01T00:30:00$Offset")

                (Get-PomodoroLog -Path $script:logPath).EndedAt.Offset | Should -Be $Expected
            }
        }

        Context 'By day' {
            It 'always has 7 days, oldest first, with the empty ones at zero' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Minutes 25)
                    (New-LogLine '2026-11-02T10:00+01:00' -Minutes 30)
                )

                $days = (Get-TestSummary).Days

                $days.Date | Should -Be @(0..6 | ForEach-Object { ([datetime]'2026-11-01').AddDays($_) })
                $days.Sessions | Should -Be @(0, 2, 0, 0, 0, 0, 0)
                $days.Minutes | Should -Be @(0, 55, 0, 0, 0, 0, 0)
            }
        }

        Context 'By tag' {
            It 'groups regardless of case' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Tag 'Dev')
                    (New-LogLine '2026-11-03T09:00+01:00' -Tag 'dev')
                )

                $tags = @((Get-TestSummary).Tags)

                $tags.Count | Should -Be 1
                $tags[0].Sessions | Should -Be 2
                $tags[0].Minutes | Should -Be 50
            }

            It 'groups regardless of case under a culture where I and i differ' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Tag 'DIV')
                    (New-LogLine '2026-11-03T09:00+01:00' -Tag 'div')
                )
                $previous = [CultureInfo]::CurrentCulture
                [CultureInfo]::CurrentCulture = 'tr-TR'
                try { $tags = @((Get-TestSummary).Tags) }
                finally { [CultureInfo]::CurrentCulture = $previous }

                $tags.Count | Should -Be 1
            }

            It 'keeps the spelling of the first session in journal order, not in time' {
                Set-TestLog @(
                    (New-LogLine '2026-11-06T09:00+01:00' -Tag 'DEV')
                    (New-LogLine '2026-11-02T09:00+01:00' -Tag 'dev')
                )

                (Get-TestSummary).Tags[0].Label | Should -BeExactly 'DEV'
            }

            It 'ignores the spelling of a session outside the window' {
                Set-TestLog @(
                    (New-LogLine '2026-10-20T09:00+01:00' -Tag 'OLD')
                    (New-LogLine '2026-11-02T09:00+01:00' -Tag 'old')
                )

                (Get-TestSummary).Tags[0].Label | Should -BeExactly 'old'
            }

            It 'lists only the tags with a session in the window' {
                Set-TestLog @(
                    (New-LogLine '2026-10-20T09:00+01:00' -Tag 'old')
                    (New-LogLine '2026-11-02T09:00+01:00' -Tag 'dev')
                )

                (Get-TestSummary).Tags.Label | Should -Be @('dev')
            }

            It 'merges null, empty and blank tags into one last line, even with the most minutes' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Minutes 60)
                    (New-LogLine '2026-11-02T10:00+01:00' -Minutes 60 -Tag '')
                    (New-LogLine '2026-11-02T11:00+01:00' -Minutes 60 -Tag '   ')
                    (New-LogLine '2026-11-02T12:00+01:00' -Minutes 5 -Tag 'dev')
                )

                $tags = @((Get-TestSummary).Tags)
                $lines = @(Get-TestSummary | Format-PomodoroSummary)

                $tags.Count | Should -Be 2
                $tags[1].Sessions | Should -Be 3
                $tags[1].Minutes | Should -Be 180
                $lines[-3] | Should -BeLike '(sans étiquette)*'
            }

            It 'sorts by minutes descending' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Minutes 10 -Tag 'a')
                    (New-LogLine '2026-11-02T10:00+01:00' -Minutes 30 -Tag 'b')
                    (New-LogLine '2026-11-02T11:00+01:00' -Minutes 20 -Tag 'c')
                )

                (Get-TestSummary).Tags.Label | Should -Be @('b', 'c', 'a')
            }

            It 'breaks ties by label, ordinal and without case' {
                # Ordinal: é sorts after f, unlike in a French sort. Case-insensitive: b sorts before C.
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Tag 'é')
                    (New-LogLine '2026-11-02T10:00+01:00' -Tag 'f')
                    (New-LogLine '2026-11-02T11:00+01:00' -Tag 'C')
                    (New-LogLine '2026-11-02T12:00+01:00' -Tag 'b')
                )

                (Get-TestSummary).Tags.Label | Should -BeExactly @('b', 'C', 'f', 'é')
            }

            It 'accepts a tag named like a member of the dictionary' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Tag 'Values')
                    (New-LogLine '2026-11-02T10:00+01:00' -Tag 'Count')
                )

                (Get-TestSummary).Tags.Label | Should -BeExactly @('Count', 'Values')
            }
        }

        Context 'Total' {
            It 'equals the sum of the days and the sum of the tags' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Minutes 25 -Tag 'dev')
                    (New-LogLine '2026-11-03T09:00+01:00' -Minutes 30)
                    (New-LogLine '2026-11-07T09:00+01:00' -Minutes 50 -Tag 'docs')
                    (New-LogLine '2026-10-20T09:00+01:00' -Minutes 99 -Tag 'dev')
                )

                $summary = Get-TestSummary

                $summary.Sessions | Should -Be 3
                $summary.Minutes | Should -Be 105
                ($summary.Days | Measure-Object Sessions -Sum).Sum | Should -Be $summary.Sessions
                ($summary.Days | Measure-Object Minutes -Sum).Sum | Should -Be $summary.Minutes
                ($summary.Tags | Measure-Object Sessions -Sum).Sum | Should -Be $summary.Sessions
                ($summary.Tags | Measure-Object Minutes -Sum).Sum | Should -Be $summary.Minutes
            }
        }

        Context 'Format' {
            BeforeEach {
                $script:previousCulture2 = [CultureInfo]::CurrentCulture
                # The dates must come from the language file, not from the machine.
                [CultureInfo]::CurrentCulture = 'en-US'
            }

            AfterEach {
                [CultureInfo]::CurrentCulture = $script:previousCulture2
            }

            It 'matches the expected text, line by line' {
                Set-TestLog @(
                    (New-LogLine '2026-11-02T09:00+01:00' -Minutes 25 -Tag 'dev')
                    (New-LogLine '2026-11-02T10:00+01:00' -Minutes 25)
                    (New-LogLine '2026-11-07T08:00+01:00' -Minutes 25 -Tag 'dev')
                    (New-LogLine '2026-11-07T09:00+01:00' -Minutes 25 -Tag 'Dev')
                    (New-LogLine '2026-11-07T09:30+01:00' -Minutes 25)
                )

                $lines = @(Get-TestSummary | Format-PomodoroSummary)

                $lines | Should -BeExactly @(
                    'Pomodoro : du dim. 01/11/2026 au sam. 07/11/2026'
                    ''
                    'Jour              Séances  Minutes'
                    'dim. 01/11/2026         0        0'
                    'lun. 02/11/2026         2       50'
                    'mar. 03/11/2026         0        0'
                    'mer. 04/11/2026         0        0'
                    'jeu. 05/11/2026         0        0'
                    'ven. 06/11/2026         0        0'
                    'sam. 07/11/2026         3       75'
                    ''
                    'Étiquette         Séances  Minutes'
                    'dev                     3       75'
                    '(sans étiquette)        2       50'
                    ''
                    'Total                   5      125'
                )
            }

            It 'lets a tag longer than the column overflow, without truncating it' {
                Set-TestLog (New-LogLine '2026-11-02T09:00+01:00' -Tag 'etiquette-tres-longue')

                $lines = @(Get-TestSummary | Format-PomodoroSummary)

                $lines | Should -Contain 'etiquette-tres-longue        1       25'
            }
        }

        Context 'Missing or empty journal' {
            It 'shows 7 days at zero and the empty message when the journal is <Label>' -ForEach @(
                @{ Label = 'missing'; Create = $false }
                @{ Label = 'empty'; Create = $true }
            ) {
                if ($Create) { [IO.File]::WriteAllBytes($script:logPath, [byte[]]::new(0)) }

                # Redirected: -ErrorVariable and -WarningVariable do not see what the inner Get-PomodoroLog writes.
                $output = @(Get-TestSummary 2>&1 3>&1)
                $output.Count | Should -Be 1
                $summary = $output[0]
                $lines = @($summary | Format-PomodoroSummary)

                $summary.Days.Count | Should -Be 7
                $summary.Days.Sessions | Should -Be @(0, 0, 0, 0, 0, 0, 0)
                $summary.Days.Minutes | Should -Be @(0, 0, 0, 0, 0, 0, 0)
                @($summary.Tags).Count | Should -Be 0
                $lines[10..12] | Should -Be @('', 'Aucune séance sur cette période.', '')
                $lines[13] | Should -Be 'Total                   0        0'
                $lines.Count | Should -Be 14
            }

            It 'warns about an unreadable line and counts the others' {
                [IO.File]::WriteAllText($script:logPath, "$(New-LogLine '2026-11-02T09:00+01:00')`n{oops`n$(New-LogLine '2026-11-03T09:00+01:00')`n")

                $output = @(Get-TestSummary 3>&1)
                $warnings = @($output | Where-Object { $_ -is [Management.Automation.WarningRecord] })

                ($output | Where-Object { $_ -isnot [Management.Automation.WarningRecord] }).Sessions | Should -Be 2
                $warnings.Count | Should -Be 1
                $warnings[0].Message | Should -Be 'Journal : ligne 2 illisible, ignorée.'
            }
        }

        Context 'pomodoro.ps1 -Summary' {
            BeforeEach {
                Mock Start-PomodoroSession { }
                Mock Add-PomodoroLogEntry { }
                Mock Get-PomodoroSummary { }
            }

            It 'starts no session and writes nothing' {
                & $script:scriptPath -Summary -LogPath $script:logPath

                Should -Invoke Start-PomodoroSession -Exactly 0
                Should -Invoke Add-PomodoroLogEntry -Exactly 0
            }

            It 'forwards -Path when -LogPath is given' {
                & $script:scriptPath -Summary -LogPath $script:logPath

                Should -Invoke Get-PomodoroSummary -Exactly 1 -ParameterFilter { $Path -eq $script:logPath }
            }

            It 'forwards nothing without -LogPath, even with -Tag' {
                & $script:scriptPath -Summary -Tag 'dev'

                Should -Invoke Get-PomodoroSummary -Exactly 1 -ParameterFilter { $PesterBoundParameters.Count -eq 0 }
            }

            It 'runs a session with -Summary:$false, without forwarding the switch' {
                & $script:scriptPath -Summary:$false -LogPath $script:logPath

                Should -Invoke Get-PomodoroSummary -Exactly 0
                Should -Invoke Start-PomodoroSession -Exactly 1 -ParameterFilter { $PesterBoundParameters.Count -eq 0 }
            }
        }

        Context 'pomodoro.ps1 -Summary, as a process' {
            BeforeEach {
                Push-Location $TestDrive
                # An alias wins over the module's function: the fixed clock stays off the command line (ADR 0001).
                $script:fixedClockRunner = Join-Path $TestDrive 'run-with-fixed-clock.ps1'
                Set-Content -LiteralPath $script:fixedClockRunner -Value @'
param($ScriptPath, $LogPath)
function global:Get-FixedClockSummary { Pomodoro\Get-PomodoroSummary @args -Clock { [DateTimeOffset]'2026-11-07T10:00:00+01:00' } }
Set-Alias -Name Get-PomodoroSummary -Value Get-FixedClockSummary -Scope Global
& $ScriptPath -Summary -LogPath $LogPath
exit $LASTEXITCODE
'@
            }

            AfterEach {
                Pop-Location
            }

            It 'prints the summary, exits with code 0 and leaves the journal untouched' {
                Set-TestLog (New-LogLine '2026-11-02T09:00+01:00' -Tag 'dev')
                $before = (Get-FileHash -LiteralPath $script:logPath).Hash

                $output = @(pwsh -NoProfile -File $script:fixedClockRunner $script:scriptPath $script:logPath 2>&1)

                $LASTEXITCODE | Should -Be 0
                $output[0] | Should -Be 'Pomodoro : du dim. 01/11/2026 au sam. 07/11/2026'
                $output[-1] | Should -Be 'Total                   1       25'
                (Get-FileHash -LiteralPath $script:logPath).Hash | Should -Be $before
            }

            It 'exits with code 0 without error and creates nothing when the journal is missing' {
                $output = @(pwsh -NoProfile -File $script:fixedClockRunner $script:scriptPath $script:logPath 2>&1)

                $LASTEXITCODE | Should -Be 0
                @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count | Should -Be 0
                $output[-1] | Should -Be 'Total                   0        0'
                $script:logPath | Should -Not -Exist
            }
        }
    }

    # Keep last: it reads the calls recorded by every test above.
    It 'never called the real Start-Sleep' {
        Should -Invoke Start-Sleep -ModuleName Pomodoro -Exactly 0 -Scope Describe
    }
}

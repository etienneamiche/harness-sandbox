#Requires -Version 7.4

# The culture is forced: French is the only language shipped, whatever the user's locale.
$script:Messages = Import-LocalizedData -BaseDirectory $PSScriptRoot -FileName Pomodoro.psd1 -UICulture fr-FR

$script:LogPath = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'pomodoro', 'sessions.jsonl')

function Start-PomodoroSession {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Text on purpose: [int] and [decimal] would turn 1.5 into 2 and '1,5' into 15 before any validation.
        [ValidatePattern('^\d+$')]
        [ValidateRange(1, 180)]
        [string] $Minutes = 25,

        [scriptblock] $Clock = { [DateTimeOffset]::Now },

        [scriptblock] $Wait = { param([TimeSpan] $Duration) Start-Sleep -Duration $Duration }
    )

    [DateTimeOffset] $startedAt = & $Clock
    $plannedMinutes = [int] $Minutes
    $endsAt = $startedAt.AddMinutes($plannedMinutes)
    $now = $startedAt
    $reachedEnd = $false

    try {
        while (($remaining = $endsAt - $now) -gt [TimeSpan]::Zero) {
            # Rounded up: the display starts on the full duration and only shows 00:00 once it is over.
            $seconds = [int] [Math]::Ceiling($remaining.TotalSeconds)
            Write-Host -NoNewline ("`r{0:00}:{1:00}" -f [Math]::Floor($seconds / 60), ($seconds % 60))

            $null = & $Wait ([TimeSpan]::FromTicks([Math]::Min($remaining.Ticks, [TimeSpan]::TicksPerSecond)))
            $now = & $Clock
        }
        $reachedEnd = $true
    }
    finally {
        if (-not $reachedEnd) {
            Write-Host "`r$($script:Messages.Interrupted)"
        }
    }

    Write-Host "`r$($script:Messages.Completed)"
    [pscustomobject]@{
        PlannedMinutes = $plannedMinutes
        StartedAt      = $startedAt
        EndedAt        = $now
    }
}

function Add-PomodoroLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [DateTimeOffset] $EndedAt,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [int] $PlannedMinutes,

        # Validated at binding, before any command of the pipeline runs: an invalid tag prevents the session from starting.
        [ValidateScript({
                # Perceived characters: .Length counts two units per emoji.
                if ($_ -match '\p{Cc}' -or [Globalization.StringInfo]::new($_.Trim()).LengthInTextElements -notin 1..50) { throw $script:Messages.InvalidTag }
                $true
            })]
        [string] $Tag,

        [ValidateNotNullOrEmpty()]
        [string] $Path = $script:LogPath
    )

    process {
        $line = [ordered]@{
            endedAt = $EndedAt.ToString('o')
            minutes = $PlannedMinutes
            tag     = if ($PSBoundParameters.ContainsKey('Tag')) { $Tag.Trim() }
        } | ConvertTo-Json -Compress

        try {
            $provider = $drive = $null
            $file = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref] $provider, [ref] $drive)
            # .NET would take a registry path for a relative file path and write under the current directory.
            if ($provider.Name -ne 'FileSystem') { throw }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
            # A journal edited by hand may not end with a line feed: the new line must not stick to the last one.
            $separator = ''
            if ([IO.File]::Exists($file)) {
                $stream = [IO.File]::OpenRead($file)
                try {
                    if ($stream.Length -gt 0) {
                        $stream.Position = $stream.Length - 1
                        if ($stream.ReadByte() -ne 10) { $separator = "`n" }
                    }
                }
                finally { $stream.Dispose() }
            }
            # shortcut: no file lock, two sessions ending at the same instant may collide
            [IO.File]::AppendAllText($file, "$separator$line`n", [Text.UTF8Encoding]::new($false))
        }
        catch {
            throw ($script:Messages.LogWriteFailed -f $Path)
        }
    }
}

function Get-PomodoroLog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $script:LogPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        $lineNumber++
        $entry = $null
        try {
            # System.Text.Json rather than ConvertFrom-Json, which turns any ISO text into a local [DateTime], tags included.
            $root = [System.Text.Json.JsonDocument]::Parse($line).RootElement
            $endedAt = $root.GetProperty('endedAt').GetDateTimeOffset()
            $minutes = $root.GetProperty('minutes').GetInt32()
            $tag = [System.Text.Json.JsonElement]::new()
            $hasTag = $root.TryGetProperty('tag', [ref] $tag) -and $tag.ValueKind -eq 'String'
            if ($minutes -ge 1) {
                $entry = [pscustomobject]@{
                    EndedAt = $endedAt
                    Minutes = $minutes
                    Tag     = if ($hasTag) { $tag.GetString() }
                }
            }
        }
        catch {
            # The parser only reports an unreadable line by throwing: the warning below covers it.
            $null = $_
        }

        if ($entry) { $entry } else { Write-Warning ($script:Messages.LogLineIgnored -f $lineNumber) }
    }
}

Export-ModuleMember -Function Start-PomodoroSession, Add-PomodoroLogEntry, Get-PomodoroLog

#Requires -Version 7.4

# The culture is forced: French is the only language shipped, whatever the user's locale.
$script:Messages = Import-LocalizedData -BaseDirectory $PSScriptRoot -FileName Pomodoro.psd1 -UICulture fr-FR

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

Export-ModuleMember -Function Start-PomodoroSession

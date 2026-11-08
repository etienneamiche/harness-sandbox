#Requires -Version 7.4

[CmdletBinding()]
param(
    # No default here: Start-PomodoroSession owns it. Text on purpose, see the module.
    [ValidatePattern('^\d+$')]
    [ValidateRange(1, 180)]
    [string] $Minutes
)

Import-Module (Join-Path $PSScriptRoot 'Pomodoro.psm1')
Start-PomodoroSession @PSBoundParameters

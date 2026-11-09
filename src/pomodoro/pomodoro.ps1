#Requires -Version 7.4

[CmdletBinding()]
param(
    # No default here: Start-PomodoroSession owns it. Text on purpose, see the module.
    [ValidatePattern('^\d+$')]
    [ValidateRange(1, 180)]
    [string] $Minutes,

    [string] $Tag,

    [string] $LogPath
)

# Otherwise a refused tag or log path only ends the chain and the script still exits with code 0.
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Pomodoro.psm1')
$log = @{}
if ($PSBoundParameters.Remove('Tag')) { $log.Tag = $Tag }
if ($PSBoundParameters.Remove('LogPath')) { $log.Path = $LogPath }

# One command on purpose: an interrupted session emits nothing, so nothing is logged.
Start-PomodoroSession @PSBoundParameters | Add-PomodoroLogEntry @log

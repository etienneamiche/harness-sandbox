#Requires -Version 7.4

$ErrorActionPreference = 'Stop'

# Several Pester versions can coexist on a machine: an older one must not be picked up.
Import-Module Pester -MinimumVersion 5.5

$result = Invoke-Pester -Path (Join-Path $PSScriptRoot '..' 'src') -Output Detailed -PassThru
if ($result.Result -ne 'Passed') { exit 1 }

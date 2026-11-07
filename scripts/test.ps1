#Requires -Version 7.4
# Project tests: Pester on scripts/tests. Fails when Pester cannot run, not only when a test fails.
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5
$result = Invoke-Pester -Path (Join-Path $PSScriptRoot 'tests') -Output Detailed -PassThru
if (-not $result -or $result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { exit 1 }

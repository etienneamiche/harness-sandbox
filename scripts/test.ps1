#Requires -Version 7.4
# Tests du projet : Pester sur scripts/tests.
$result = Invoke-Pester -Path (Join-Path $PSScriptRoot 'tests') -Output Detailed -PassThru
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { exit 1 }

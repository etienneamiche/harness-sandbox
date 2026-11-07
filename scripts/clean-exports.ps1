#Requires -Version 7.4
<#
.SYNOPSIS
    Deletes the CSV exports in exports/ older than -Days days.
.EXAMPLE
    ./scripts/clean-exports.ps1 -Days 30 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 3650)] [int] $Days = 30,
    [string] $Path = (Join-Path $PSScriptRoot '..' 'exports')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "Nothing to clean: $Path does not exist."; return }

$limit = (Get-Date).AddDays(-$Days)
$old = @(Get-ChildItem -LiteralPath $Path -Filter '*.csv' -File | Where-Object LastWriteTime -lt $limit)
$failed = 0
foreach ($file in $old) {
    if (-not $PSCmdlet.ShouldProcess($file.Name, 'delete')) { continue }
    # A locked file is reported and skipped: it must not stop the rest of the cleanup.
    try { [IO.File]::Delete($file.FullName) }
    catch { $failed++; Write-Warning "$($file.Name): $($_.Exception.Message)" }
}
Write-Host "$($old.Count) export(s) older than $Days days, $failed not deleted."
if ($failed) { exit 1 }

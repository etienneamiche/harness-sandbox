#Requires -Version 7.4
<#
.SYNOPSIS
    Supprime les exports CSV de exports/ plus vieux que -Days jours.
.EXAMPLE
    ./scripts/clean-exports.ps1 -Days 30 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 3650)] [int] $Days = 30,
    [string] $Path = (Join-Path $PSScriptRoot '..' 'exports')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { Write-Host "Rien à nettoyer : $Path n'existe pas."; return }

$limit = (Get-Date).AddDays(-$Days)
$old = @(Get-ChildItem $Path -Filter '*.csv' -File | Where-Object LastWriteTime -lt $limit)
foreach ($file in $old) {
    if ($PSCmdlet.ShouldProcess($file.Name, 'suppression')) { [IO.File]::Delete($file.FullName) }
}
Write-Host "$($old.Count) export(s) de plus de $Days jours."

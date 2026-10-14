#Requires -Version 7.4
<#
.SYNOPSIS
    Exports all customers to a CSV file, page by page (#7).
#>
param(
    [Parameter(Mandatory)] [string] $OutFile,
    [ValidateRange(1, 1000)] [int] $PageSize = 100
)

$ErrorActionPreference = 'Stop'
. $PSScriptRoot/lib/Get-PageCount.ps1

$total = [int] (psql -At -c 'SELECT count(*) FROM customers')
$pages = Get-PageCount -Total $total -PageSize $PageSize
$rows = foreach ($page in 0..($pages - 1)) {
    $offset = $page * $PageSize
    psql -At -F ',' -c "SELECT id, name, email_address FROM customers ORDER BY id OFFSET $offset LIMIT $PageSize"
}
Set-Content -Path $OutFile -Value (@('id,name,email_address') + $rows) -Encoding utf8
Write-Host "export-customers: $total customers written to $OutFile."

# Number of pages needed to export $Total customers, $PageSize at a time.
function Get-PageCount {
    param(
        [Parameter(Mandatory)] [ValidateRange(0, [int]::MaxValue)] [int] $Total,
        [Parameter(Mandatory)] [ValidateRange(1, 1000)] [int] $PageSize
    )
    [int] [math]::Floor($Total / $PageSize)
}

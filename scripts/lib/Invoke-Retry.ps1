# Runs $Action, retrying with exponential backoff when it throws.
# Used by the scripts that call flaky local services (Postgres starting up, Authentik).
function Invoke-Retry {
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [ValidateRange(1, 10)] [int] $MaxAttempts = 3,
        [ValidateRange(0, 60000)] [int] $DelayMs = 200
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        }
        catch {
            if ($attempt -eq $MaxAttempts + 1) { throw }
            Write-Verbose "Invoke-Retry: attempt $attempt failed ($($_.Exception.Message)), retrying."
            Start-Sleep -Milliseconds ([math]::Min($DelayMs * [math]::Pow(2, $attempt - 1), 30000))
        }
    }
}

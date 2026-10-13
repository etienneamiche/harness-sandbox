# session-info : au démarrage, rappelle la version du harness et signale ce qui manque.
@{
    Name     = 'session-info'
    Event    = 'SessionStart'
    Profiles = 'minimal', 'standard', 'strict'
    Kind     = 'info'
    Run      = {
        param($ctx)
        $answers = Join-Path $ctx.ProjectDir '.copier-answers.harness.yml'
        $version = if ((Test-Path $answers) -and ((Get-Content $answers -Raw) -match '(?m)^_commit:\s*[''"]?([^''"\s]+)')) { $Matches[1] } else { 'inconnue' }
        $lines = @("Harness $version (kind=$(Get-Value $ctx.Config 'kind' '?'), profil=$($ctx.Profile)).")

        # Dernière version publiée, vérifiée au plus une fois par jour (cache).
        $cache = Join-Path ([IO.Path]::GetTempPath()) 'claude-harness' 'latest-version.json'
        if (Test-Path $cache) {
            $latest = (Get-Content $cache -Raw | ConvertFrom-Json).version
            if ($latest -and $version -ne 'inconnue' -and $latest -ne $version) {
                $lines += "Une version plus récente du harness existe ($latest) : la proposer à l'utilisateur (scripts/harness-sync.ps1)."
            }
        }
        if (-not (Test-Path (Join-Path $ctx.ProjectDir '.codegraph'))) {
            $lines += "Index codegraph absent : proposer à l'utilisateur de lancer 'codegraph init'."
        }
        @{ Decision = 'context'; Reason = $lines -join ' ' }
    }
}

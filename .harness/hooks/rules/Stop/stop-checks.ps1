# stop-checks : à la fin d'un tour, une seule passe de vérifications sur les fichiers
# modifiés (format et typecheck déclarés par les modules, traces de debug oubliées).
# Bloquer l'arrêt renvoie l'agent au travail ; jamais deux fois de suite (stop_hook_active).
@{
    Name     = 'stop-checks'
    Event    = 'Stop'
    Profiles = 'standard', 'strict'
    Kind     = 'info'
    Run      = {
        param($ctx)
        if (Get-Value $ctx.Input 'stop_hook_active' $false) { return }

        $changed = @(git -C $ctx.ProjectDir status --porcelain 2>$null | ForEach-Object { $_.Substring(3) -replace '^.* -> ', '' })
        if (-not $changed) { return }
        $problems = [System.Collections.Generic.List[string]]::new()

        # Vérifications déclarées par les modules : .harness/modules/<nom>/module.json → stopChecks.
        foreach ($manifest in Get-ChildItem (Join-Path $ctx.ProjectDir '.harness' 'modules' '*' 'module.json') -ErrorAction SilentlyContinue) {
            $module = Get-Content $manifest.FullName -Raw | ConvertFrom-Json -AsHashtable
            foreach ($check in @(Get-Value $module 'stopChecks' @())) {
                if (-not ($changed | Where-Object { $_ -match $check.files })) { continue }
                Push-Location $ctx.ProjectDir
                try { $output = pwsh -NoProfile -Command $check.command 2>&1 | Out-String; $ok = $LASTEXITCODE -eq 0 }
                finally { Pop-Location }
                if (-not $ok) { $problems.Add("$($check.name) a échoué :`n$($output.Trim() | Select-Object -First 1)") }
            }
        }

        # Traces de debug ajoutées (profil strict seulement : un Console.WriteLine peut être légitime).
        if ($ctx.Profile -eq 'strict') {
            $added = git -C $ctx.ProjectDir diff -U0 2>$null | Where-Object { $_ -match '^\+[^+]' }
            $debug = @(Get-Value $ctx.Config 'debugPatterns' @())
            $hits = @($added | Where-Object { Test-AnyMatch $_ $debug })
            if ($hits) { $problems.Add("traces de debug ajoutées :`n$(($hits | Select-Object -First 5) -join "`n")") }
        }

        if ($problems.Count -gt 0) {
            @{ Decision = 'block'; Reason = "vérifications de fin de tour en échec. Corriger avant de terminer :`n$($problems -join "`n`n")" }
        }
    }
}

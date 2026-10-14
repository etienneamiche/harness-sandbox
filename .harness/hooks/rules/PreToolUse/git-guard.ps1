# git-guard : opérations Git et GitHub réservées à certains agents, gestes interdits,
# format des commits, et revue `auditor` obligatoire avant toute fusion.
@{
    Name     = 'git-guard'
    Event    = 'PreToolUse'
    Tools    = 'Bash|PowerShell'
    Profiles = 'minimal', 'standard', 'strict'
    Kind     = 'guard'
    Run      = {
        param($ctx)
        $cmd = Get-Value $ctx.ToolInput 'command' ''
        # merge-pr.ps1 ne contient ni « git » ni « gh » : il doit quand même passer par les règles.
        if ($cmd -notmatch '\b(git|gh)\b|merge-pr\.ps1') { return }
        # Options globales de git (-C dossier, -c clé=valeur, --git-dir…) retirées avant l'analyse :
        # `git -C x push` reste un `git push`. Le dossier visé sert à lire la branche courante.
        $gitDir = $ctx.Cwd
        if ($cmd -match '\bgit\s+-C\s+("(?<d>[^"]+)"|''(?<d>[^'']+)''|(?<d>\S+))') { $gitDir = [IO.Path]::GetFullPath($Matches['d'], $ctx.Cwd) }
        # Un alias git défini en ligne (`git -c alias.p=push p`) masquerait la vraie sous-commande.
        if ($cmd -match '\bgit\b[^;&|]*\s-c\s*["'']?alias\.') {
            return @{ Decision = 'deny'; Reason = "pas d'alias git défini dans la commande (-c alias.…) : écrire la sous-commande en clair." }
        }
        # Toute option placée avant la sous-commande est retirée (celles qui prennent une valeur avec elle).
        $cmd = [regex]::Replace($cmd, '\bgit((\s+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env|--super-prefix)(=|\s+)("[^"]*"|''[^'']*''|\S+))|(\s+--?[A-Za-z][\w-]*(=\S+)?))+', 'git')
        # Même chose pour gh : -R / --repo peut se placer avant ou après le groupe (`gh pr -R x merge`).
        $cmd = [regex]::Replace($cmd, '(?<=\bgh\b[^;&|\n]*)\s(-R|--repo)(=|\s+)("[^"]*"|''[^'']*''|\S+)', '')
        $agent = $ctx.AgentType
        $config = $ctx.Config
        $who = if ($agent) { "l'agent '$agent'" } else { 'la session principale' }

        # 1. Interdits pour tout le monde.
        $forbidden = [ordered]@{
            'git\s+worktree\b'                                   = 'les worktrees sont interdits : on travaille par branches simples.'
            'git\s+rebase\b[^;&|]*\s(-i|--interactive)\b'        = 'le rebase interactif est interdit.'
            'git\s+push\b[^;&|]*(\s--force(-with-lease)?\b|\s-f\b|\s\+\S)' = 'le push forcé est interdit.'
            '--no-verify\b'                                      = 'contourner les hooks Git (--no-verify) est interdit.'
            'git\s+add\b[^;&|]*\s(-A|--all|\.)(?=\s|$|;|&|\|)'   = "git add -A / git add . sont interdits : ajouter les fichiers un par un, après les avoir vérifiés."
            'git\s+commit\b[^;&|]*\s-(?!-)[a-zA-Z]*a'            = "git commit -a est interdit : ajouter les fichiers un par un."
        }
        foreach ($pattern in $forbidden.Keys) {
            if ($cmd -cmatch $pattern) { return @{ Decision = 'deny'; Reason = $forbidden[$pattern] } }
        }

        # 2. Opérations réservées : classe d'opération → agents autorisés.
        $restricted = Get-Value $config 'restrictedCommands' @{}
        foreach ($pattern in $restricted.Keys) {
            $owners = @($restricted[$pattern])
            if ($cmd -match $pattern -and $owners -notcontains $agent) {
                $reason = if ($owners) { "$who ne peut pas lancer cette commande, réservée à : $($owners -join ', '). Déléguer à l'agent concerné." }
                          else { "cette commande est réservée à l'utilisateur : la lui proposer, sans la lancer." }
                return @{ Decision = 'deny'; Reason = $reason }
            }
        }

        # 2 bis. Le marqueur de revue n'est écrit que par auditor : tout autre agent qui l'écrirait
        # s'auto-approuverait (texte de la commande ou fichier passé par --body-file).
        if ($agent -ne 'auditor' -and $cmd -match '\bgh\b') {
            $text = $cmd
            if ($cmd -match '\s(--body-file|-F)(=|\s+)("(?<f>[^"]+)"|''(?<f>[^'']+)''|(?<f>\S+))') {
                $bodyFile = [IO.Path]::GetFullPath($Matches['f'], $ctx.Cwd)
                if (Test-Path $bodyFile -PathType Leaf) { $text += "`n" + (Get-Content $bodyFile -Raw) }
            }
            if ($text -match '<!--\s*auditor:') {
                return @{ Decision = 'deny'; Reason = "seul l'agent auditor écrit le marqueur de revue (<!-- auditor: … -->)." }
            }
        }

        # 3. Push vers une branche protégée.
        $protected = @(Get-Value $config 'protectedBranches' @())
        if ($protected -and $cmd -match 'git\s+push\b(?<args>[^;&|]*)') {
            # `git push [options] <remote> <refspec>` : sans refspec, c'est la branche courante.
            $positional = @($Matches['args'].Trim() -split '\s+' | Where-Object { $_ -and $_ -notmatch '^-' })
            $branch = if ($positional.Count -ge 2) {
                (($positional[1] -split ':')[-1]) -replace '^\+', '' -replace '^refs/heads/', ''
            }
            else { git -C $gitDir branch --show-current 2>$null }
            if ($protected -contains $branch) {
                return @{ Decision = 'deny'; Reason = "push direct sur '$branch' interdit : passer par une PR." }
            }
        }

        # 4. Message de commit avec le numéro d'issue.
        if ((Get-Value $config 'requireIssueRef' $false) -and $cmd -match 'git\s+commit\b') {
            if ($cmd -notmatch '\s(-m|--message)[\s=]' -and $cmd -notmatch '\s(-F|--file)[\s=]') {
                return @{ Decision = 'deny'; Reason = 'commit sans message en ligne de commande : utiliser -m "type(scope): description (#n)".' }
            }
            # Message en ligne (-m), lu sur l'entrée standard (-F - avec un heredoc : il est
            # dans la commande elle-même), ou dans un fichier (-F <fichier>).
            $message = $cmd
            if ($cmd -match '\s(-F|--file)[\s=]+"?([^"\s]+)' -and $Matches[2] -ne '-') {
                $file = [IO.Path]::GetFullPath($Matches[2], $ctx.Cwd)
                $message = if (Test-Path $file) { Get-Content $file -Raw } else { '' }
            }
            if ($message -notmatch '#\d+') {
                return @{ Decision = 'deny'; Reason = 'le message de commit doit citer le numéro d''issue : "type(scope): description (#n)".' }
            }
        }

        # 5. Fusion d'une PR : jamais par `gh pr merge` direct. Une ligne de commande ne se laisse pas
        # analyser de façon fiable (échappements, commandes enchaînées, --repo…) : la fusion passe par
        # .harness/tools/merge-pr.ps1, aux paramètres typés, qui vérifie la revue auditor et fusionne
        # le commit revu et lui seul (--match-head-commit). Ce script est réservé à git-ops (§2).
        if ($cmd -match '\bgh(\s+(-R|--repo)(=|\s+)\S+|\s+--?[\w-]+)*\s+pr\s+merge\b') {
            return @{ Decision = 'deny'; Reason = "pas de 'gh pr merge' direct : fusionner avec pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr <n> -Subject `"type(scope): description (#n)`" (-Strategy merge pour une release ou un hotfix)." }
        }
    }
}

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
        if ($cmd -notmatch '\b(git|gh)\b') { return }
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

        # 3. Push vers une branche protégée.
        $protected = @(Get-Value $config 'protectedBranches' @())
        if ($protected -and $cmd -match 'git\s+push\b(?<args>[^;&|]*)') {
            # `git push [options] <remote> <refspec>` : sans refspec, c'est la branche courante.
            $positional = @($Matches['args'].Trim() -split '\s+' | Where-Object { $_ -and $_ -notmatch '^-' })
            $branch = if ($positional.Count -ge 2) {
                (($positional[1] -split ':')[-1]) -replace '^\+', '' -replace '^refs/heads/', ''
            }
            else { git -C $ctx.Cwd branch --show-current 2>$null }
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

        # 5. Fusion d'une PR.
        if ($cmd -match 'gh\s+pr\s+merge\b(?<args>[^;&|]*)') {
            $mergeArgs = $Matches['args']
            $origin = git -C $ctx.Cwd remote get-url origin 2>$null
            if ("$origin $mergeArgs" -match '[/:]homelab(\.git)?\b') {
                return @{ Decision = 'deny'; Reason = "une PR de homelab ne se fusionne qu'à la main par le propriétaire : fusionner dans homelab, c'est déployer." }
            }
            $number = if ($mergeArgs -match '(?<!\S)#?(\d+)\b') { $Matches[1] } else { '' }
            $pr = if ($env:HARNESS_TEST_PR_JSON) {
                Get-Content $env:HARNESS_TEST_PR_JSON -Raw | ConvertFrom-Json -AsHashtable
            }
            else {
                Push-Location $ctx.Cwd
                try { gh pr view $number --json number,headRefOid,comments 2>$null | ConvertFrom-Json -AsHashtable }
                finally { Pop-Location }
            }
            if (-not $pr) { return @{ Decision = 'deny'; Reason = "impossible de lire la PR $number pour vérifier sa revue auditor." } }

            $head = $pr.headRefOid
            $verdict = $null
            foreach ($comment in @($pr.comments)) {
                if ($comment.body -match '<!--\s*auditor:\s*sha=(?<sha>[0-9a-f]{7,40})\s+verdict=(?<v>\w+)\s*-->') {
                    $verdict = @{ Sha = $Matches['sha']; Value = $Matches['v'] }
                }
            }
            if (-not $verdict) {
                return @{ Decision = 'deny'; Reason = "la PR #$($pr.number) n'a pas de revue auditor. Lancer /audit-pr avant de fusionner." }
            }
            if (-not $head.StartsWith($verdict.Sha)) {
                return @{ Decision = 'deny'; Reason = "la revue auditor porte sur $($verdict.Sha), mais la PR a reçu des commits depuis (dernier : $($head.Substring(0,7))). Relancer /audit-pr." }
            }
            if ($verdict.Value -ne 'approve') {
                return @{ Decision = 'deny'; Reason = "la dernière revue auditor demande des changements ($($verdict.Value)). Corriger puis relancer /audit-pr." }
            }
        }
    }
}

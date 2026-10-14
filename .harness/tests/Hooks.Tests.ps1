#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
# Autotests des hooks du harness : chaque règle reçoit une entrée simulée,
# exactement comme Claude Code la lui enverrait, dans un vrai processus pwsh.
# Lancés par `.harness/tools/doctor.ps1 -Deep` et par la CI du harness.

BeforeDiscovery {
    # Certains tests dépendent du type de dépôt (gitflow ou non) : on lit sa config.
    $cfg = Get-Content (Join-Path $PSScriptRoot '..' 'harness.json') -Raw | ConvertFrom-Json
    $Gitflow = [bool] $cfg.requireIssueRef
    $HasReact = Test-Path (Join-Path $PSScriptRoot '..' 'modules' 'react')
    $HasDotnet = Test-Path (Join-Path $PSScriptRoot '..' 'modules' 'dotnet')
}

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Dispatch = Join-Path $Root '.harness' 'hooks' 'dispatch.ps1'

    function Invoke-Hook {
        param(
            [string] $EventName = 'PreToolUse',
            [hashtable] $Data = @{},
            [hashtable] $Env = @{},
            [string] $Raw,
            [string] $Dispatch = $script:Dispatch
        )
        # Les tests visent le profil standard, sauf s'ils en demandent un autre.
        if (-not $Env.ContainsKey('HARNESS_HOOK_PROFILE')) { $Env = $Env + @{ HARNESS_HOOK_PROFILE = 'standard' } }
        $payload = @{ hook_event_name = $EventName; session_id = $script:SessionId; cwd = (Split-Path (Split-Path (Split-Path $Dispatch))) } + $Data
        $json = if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else { $payload | ConvertTo-Json -Depth 10 -Compress }
        $saved = @{}
        foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
        try { $out = $json | pwsh -NoProfile -NonInteractive -File $Dispatch $EventName }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }

        $text = ($out | Out-String).Trim()
        if (-not $text) { return [pscustomobject]@{ Decision = 'allow'; Reason = '' } }
        $o = $text | ConvertFrom-Json -AsHashtable
        $hso = if ($o.ContainsKey('hookSpecificOutput')) { $o.hookSpecificOutput } else { @{} }
        if ($hso['permissionDecision'] -eq 'deny' -or $o['decision'] -eq 'block') {
            return [pscustomobject]@{ Decision = 'deny'; Reason = "$($hso['permissionDecisionReason'])$($o['reason'])" }
        }
        [pscustomobject]@{ Decision = 'context'; Reason = $hso['additionalContext'] }
    }

    function Tool([string] $Name, [hashtable] $ToolInput, [string] $Agent = '') {
        $d = @{ tool_name = $Name; tool_input = $ToolInput }
        if ($Agent) { $d.agent_type = $Agent; $d.agent_id = 'a0' }
        $d
    }
    function Bash([string] $Command, [string] $Agent = '') { Tool 'Bash' @{ command = $Command } $Agent }

    # Faux secrets construits à l'exécution : rien de détectable n'est écrit dans le dépôt.
    function New-FakeToken([string] $Prefix, [int] $Length) {
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
        $Prefix + -join (1..$Length | ForEach-Object { $chars | Get-Random })
    }
}

Describe 'Hooks du harness' {
BeforeEach { $script:SessionId = "test-$([guid]::NewGuid())" }

Describe 'model-guard' {
    It 'refuse un agent générique' { (Invoke-Hook -Data (Tool 'Agent' @{ subagent_type = 'general-purpose'; prompt = 'x' })).Decision | Should -Be 'deny' }
    It 'refuse un agent inconnu' { (Invoke-Hook -Data (Tool 'Agent' @{ subagent_type = 'Explore'; prompt = 'x' })).Decision | Should -Be 'deny' }
    It 'accepte un agent de la liste blanche' { (Invoke-Hook -Data (Tool 'Agent' @{ subagent_type = 'explorer'; prompt = 'x' })).Decision | Should -Be 'allow' }
    It 'refuse un paramètre model, même sur un agent autorisé' {
        $r = Invoke-Hook -Data (Tool 'Agent' @{ subagent_type = 'explorer'; prompt = 'x'; model = 'opus' })
        $r.Decision | Should -Be 'deny'
        $r.Reason | Should -Match 'model'
    }
    It 'accepte les agents impeccable' { (Invoke-Hook -Data (Tool 'Agent' @{ subagent_type = 'impeccable-documenter'; prompt = 'x' })).Decision | Should -Be 'allow' }
}

Describe 'git-guard' {
    It 'refuse un commit depuis la session principale' { (Invoke-Hook -Data (Bash 'git commit -m "feat: x (#1)"')).Decision | Should -Be 'deny' }
    It 'refuse un commit depuis dev' { (Invoke-Hook -Data (Bash 'git commit -m "feat: x (#1)"' 'dev')).Decision | Should -Be 'deny' }
    It 'accepte un commit de git-ops avec numéro d''issue' { (Invoke-Hook -Data (Bash 'git commit -m "feat(api): export (#12)"' 'git-ops')).Decision | Should -Be 'allow' }
    It 'refuse un commit sans numéro d''issue' -Skip:(-not $Gitflow) { (Invoke-Hook -Data (Bash 'git commit -m "feat: export"' 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse un commit sans -m' -Skip:(-not $Gitflow) { (Invoke-Hook -Data (Bash 'git commit' 'git-ops')).Decision | Should -Be 'deny' }
    It 'accepte un message passé par heredoc (-F -)' {
        (Invoke-Hook -Data (Bash "git commit -F - <<'EOF'`ndocs: essai (#1)`n`nCorps du message.`nEOF" 'git-ops')).Decision | Should -Be 'allow'
    }
    It 'vérifie le message lu dans un fichier (-F <fichier>)' -Skip:(-not $Gitflow) {
        $file = Join-Path ([IO.Path]::GetTempPath()) "msg-$([guid]::NewGuid()).txt"
        Set-Content $file 'docs: sans numéro'
        try { (Invoke-Hook -Data (Bash "git commit -F $file" 'git-ops')).Decision | Should -Be 'deny' }
        finally { Remove-Item $file }
    }
    It 'refuse git commit -a' { (Invoke-Hook -Data (Bash 'git commit -am "feat: x (#1)"' 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse git add -A' { (Invoke-Hook -Data (Bash 'git add -A' 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse git add .' { (Invoke-Hook -Data (Bash 'git add .' 'git-ops')).Decision | Should -Be 'deny' }
    It 'accepte git add fichier par fichier' { (Invoke-Hook -Data (Bash 'git add src/app.ts docs/x.md' 'git-ops')).Decision | Should -Be 'allow' }
    It 'refuse les worktrees, même pour git-ops' { (Invoke-Hook -Data (Bash 'git worktree add ../x' 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse le rebase interactif' { (Invoke-Hook -Data (Bash 'git rebase -i HEAD~3' 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse --no-verify' { (Invoke-Hook -Data (Bash 'git commit --no-verify -m "x (#1)"' 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse le push forcé (<cmd>)' -ForEach @(
        @{ cmd = 'git push --force origin feature/1-x' }, @{ cmd = 'git push -f origin feature/1-x' },
        @{ cmd = 'git push --force-with-lease' }, @{ cmd = 'git push origin +feature/1-x' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse le push direct sur main' -Skip:(-not $Gitflow) { (Invoke-Hook -Data (Bash 'git push origin main' 'git-ops')).Decision | Should -Be 'deny' }
    It 'refuse le push direct sur develop' -Skip:(-not $Gitflow) { (Invoke-Hook -Data (Bash 'git push origin HEAD:develop' 'git-ops')).Decision | Should -Be 'deny' }
    It 'accepte le push d''une branche de feature' { (Invoke-Hook -Data (Bash 'git push -u origin feature/12-export' 'git-ops')).Decision | Should -Be 'allow' }
    It 'refuse gh pr create hors git-ops' { (Invoke-Hook -Data (Bash 'gh pr create --fill')).Decision | Should -Be 'deny' }
    It 'accepte gh pr create par git-ops' { (Invoke-Hook -Data (Bash 'gh pr create --fill' 'git-ops')).Decision | Should -Be 'allow' }
    It 'accepte gh pr comment par auditor' { (Invoke-Hook -Data (Bash 'gh pr comment 3 --body-file r.md' 'auditor')).Decision | Should -Be 'allow' }
    It 'réserve gh repo delete à l''utilisateur' { (Invoke-Hook -Data (Bash 'gh repo delete x/y --yes' 'git-ops')).Decision | Should -Be 'deny' }
    It 'laisse passer les lectures Git' { (Invoke-Hook -Data (Bash 'git status; git log --oneline -5; git diff')).Decision | Should -Be 'allow' }
}

Describe 'git-guard : fusion uniquement par merge-pr.ps1' {
    It 'refuse tout gh pr merge direct, même pour git-ops (<cmd>)' -ForEach @(
        @{ cmd = 'gh pr merge 7 --squash --subject "feat: x (#7)"' }, @{ cmd = 'gh pr merge 7 --merge' },
        @{ cmd = 'gh -R someone/other pr merge 7 --squash' }, @{ cmd = 'git status && gh pr merge 9' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason | Should -Match 'merge-pr\.ps1' }
    It 'réserve merge-pr.ps1 à git-ops' {
        (Invoke-Hook -Data (Bash 'pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 7 -Subject "feat: x (#7)"' 'auditor')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 7 -Subject "feat: x (#7)"')).Decision | Should -Be 'deny'
    }
    It 'laisse git-ops lancer merge-pr.ps1' {
        (Invoke-Hook -Data (Bash 'pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 7 -Subject "feat: x (#7)"' 'git-ops')).Decision | Should -Be 'allow'
    }
    It 'ne confond pas un texte « pr merge » dans un commentaire avec une fusion' {
        (Invoke-Hook -Data (Bash 'gh issue comment 3 --body "voir la pr merge de demain"' 'git-ops')).Decision | Should -Be 'allow'
    }
}

Describe 'git-guard : contournements connus' {
    It 'voit un git push derrière les options globales de git (<cmd>)' -Skip:(-not $Gitflow) -ForEach @(
        @{ cmd = 'git -C ../autre push origin main' }, @{ cmd = 'git -c core.hooksPath=/dev/null push origin develop' },
        @{ cmd = 'git --no-pager --git-dir=.git push origin main' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'deny' }
    It 'voit un commit derrière les options globales de git, hors git-ops' {
        (Invoke-Hook -Data (Bash 'git -C . commit -m "feat: x (#1)"' 'dev')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'git -c user.name=x commit -m "feat: x (#1)"' 'dev')).Decision | Should -Be 'deny'
    }
    It 'réserve à l''utilisateur toute écriture par gh api (<cmd>)' -ForEach @(
        @{ cmd = 'gh api --method=PUT repos/o/r/pulls/7/merge' }, @{ cmd = 'gh api -X PUT repos/o/r/pulls/7/merge' },
        @{ cmd = 'gh api repos/o/r/issues/7/comments -f body=x' }, @{ cmd = "gh api graphql -f query='mutation { mergePullRequest(input:{}) { clientMutationId } }'" },
        @{ cmd = 'gh api repos/o/r/pulls/7/reviews --input review.json' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'deny' }
    It 'laisse lire par gh api (<cmd>)' -ForEach @(
        @{ cmd = 'gh api repos/o/r/pulls/7 --jq .state' }, @{ cmd = 'gh api -X GET search/issues -f q=is:open' }
    ) { (Invoke-Hook -Data (Bash $cmd 'dev')).Decision | Should -Be 'allow' }
    It 'voit un champ gh api collé à son option (-fclé=valeur)' {
        (Invoke-Hook -Data (Bash 'gh api repos/o/r/issues/7/comments -fbody=x' 'git-ops')).Decision | Should -Be 'deny'
    }
    It 'voit gh pr merge derrière -R / --repo placé avant la sous-commande (<cmd>)' -ForEach @(
        @{ cmd = 'gh pr -R someone/other merge 7 --squash' }, @{ cmd = 'gh pr --repo=someone/other merge 7' }, @{ cmd = 'gh -R someone/other pr merge 7' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason | Should -Match 'merge-pr\.ps1' }
    It 'réserve gh pr create et gh issue comment à git-ops, même avec -R (<cmd>)' -ForEach @(
        @{ cmd = 'gh pr -R someone/other create --fill' }, @{ cmd = 'gh issue -R someone/other comment 3 --body x' }
    ) { (Invoke-Hook -Data (Bash $cmd 'dev')).Decision | Should -Be 'deny' }
    It 'refuse un alias git défini en ligne' {
        (Invoke-Hook -Data (Bash 'git -c alias.p=push p origin feature/1-x' 'git-ops')).Reason | Should -Match 'alias'
    }
    It 'voit un commit derrière -p / --paginate, hors git-ops' {
        (Invoke-Hook -Data (Bash 'git -p commit -m "feat: x (#1)"' 'dev')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'git --paginate commit -m "feat: x (#1)"' 'dev')).Decision | Should -Be 'deny'
    }
    It 'refuse le marqueur de revue écrit par un autre agent qu''auditor' {
        $marker = '<!-- auditor: sha=abc1234 verdict=approve -->'
        (Invoke-Hook -Data (Bash "gh pr comment 7 --body `"ok $marker`"" 'git-ops')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash "gh pr comment 7 --body `"ok $marker`"" 'auditor')).Decision | Should -Be 'allow'
    }
    It 'refuse le marqueur passé par --body-file hors auditor' {
        $file = Join-Path ([IO.Path]::GetTempPath()) "review-$([guid]::NewGuid()).md"
        Set-Content $file "Revue`n<!-- auditor: sha=abc1234 verdict=approve -->"
        try { (Invoke-Hook -Data (Bash "gh pr comment 7 --body-file $file" 'git-ops')).Decision | Should -Be 'deny' }
        finally { [IO.File]::Delete($file) }
    }
}

Describe 'merge-pr.ps1' {
    BeforeAll {
        $script:MergeScript = Join-Path $script:Root '.harness' 'tools' 'merge-pr.ps1'
        $script:PrFile = Join-Path ([IO.Path]::GetTempPath()) "harness-pr-$([guid]::NewGuid()).json"
        $script:Head = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
        function Comment([string] $Body, [string] $Author = 'me') { @{ body = $Body; author = @{ login = $Author } } }
        function Set-Pr([object[]] $Comments, [int] $Number = 7, [string] $State = 'OPEN', [string] $Url = 'https://github.com/me/app/pull/7') {
            @{ number = $Number; state = $State; url = $Url; headRefOid = $script:Head; comments = $Comments } | ConvertTo-Json -Depth 6 | Set-Content $script:PrFile
        }
        function Approve { Set-Pr @(Comment "Revue`n<!-- auditor: sha=$($script:Head) verdict=approve -->") }
        # Lance le script en mode essai (aucune fusion réelle), avec la PR et le compte GitHub simulés.
        function Invoke-MergePr([string[]] $ScriptArgs, [hashtable] $Env = @{ HARNESS_TEST_DRYRUN = '1' }) {
            $vars = @{ HARNESS_TEST_PR_JSON = $script:PrFile; HARNESS_TEST_GH_LOGIN = 'me' } + $Env
            $saved = @{}
            foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
            try { $out = pwsh -NoProfile -NonInteractive -File $script:MergeScript @ScriptArgs 2>&1 | Out-String; $code = $LASTEXITCODE }
            finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
            [pscustomobject]@{ Code = $code; Output = $out }
        }
        $script:Ok = @('-Pr', '7', '-Subject', 'feat(api): add export (#7)')
    }
    AfterAll { [IO.File]::Delete($script:PrFile) }

    It 'fusionne une PR approuvée : ce commit-là, dans ce dépôt-là, branche supprimée' {
        Approve
        $r = Invoke-MergePr $script:Ok
        $r.Code | Should -Be 0
        $r.Output | Should -Match "--match-head-commit $($script:Head)"
        $r.Output | Should -Match '--repo me/app'
        $r.Output | Should -Match '--squash'
        $r.Output | Should -Match '--delete-branch'
    }
    It 'refuse une PR sans revue' { Set-Pr @(Comment 'LGTM'); (Invoke-MergePr $script:Ok).Code | Should -Be 1 }
    It 'ignore un marqueur posé par un autre compte GitHub' {
        Set-Pr @(Comment "<!-- auditor: sha=$($script:Head) verdict=approve -->" 'inconnu')
        (Invoke-MergePr $script:Ok).Output | Should -Match "pas de revue auditor"
    }
    It 'refuse une PR modifiée après la revue' {
        Set-Pr @(Comment '<!-- auditor: sha=0000000aaaaaaa1111111bbbbbbb2222222ccccc verdict=approve -->')
        (Invoke-MergePr $script:Ok).Output | Should -Match 'Relancer /audit-pr'
    }
    It 'refuse une PR dont la dernière revue demande des changements' {
        Set-Pr @((Comment "<!-- auditor: sha=$($script:Head) verdict=approve -->"), (Comment "<!-- auditor: sha=$($script:Head) verdict=changes -->"))
        (Invoke-MergePr $script:Ok).Code | Should -Be 1
    }
    It 'refuse une PR de homelab, quel que soit le dépôt courant' {
        Set-Pr @(Comment "<!-- auditor: sha=$($script:Head) verdict=approve -->") -Url 'https://github.com/me/homelab/pull/7'
        (Invoke-MergePr $script:Ok).Output | Should -Match 'homelab'
    }
    It 'refuse si la PR lue n''est pas celle demandée' { Approve; (Invoke-MergePr @('-Pr', '8', '-Subject', 'feat(api): add export (#7)')).Code | Should -Be 1 }
    It 'refuse une PR fermée' { Set-Pr @(Comment "<!-- auditor: sha=$($script:Head) verdict=approve -->") -State 'MERGED'; (Invoke-MergePr $script:Ok).Code | Should -Be 1 }
    It 'exige -Subject en squash' { Approve; (Invoke-MergePr @('-Pr', '7')).Output | Should -Match 'Subject' }
    It 'exige un -Subject en Conventional Commits avec numéro d''issue' { Approve; (Invoke-MergePr @('-Pr', '7', '-Subject', 'Ajout export')).Code | Should -Be 1 }
    It 'accepte -Strategy merge sans -Subject, et garde la branche (release, hotfix)' {
        Approve
        $r = Invoke-MergePr @('-Pr', '7', '-Strategy', 'merge')
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match '--delete-branch'
    }
    It 'refuse une stratégie rebase' { Approve; (Invoke-MergePr @('-Pr', '7', '-Strategy', 'rebase')).Code | Should -Not -Be 0 }
    It 'ne fusionne jamais pour de vrai avec des données simulées (sans mode essai)' {
        Approve
        $r = Invoke-MergePr $script:Ok -Env @{}
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'HARNESS_TEST_DRYRUN'
    }
}

Describe 'destructive-guard' {
    It 'refuse au premier essai puis accepte la même commande' {
        (Invoke-Hook -Data (Bash 'rm -rf build')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'rm -rf build')).Decision | Should -Be 'allow'
    }
    It 'reconnaît <cmd>' -ForEach @(
        @{ cmd = 'Remove-Item ./dist -Recurse -Force' }, @{ cmd = 'git reset --hard HEAD~1' },
        @{ cmd = 'kubectl delete ns demo' }, @{ cmd = 'tofu destroy' }, @{ cmd = 'psql -c "DROP TABLE users"' }
    ) { (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'deny' }
    It 'ne s''applique pas en profil minimal' {
        (Invoke-Hook -Data (Bash 'rm -rf build') -Env @{ HARNESS_HOOK_PROFILE = 'minimal' }).Decision | Should -Be 'allow'
    }
}

Describe 'config-protection' {
    It 'protège <path>' -ForEach @(
        @{ path = '.eslintrc.json' }, @{ path = 'frontend/eslint.config.mjs' }, @{ path = '.editorconfig' },
        @{ path = '.harness/hooks/rules/git-guard.ps1' }, @{ path = '.claude/settings.json' },
        @{ path = '.claude/agents/dev.md' }, @{ path = '.github/workflows/ci.yml' }, @{ path = '.gitignore' }, @{ path = 'CLAUDE.md' },
        @{ path = 'backend/Directory.Build.props' }, @{ path = 'frontend/tsconfig.app.json' }, @{ path = 'backend/pyrightconfig.json' }, @{ path = 'backend/ruff.toml' }
    ) { (Invoke-Hook -Data (Tool 'Edit' @{ file_path = (Join-Path $script:Root $path); old_string = 'a'; new_string = 'b' })).Decision | Should -Be 'deny' }
    It 'laisse modifier le code et AGENTS.md (<path>)' -ForEach @(@{ path = 'src/app.ts' }, @{ path = 'AGENTS.md' }, @{ path = 'docs/adr/0001.md' }) {
        (Invoke-Hook -Data (Tool 'Edit' @{ file_path = (Join-Path $script:Root $path); old_string = 'a'; new_string = 'b' })).Decision | Should -Be 'allow'
    }
}

Describe 'secret-guard' {
    It 'refuse la lecture de <path>' -ForEach @(
        @{ path = '.env' }, @{ path = 'backend/.env.local' }, @{ path = 'certs/server.key' }, @{ path = 'secrets.json' },
        @{ path = 'C:/Users/x/.ssh/id_ed25519' }, @{ path = 'C:/Users/x/AppData/Roaming/sops/age/keys.txt' }
    ) { (Invoke-Hook -Data (Tool 'Read' @{ file_path = $path })).Decision | Should -Be 'deny' }
    It 'autorise <path>' -ForEach @(@{ path = '.env.example' }, @{ path = 'C:/Users/x/.ssh/id_ed25519.pub' }, @{ path = 'src/env.ts' }) {
        (Invoke-Hook -Data (Tool 'Read' @{ file_path = $path })).Decision | Should -Be 'allow'
    }
    It 'refuse la commande <cmd>' -ForEach @(
        @{ cmd = 'cat .env' }, @{ cmd = 'Get-Content ./config/secrets.json' }, @{ cmd = 'type backend\.env' },
        @{ cmd = 'sops -d secrets/app.sops.yaml' }, @{ cmd = 'printenv' }, @{ cmd = 'Get-ChildItem env:' },
        @{ cmd = 'echo $env:GITHUB_TOKEN' }, @{ cmd = 'gh auth token' }
    ) { (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'deny' }
    It 'autorise la commande <cmd>' -ForEach @(
        @{ cmd = "sops exec-env secrets/app.sops.yaml 'dotnet run'" }, @{ cmd = 'npm test' }, @{ cmd = 'cp .env.example .env.sample' }
    ) { (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'allow' }
}

Describe 'secret-prompt' {
    It 'bloque un message contenant un jeton GitHub' {
        $r = Invoke-Hook -EventName 'UserPromptSubmit' -Data @{ prompt = "voici mon jeton $(New-FakeToken 'ghp_' 36)" }
        $r.Decision | Should -Be 'deny'
        $r.Reason | Should -Match 'jeton GitHub'
    }
    It 'laisse passer un message normal' { (Invoke-Hook -EventName 'UserPromptSubmit' -Data @{ prompt = 'ajoute un test' }).Decision | Should -Be 'allow' }
}

Describe 'règles d''information' {
    It 'doc-sprawl signale un Markdown hors de docs/' {
        $r = Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Write' @{ file_path = (Join-Path $script:Root 'notes.md'); content = 'x' })
        $r.Decision | Should -Be 'context'
        $r.Reason | Should -Match 'docs/'
    }
    It 'doc-sprawl ignore docs/ et README' -ForEach @(@{ path = 'docs/guide.md' }, @{ path = 'README.md' }) {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Write' @{ file_path = (Join-Path $script:Root $path); content = 'x' })).Decision | Should -Be 'allow'
    }
    It 'structural-watch signale un bloc structurel' {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Edit' @{ file_path = (Join-Path $script:Root 'scripts/launch.ps1') })).Reason | Should -Match '/upstream'
    }
    It 'structural-watch lit aussi les blocs déclarés par les modules' -Skip:(-not $HasReact) {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Edit' @{ file_path = (Join-Path $script:Root 'frontend/vite.config.ts') })).Reason | Should -Match '/upstream'
    }
    It 'structural-watch ne dit rien pour du code ordinaire' {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Edit' @{ file_path = (Join-Path $script:Root 'frontend/src/features/x/Thing.tsx') })).Decision | Should -Be 'allow'
    }
    It 'stop-checks bloque des numéros de migration en double (module dotnet)' -Skip:(-not $HasDotnet) {
        # Copie jetable du harness dans un dépôt vide : le vrai hook Stop ne tourne jamais sur le
        # projet réel (il lancerait les vérifications des modules, dont des formateurs qui réécrivent).
        $copy = Join-Path ([IO.Path]::GetTempPath()) "harness-stop-$([guid]::NewGuid())"
        try {
            New-Item -ItemType Directory -Force $copy | Out-Null
            Copy-Item (Join-Path $script:Root '.harness') $copy -Recurse
            git -C $copy init -q
            $dir = Join-Path $copy 'backend' 'db' 'migrations'
            New-Item -ItemType Directory -Force $dir | Out-Null
            Set-Content (Join-Path $dir '0001.1.create-a.sql') 'SELECT 1;'
            Set-Content (Join-Path $dir '0001.2.create-b.sql') 'SELECT 2;'
            $r = Invoke-Hook -EventName 'Stop' -Data @{ stop_hook_active = $false } -Dispatch (Join-Path $copy '.harness' 'hooks' 'dispatch.ps1')
            $r.Decision | Should -Be 'deny'
            $r.Reason | Should -Match 'double'
        }
        finally { if (Test-Path $copy) { Remove-Item $copy -Recurse -Force } }
    }
    It 'session-info annonce la version du harness' {
        (Invoke-Hook -EventName 'SessionStart' -Data @{ source = 'startup' }).Reason | Should -Match 'Harness'
    }
}

Describe 'robustesse' {
    It 'refuse par sécurité une entrée illisible' { (Invoke-Hook -Raw '{pas du json').Decision | Should -Be 'deny' }
    It 'permet de couper une règle (HARNESS_DISABLED_HOOKS)' {
        (Invoke-Hook -Data (Bash 'rm -rf build') -Env @{ HARNESS_DISABLED_HOOKS = 'destructive-guard' }).Decision | Should -Be 'allow'
    }
}

Describe 'pre-commit (gitleaks)' {
    BeforeAll {
        $script:Repo = Join-Path ([IO.Path]::GetTempPath()) "harness-precommit-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force (Join-Path $script:Repo '.harness') | Out-Null
        Copy-Item (Join-Path $script:Root '.harness' 'harness.json') (Join-Path $script:Repo '.harness')
        Copy-Item (Join-Path $script:Root '.harness' 'githooks') (Join-Path $script:Repo '.harness') -Recurse
        Copy-Item (Join-Path $script:Root '.gitleaks.toml') $script:Repo
        git -C $script:Repo init -q -b main
        function Test-PreCommit {
            Push-Location $script:Repo
            try { pwsh -NoProfile -File (Join-Path $script:Repo '.harness' 'githooks' 'pre-commit.ps1') *> $null; $LASTEXITCODE }
            finally { Pop-Location }
        }
    }
    AfterEach { git -C $script:Repo reset -q 2>$null }
    AfterAll { Remove-Item $script:Repo -Recurse -Force -ErrorAction SilentlyContinue }

    It 'refuse un fichier contenant un jeton' {
        Set-Content (Join-Path $script:Repo 'config.ts') "export const token = '$(New-FakeToken 'ghp_' 36)';"
        git -C $script:Repo add config.ts
        Test-PreCommit | Should -Not -Be 0
    }
    It 'refuse un fichier .env, même anodin' {
        Set-Content (Join-Path $script:Repo '.env') 'DEBUG=true'
        git -C $script:Repo add -f .env
        Test-PreCommit | Should -Not -Be 0
    }
    It 'accepte le manifeste du harness (empreintes, pas des secrets)' {
        Copy-Item (Join-Path $script:Root '.harness' 'manifest.json') (Join-Path $script:Repo '.harness')
        git -C $script:Repo add .harness/manifest.json
        Test-PreCommit | Should -Be 0
    }
    It 'accepte un fichier sain' {
        Set-Content (Join-Path $script:Repo 'app.ts') 'export const answer = 42;'
        git -C $script:Repo add app.ts
        Test-PreCommit | Should -Be 0
    }
}
}

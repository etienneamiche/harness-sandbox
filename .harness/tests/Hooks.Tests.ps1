#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
# Autotests des hooks du harness : chaque règle reçoit une entrée simulée,
# exactement comme Claude Code la lui enverrait, dans un vrai processus pwsh.
# Lancés par `.harness/tools/doctor.ps1 -Deep` et par la CI du harness.

BeforeDiscovery {
    # Certains tests dépendent du type de dépôt (gitflow ou non) : on lit sa config.
    $cfg = Get-Content (Join-Path $PSScriptRoot '..' 'harness.json') -Raw | ConvertFrom-Json
    $Gitflow = [bool] $cfg.requireIssueRef
}

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Dispatch = Join-Path $Root '.harness' 'hooks' 'dispatch.ps1'

    function Invoke-Hook {
        param(
            [string] $EventName = 'PreToolUse',
            [hashtable] $Data = @{},
            [hashtable] $Env = @{},
            [string] $Raw
        )
        $payload = @{ hook_event_name = $EventName; session_id = $script:SessionId; cwd = $script:Root } + $Data
        $json = if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else { $payload | ConvertTo-Json -Depth 10 -Compress }
        $saved = @{}
        foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
        try { $out = $json | pwsh -NoProfile -NonInteractive -File $script:Dispatch $EventName }
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

Describe 'git-guard : revue auditor avant fusion' {
    BeforeAll {
        $script:PrFile = Join-Path ([IO.Path]::GetTempPath()) "harness-pr-$([guid]::NewGuid()).json"
        $script:Head = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
        function Set-Pr([object[]] $Comments) {
            @{ number = 7; headRefOid = $script:Head; comments = $Comments } | ConvertTo-Json -Depth 5 | Set-Content $script:PrFile
        }
        function Merge { Invoke-Hook -Data (Bash 'gh pr merge 7 --squash' 'git-ops') -Env @{ HARNESS_TEST_PR_JSON = $script:PrFile } }
    }
    AfterAll { Remove-Item $script:PrFile -ErrorAction SilentlyContinue }

    It 'refuse une PR sans revue' { Set-Pr @(@{ body = 'LGTM' }); (Merge).Decision | Should -Be 'deny' }
    It 'accepte une PR approuvée sur son dernier commit' {
        Set-Pr @(@{ body = "Revue`n<!-- auditor: sha=$($script:Head) verdict=approve -->" })
        (Merge).Decision | Should -Be 'allow'
    }
    It 'refuse une PR modifiée après la revue' {
        Set-Pr @(@{ body = '<!-- auditor: sha=0000000aaaaaaa1111111bbbbbbb2222222ccccc verdict=approve -->' })
        (Merge).Reason | Should -Match 'Relancer /audit-pr'
    }
    It 'refuse une PR dont la dernière revue demande des changements' {
        Set-Pr @(
            @{ body = "<!-- auditor: sha=$($script:Head) verdict=approve -->" },
            @{ body = "<!-- auditor: sha=$($script:Head) verdict=changes -->" })
        (Merge).Decision | Should -Be 'deny'
    }
    It 'refuse la fusion par un autre agent que git-ops' {
        Set-Pr @(@{ body = "<!-- auditor: sha=$($script:Head) verdict=approve -->" })
        (Invoke-Hook -Data (Bash 'gh pr merge 7' 'auditor') -Env @{ HARNESS_TEST_PR_JSON = $script:PrFile }).Decision | Should -Be 'deny'
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
        @{ path = '.claude/agents/dev.md' }, @{ path = '.github/workflows/ci.yml' }, @{ path = '.gitignore' }, @{ path = 'CLAUDE.md' }
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

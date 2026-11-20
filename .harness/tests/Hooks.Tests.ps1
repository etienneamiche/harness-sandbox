#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
# Autotests des hooks du harness : chaque règle reçoit une entrée simulée,
# exactement comme Claude Code la lui enverrait, dans un vrai processus pwsh.
# Lancés par `.harness/tools/doctor.ps1 -Deep` et par la CI du harness.

BeforeDiscovery {
    # Certains tests dépendent du type de dépôt (gitflow ou non) : on lit sa config.
    $cfg = Get-Content (Join-Path $PSScriptRoot '..' 'harness.json') -Raw | ConvertFrom-Json
    $Gitflow = [bool] $cfg.requireIssueRef
    $IsRoot = $cfg.kind -eq 'root'
    $HasReact = Test-Path (Join-Path $PSScriptRoot '..' 'modules' 'react')
    $HasDotnet = Test-Path (Join-Path $PSScriptRoot '..' 'modules' 'dotnet')
    $HasInfra = Test-Path (Join-Path $PSScriptRoot '..' 'modules' 'infra')
    $Tools = @(Get-ChildItem (Join-Path $PSScriptRoot '..' 'tools') -File -Filter '*.ps1' | ForEach-Object { @{ name = $_.Name; path = $_.FullName } })
}

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Dispatch = Join-Path $Root '.harness' 'hooks' 'dispatch.ps1'

    # Variables d'environnement : Save-Env relève leur état (absente, vide ou définie), Set-EnvVar
    # pose une valeur ($null retire la variable) et Restore-Env remet l'état relevé. Pas de
    # [Environment]::SetEnvironmentVariable(…, $null) : PowerShell y passe $null sous forme de '',
    # et la variable reste présente et vide (avec HOME vide, git ne trouve plus ~/.gitconfig).
    function Save-Env([string[]] $Names) {
        foreach ($n in $Names) { [pscustomobject]@{ Name = $n; Present = Test-Path "env:$n"; Value = [Environment]::GetEnvironmentVariable($n) } }
    }
    function Set-EnvVar([string] $Name, $Value) {
        if ($null -eq $Value) { Remove-Item "env:$Name" -ErrorAction SilentlyContinue } else { Set-Item "env:$Name" ([string] $Value) }
    }
    function Restore-Env([object[]] $State) {
        foreach ($s in $State) { Set-EnvVar $s.Name ($s.Present ? $s.Value : $null) }
    }
    # Lance $Block avec les variables de $Variables, puis remet l'environnement comme avant, même
    # si une pose ou le bloc échoue. Le bloc rend son résultat par sa sortie.
    function Invoke-WithEnv([System.Collections.IDictionary] $Variables, [scriptblock] $Block) {
        $__state = @(Save-Env @($Variables.Keys))
        try {
            foreach ($__name in $Variables.Keys) { Set-EnvVar $__name $Variables[$__name] }
            & $Block
        }
        finally { Restore-Env $__state }
    }

    # Git sans la config du poste ni celle du système (signature, fins de ligne, identité…) : les
    # dépôts jetables des tests se comportent de même partout. Remis comme avant en fin de fichier.
    $script:GitConfig = Join-Path ([IO.Path]::GetTempPath()) "harness-gitconfig-$([guid]::NewGuid())"
    Set-Content $script:GitConfig ''
    $script:GitIsolation = @{
        GIT_CONFIG_GLOBAL = $script:GitConfig; GIT_CONFIG_NOSYSTEM = '1'; GIT_CONFIG_COUNT = $null; GIT_CONFIG_PARAMETERS = $null
        GIT_AUTHOR_NAME = 'harness-test'; GIT_AUTHOR_EMAIL = 'harness-test@example.invalid'
        GIT_COMMITTER_NAME = 'harness-test'; GIT_COMMITTER_EMAIL = 'harness-test@example.invalid'
    }
    $script:GitEnvBefore = @(Save-Env @($script:GitIsolation.Keys))
    foreach ($k in $script:GitIsolation.Keys) { Set-EnvVar $k $script:GitIsolation[$k] }

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
        $out = Invoke-WithEnv $Env { $json | pwsh -NoProfile -NonInteractive -File $Dispatch $EventName }

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
    function PowerShell([string] $Command, [string] $Agent = '') { Tool 'PowerShell' @{ command = $Command } $Agent }

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
    It 'refuse git merge hors git-ops' { (Invoke-Hook -Data (Bash 'git merge origin/develop')).Decision | Should -Be 'deny' }
    It 'laisse les lectures git merge-base et merge-tree à la session (<cmd>)' -ForEach @(
        @{ cmd = 'git merge-base --is-ancestor v0.1.0 origin/develop' }
        @{ cmd = 'git merge-tree --write-tree main develop' }
    ) { (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'allow' }
    It 'réserve aussi git commit-tree à git-ops' { (Invoke-Hook -Data (Bash 'git commit-tree HEAD^{tree} -p HEAD -m "fix: x (#1)"')).Decision | Should -Be 'deny' }
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

Describe 'board.ps1 : carte d''une issue sur le Project' {
    BeforeAll { $script:BoardScript = Join-Path $script:Root '.harness' 'tools' 'board.ps1' }
    It 'réserve board.ps1 à git-ops' {
        (Invoke-Hook -Data (Bash "pwsh -NoProfile -File .harness/tools/board.ps1 -Issue 7 -Status 'En revue'" 'dev')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash "pwsh -NoProfile -File .harness/tools/board.ps1 -Issue 7 -Status 'En revue'")).Decision | Should -Be 'deny'
    }
    It 'laisse git-ops lancer board.ps1' {
        (Invoke-Hook -Data (Bash "pwsh -NoProfile -File .harness/tools/board.ps1 -Issue 7 -Status 'En revue'" 'git-ops')).Decision | Should -Be 'allow'
    }
    It 'refuse un statut hors des cinq colonnes, avant tout appel à gh (<status>)' -ForEach @(
        @{ status = 'Done' }, @{ status = 'En attente' }
    ) {
        $out = pwsh -NoProfile -NonInteractive -File $script:BoardScript -Issue 7 -Status $status -Repo 'o/r' 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'Status'
    }
    It 'refuse un numéro d''issue invalide et un -Repo mal formé (<param>)' -ForEach @(
        @{ param = 'Issue'; issue = 0; repo = 'o/r' }, @{ param = 'Repo'; issue = 7; repo = 'pas un dépôt' }
    ) {
        $out = pwsh -NoProfile -NonInteractive -File $script:BoardScript -Issue $issue -Status 'Fait' -Repo $repo 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match $param
    }
    It 'ne confond pas un autre script avec board.ps1 (<cmd>)' -ForEach @(
        @{ cmd = 'pwsh -NoProfile -File scripts/dashboard.ps1' }, @{ cmd = 'pwsh -File tools/leaderboard.ps1 -Top 5' }, @{ cmd = './scripts/storyboard.ps1' }
    ) { (Invoke-Hook -Data (Bash $cmd 'dev')).Decision | Should -Be 'allow' }
    It 'réserve les écritures gh project à git-ops (<cmd>)' -ForEach @(
        @{ cmd = 'gh project item-edit --id X --project-id Y --field-id Z --single-select-option-id W' },
        @{ cmd = 'gh project item-add 1 --owner o --url https://github.com/o/r/issues/7' }
    ) {
        (Invoke-Hook -Data (Bash $cmd 'dev')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow'
    }
    It 'laisse lire le Project (<cmd>)' -ForEach @(
        @{ cmd = 'gh project list --owner o' }, @{ cmd = 'gh project item-list 1 --owner o --format json' }
    ) { (Invoke-Hook -Data (Bash $cmd 'dev')).Decision | Should -Be 'allow' }
}

Describe 'git-guard : le texte d''un message n''est pas une option' {
    It 'accepte un message qui parle d''options (<label>)' -ForEach @(
        @{ label = '-m'; cmd = 'git commit -m "feat(scripts): add -Days and -WhatIf to clean-exports (#5)"' }
        @{ label = 'heredoc'; cmd = "git commit -F - <<'EOF'`nfeat(scripts): clean up old exports (#5)`n`nDeletes the CSV older than -Days days; -WhatIf lists them.`nNever use --no-verify or git add -A.`nEOF" }
        @{ label = 'here-string'; cmd = "git commit -m @'`nfeat(scripts): clean up old exports (#5)`n`n-Path and -All are optional.`n'@" }
        @{ label = 'apostrophes'; cmd = "git commit -m 'fix(api): handle -a in names (#3)'" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'refuse toujours git commit -a hors du texte cité (<cmd>)' -ForEach @(
        @{ cmd = 'git commit -a -m "feat: x (#1)"' }, @{ cmd = 'git commit -am "feat: x (#1)"' },
        @{ cmd = 'git commit --all -m "feat: x (#1)"' }, @{ cmd = 'git commit -m "feat: x (#1)" -a' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason | Should -Match 'commit -a' }
    It 'refuse toujours --no-verify hors du texte cité' {
        (Invoke-Hook -Data (Bash 'git commit --no-verify -m "feat: x (#1)"' 'git-ops')).Reason | Should -Match 'no-verify'
    }
    It 'voit une option seule entre guillemets (<cmd>)' -ForEach @(
        @{ cmd = 'git commit "--no-verify" -m "feat: x (#1)"' }, @{ cmd = "git commit '-a' -m 'feat: x (#1)'" }, @{ cmd = 'git add "."' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'deny' }
    It 'accepte -a comme valeur de -m, et dans le corps d''un heredoc' {
        (Invoke-Hook -Data (Bash 'git commit -m "-a" -m "feat: x (#1)"' 'git-ops')).Decision | Should -Be 'allow'
        (Invoke-Hook -Data (Bash "git commit -F - <<'EOF'`nfeat: x (#1)`n`nThe -a flag and git add . are refused.`nEOF" 'git-ops')).Decision | Should -Be 'allow'
    }
    It 'ne masque pas ce que le shell exécute (<label>)' -ForEach @(
        @{ label = 'substitution dans des guillemets'; cmd = 'echo "$(git push --force origin feature/x)"' }
        @{ label = 'fin de la ligne d''un heredoc'; cmd = "git commit -F - <<EOF --no-verify`nfeat: x (#1)`nEOF" }
        @{ label = 'fin de ligne d''un heredoc cité'; cmd = "git commit -F - <<'EOF' --no-verify`nfeat: x (#1)`nEOF" }
        @{ label = 'heredoc dans une chaîne'; cmd = "echo `"<<'EOF'`"`ngit worktree add ../x`nEOF" }
        @{ label = 'heredoc dans un commentaire'; cmd = "echo hi # <<'EOF'`ngit push --force origin x`nEOF" }
        @{ label = 'apostrophe échappée (bash)'; cmd = "echo \' ; git commit -a -m x ; echo \'" }
        @{ label = 'apostrophe échappée (pwsh)'; cmd = "echo `` `' ; git commit -a -m x ; echo `` `'" }
        @{ label = '\" dans une chaîne pwsh'; cmd = 'git commit -m "x\" --no-verify "y"' }
        @{ label = 'apostrophe dans un commentaire'; cmd = "echo a # it's`ngit worktree add ../x # '" }
        @{ label = 'apostrophe dans une chaîne non littérale'; cmd = "echo `"`$x it's`" ; git push --force origin x ; echo 'y'" }
        @{ label = 'guillemet typographique (pwsh)'; cmd = "echo 'a$([char]0x2019) ; git push --force origin x ; $([char]0x2019)b'" }
        @{ label = 'commentaire bloc pwsh'; cmd = "<# ' #> git push --force origin x <# ' #>" }
        @{ label = 'here-string qui contient une apostrophe'; cmd = "echo @'`nit's`n'@ ; git worktree add ../x ; echo '`n'@" }
        @{ label = 'chaîne pwsh sur plusieurs lignes'; cmd = "echo `"`$x`n`" ; git push --force origin x ; `"z`"" }
        @{ label = 'substitution dans un heredoc non cité'; cmd = "cat <<EOF`n'`$(git push --force origin x)'`nEOF" }
        @{ label = 'stop-parsing pwsh'; cmd = "git --% commit -a -m 'x'" }
        @{ label = 'stop-parsing pwsh, option dans une apostrophe'; cmd = "git --% commit -m 'x --no-verify'" }
        @{ label = 'chaîne bash $''…'' avec \'''; cmd = "git commit -m `$'x\'' --no-verify -m ''" }
        @{ label = 'délimiteur de heredoc à moitié cité'; cmd = "cat <<'E'OF`nx`nEOF`ngit push --force origin main`nE" }
        @{ label = 'option entre guillemets avec sa valeur'; cmd = "git push '--force-with-lease=main' origin main" }
    ) { (Invoke-Hook -Data (Bash $cmd 'dev')).Decision | Should -Be 'deny' }
    # git-ops a droit à commit et push : seule la règle des interdits peut refuser, d'où le contrôle du motif.
    It 'voit un interdit confié à un autre programme (<label>)' -ForEach @(
        @{ label = 'bash -c, push'; cmd = 'bash -c "git push --force origin x"'; reason = 'push forc' }
        @{ label = 'bash -c, commit'; cmd = 'bash -c "git commit --no-verify -m x"'; reason = 'no-verify' }
        @{ label = 'bash -c, add'; cmd = "bash -c 'git add -A'"; reason = 'git add -A' }
        @{ label = 'sh -c'; cmd = "sh -c 'git worktree add ../y'"; reason = 'worktrees' }
        @{ label = 'pwsh -Command'; cmd = 'pwsh -NoProfile -Command "git push --force origin x"'; reason = 'push forc' }
        @{ label = 'tube vers bash'; cmd = "echo 'git add -A' | bash"; reason = 'git add -A' }
        @{ label = 'iex'; cmd = "iex 'git push --force origin x'"; reason = 'push forc' }
        @{ label = 'tube vers iex'; cmd = "'git add .' | iex"; reason = 'git add -A' }
        @{ label = 'Invoke-Expression'; cmd = "Invoke-Expression 'git commit -a -m x'"; reason = 'commit -a' }
        @{ label = 'eval'; cmd = "eval 'git rebase -i HEAD~2'"; reason = 'rebase' }
        @{ label = 'scriptblock'; cmd = "& ([scriptblock]::Create('git add -A'))"; reason = 'git add -A' }
        @{ label = 'bash -lc'; cmd = 'bash -lc "git add --all"'; reason = 'git add -A' }
        @{ label = 'cmd /c'; cmd = 'cmd /c "git add -A"'; reason = 'git add -A' }
        @{ label = 'chemin complet entre guillemets'; cmd = '& "C:\Program Files\Git\bin\bash.exe" -c "git add -A"'; reason = 'git add -A' }
        @{ label = 'programme dans une variable'; cmd = "`$s = 'bash'; & `$s -c 'git add -A'"; reason = 'git add -A' }
        @{ label = 'texte dans une variable'; cmd = "`$c = 'git add -A'; iex `$c"; reason = 'git add -A' }
        @{ label = 'shell par défaut'; cmd = "`$SHELL -c 'git add -A'"; reason = 'git add -A' }
        @{ label = 'heredoc vers bash'; cmd = "bash <<'EOF'`ngit add .`nEOF"; reason = 'git add -A' }
        @{ label = 'heredoc par un tube'; cmd = "cat <<'EOF' | sh`ngit worktree add ../y`nEOF"; reason = 'worktrees' }
        @{ label = 'here-string vers bash'; cmd = "bash <<<'git add -A'"; reason = 'git add -A' }
        @{ label = 'source'; cmd = "source <(echo 'git add -A')"; reason = 'git add -A' }
        @{ label = 'point'; cmd = ". <(echo 'git add -A')"; reason = 'git add -A' }
        @{ label = 'python -c'; cmd = "python -c `"import os; os.system('git add -A')`""; reason = 'git add -A' }
        @{ label = 'ssh'; cmd = "ssh hote 'git push --force origin x'"; reason = 'push forc' }
        @{ label = 'watch'; cmd = "watch 'git add -A'"; reason = 'git add -A' }
        @{ label = 'sous-shell'; cmd = '(git add -A)'; reason = 'git add -A' }
        @{ label = 'substitution'; cmd = 'echo $(git add .)'; reason = 'git add -A' }
        @{ label = 'shell par défaut, here-string'; cmd = "`$SHELL <<<'git push --force origin x'"; reason = 'push forc' }
        @{ label = 'programme dans une variable, heredoc'; cmd = "`$s <<'EOF'`ngit push --force origin x`nEOF"; reason = 'push forc' }
        @{ label = '-c collé'; cmd = "`$SHELL -c'git push --force origin x'"; reason = 'push forc' }
        @{ label = 'variable, -Command'; cmd = "`$p -Command 'git push --force origin x'"; reason = 'push forc' }
        @{ label = 'COMSPEC'; cmd = "`$COMSPEC /c 'git push --force origin x'"; reason = 'push forc' }
        @{ label = 'InvokeScript'; cmd = "`$ExecutionContext.InvokeCommand.InvokeScript('git push --force origin x')"; reason = 'push forc' }
        @{ label = 'point dans un bloc'; cmd = "{ . <(echo 'git push --force origin x'); }"; reason = 'push forc' }
        @{ label = 'point après then'; cmd = "if true; then . <(echo 'git push --force origin x'); fi"; reason = 'push forc' }
        @{ label = 'substitution exécutée'; cmd = "`$(printf 'git push --force origin x')"; reason = 'push forc' }
        @{ label = 'trap'; cmd = "trap 'git push --force origin x' EXIT"; reason = 'push forc' }
        @{ label = 'alias'; cmd = "shopt -s expand_aliases; alias y='git push --force origin x'; y"; reason = 'push forc' }
        @{ label = 'awk'; cmd = "awk 'BEGIN{system(`"git push --force origin x`")}'"; reason = 'push forc' }
        @{ label = 'env -S'; cmd = "env -S 'git push --force origin x'"; reason = 'push forc' }
        @{ label = 'make'; cmd = "make -f - <<'EOF'`nall:`n`tgit push --force origin x`nEOF"; reason = 'push forc' }
        @{ label = 'script écrit dans la même commande'; cmd = "cat > x.sh <<'EOF'`ngit push --force origin x`nEOF`n./x.sh"; reason = 'push forc' }
        @{ label = 'option de texte hors de git et gh'; cmd = "bash -c -m 'git add -A'"; reason = 'git add -A' }
        @{ label = 'option de texte d''un echo'; cmd = "echo x --body 'git add -A' | bash"; reason = 'git add -A' }
        @{ label = 'suivi d''une redirection'; cmd = 'bash -c "git add -A>/dev/null"'; reason = 'git add -A' }
        @{ label = 'suivi d''un \n'; cmd = "bash -c `$'git add -A\n'"; reason = 'git add -A' }
        @{ label = 'commande après le heredoc d''une substitution'; cmd = "git commit -m `"`$(cat <<'EOF'`nx (#1)`nEOF`ngit add -A`nEOF`n)`""; reason = 'git add -A' }
        @{ label = 'autre commande dans une substitution'; cmd = "git commit -m `"`$(git add -A; cat <<'EOF'`nx (#1)`nEOF`n)`""; reason = 'git add -A' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason | Should -Match $reason }
    It 'accepte un texte qui cite un interdit ou un shell, dans une option de texte (<label>)' -ForEach @(
        @{ label = 'message qui cite un interdit'; cmd = 'git commit -m "docs: explain why --no-verify is banned (#1)"' }
        @{ label = 'message qui cite une commande enveloppée'; cmd = "git commit -m `"docs: bash -c 'git add -A' is refused (#1)`"" }
        @{ label = 'message réduit au nom d''un shell'; cmd = "git commit -m 'bash' -m 'feat: never git add -A (#1)'" }
        @{ label = 'heredoc qui cite une commande enveloppée'; cmd = "git commit -F - <<'EOF'`ndocs: wrapped commands (#1)`n`nbash -c `"git push --force`" is refused.`nEOF" }
        @{ label = 'heredoc dans une substitution'; cmd = "git commit -m `"`$(cat <<'EOF'`ndocs: x (#1)`n`nRefuse ``git add -A`` under bash, and `"--no-verify`".`nEOF`n)`"" }
        @{ label = 'corps de PR dans une substitution'; cmd = "gh pr create --title `"docs: --no-verify`" --body `"`$(cat <<'EOF'`nNever git add -A.`nEOF`n)`"" }
        @{ label = 'heredoc par un tube vers git'; cmd ="cat <<'EOF' | git commit -F -`ndocs: x (#1)`n`nNever git add -A.`nEOF" }
        @{ label = 'heredoc vers un fichier .md'; cmd = "cat > /tmp/audit-61.md <<'EOF'`nNever git add -A.`nEOF" }
        @{ label = 'corps de commentaire'; cmd = "gh issue comment 1 --body 'bash -c `"git add -A`" est refusé'" }
        @{ label = 'variable de texte'; cmd = "`$body = @'`nNever git add -A.`n'@`n[IO.File]::WriteAllText(`$f, `$body)" }
        @{ label = 'message d''un tag'; cmd = "git tag -a v1.0.0 -m 'never --no-verify'" }
        @{ label = 'dossier cité par -C'; cmd = "git -C 'C:\repo\app' commit -m 'docs: --no-verify (#1)'" }
        @{ label = 'sujet de merge-pr'; cmd = 'pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 3 -Subject "docs: explain why --no-verify is banned (#1)"' }
        @{ label = 'autre sujet de merge-pr'; cmd = 'pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 3 -Subject "fix(hooks): refuse git add -A (#60)"' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'ne prend pas un mot de la commande pour un programme (<label>)' -ForEach @(
        @{ label = 'watch.ts'; cmd = 'git add src/watch.ts && git commit -m "fix: explain why --no-verify is banned (#1)"' }
        @{ label = 'source/'; cmd = 'git add source/app.ts && git commit -m "feat(scripts): add -Days (#5)"' }
        @{ label = 'cmd/'; cmd = 'git add cmd/api/main.go && git commit -m "docs: explain why --no-verify is banned (#1)"' }
        @{ label = 'eval.ts'; cmd = 'git commit -m "docs: --no-verify (#1)" -- src/eval.ts' }
        @{ label = 'ssh://'; cmd = 'git remote add up ssh://git@host/x.git && git commit -m "docs: --no-verify (#1)"' }
        @{ label = 'label python'; cmd = 'gh issue create --title "x" --label python --body "Never use --no-verify"' }
        @{ label = 'gh run watch'; cmd = 'gh run watch 123 && gh issue comment 1 --body "Pas de --no-verify"' }
        @{ label = 'chemin d''un shell dans un corps'; cmd = "gh issue comment 1 --body 'Never git add -A with /usr/bin/bash'" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'laisse passer un programme qui ne porte aucun interdit, ni le message qui suit (<label>)' -ForEach @(
        @{ label = 'script bash puis commit'; cmd = 'bash scripts/test.sh && git commit -m "feat: x (#1)"' }
        @{ label = 'script bash puis message qui cite'; cmd = 'bash scripts/test.sh && git commit -m "docs: --no-verify (#1)"' }
        @{ label = 'pytest puis message'; cmd = 'python -m pytest && git commit -m "feat(scripts): add -Days to clean-exports (#5)"' }
        @{ label = 'script pwsh puis message'; cmd = 'pwsh -NoProfile -File scripts/test.ps1 && git commit -m "feat(scripts): add -Days to clean-exports (#5)"' }
        @{ label = 'outil du harness'; cmd = 'pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 3 -Subject "fix: y (#1)"' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'accepte un chemin relatif Windows dans git add (<cmd>)' -ForEach @(
        @{ cmd = 'git add .\src\app.ts' }, @{ cmd = 'git add .\.harness\tools\doctor.ps1' }, @{ cmd = 'git add .\CHANGELOG.md .\README.md' }, @{ cmd = 'git add ".\src\app.ts"' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'refuse toujours git add . (<cmd>)' -ForEach @(
        @{ cmd = 'git add .\' }, @{ cmd = 'git add .>x' }, @{ cmd = '(git add .)' }, @{ cmd = "bash -c `$'git add .\n'" }
        @{ cmd = 'git add ./' }, @{ cmd = 'git add .\.' }, @{ cmd = 'git add ./.' }, @{ cmd = '& { git add -A}' }, @{ cmd = 'if ($true) {git add .}' }
        @{ cmd = "bash -c `$'git add ./\n'" }, @{ cmd = "`$'git add .\t'" }
        @{ cmd = "echo 'a`$'; bash -c `$'git add .\n'" }, @{ cmd = "grep 'x`$' f; bash -c `$'git\tadd -A'" }
        @{ cmd = "bash -c `$'echo \'x\'; git add .\n'" }, @{ cmd = "bash -c `$'echo \'x\'; git\tadd -A'" }
        @{ cmd = "x=`$'git add .\n'; bash -c `"`$x`"" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason | Should -Match 'git add -A' }
    It 'lit \n, \r et \t comme un nom de dossier, hors de $''…'' (<cmd>)' -ForEach @(
        @{ cmd = 'git add .\t' }, @{ cmd = 'git add .\n' }, @{ cmd = 'git add .\r .\t' }, @{ cmd = "git add .\t; x=`$'y'" }
        @{ cmd = "grep 'x`$' a.md; git add .\tests\a.ps1; echo 'y'" }, @{ cmd = "grep 'x`$' a.md; git add .\readme.md; echo 'y'" }
        @{ cmd = "`"`$x`" -match 'a`$'; git add .\tools\b.ps1; git commit -m 'x (#1)'" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'ne coupe pas un chemin quand la commande contient $''…'' ou un ''x$'' (<cmd>)' -ForEach @(
        @{ cmd = "git -C C:\repo\app push --force origin x; if (`"`$tag`" -match '^v\d+`$') { echo ok }"; reason = 'push forc' }
        @{ cmd = "git -C C:\repo\app add -A; if (`"`$tag`" -match '^v\d+`$') { echo ok }"; reason = 'git add -A' }
        @{ cmd = "git -C C:\repo\services\harness add -A; `"`$x`" | Select-String 'md`$'"; reason = 'git add -A' }
        @{ cmd = "git -C C:\repo\app commit -a -m `"x (#1)`"; `$t = `"`$a`"; `$t -match 'y`$'"; reason = 'git commit -a' }
        @{ cmd = "git -C C:\repo\tools push --force origin x; echo `$'ok'"; reason = 'push forc' }
        @{ cmd = "git -C C:\new rebase -i HEAD~2; echo `$'a'"; reason = 'rebase interactif' }
        @{ cmd = "git -C C:\\repo\\tools push --force origin x; printf `$'ok\n'"; reason = 'push forc' }
        @{ cmd = "`"`$t`" -match 'x`$'; git -C C:\new add -A; echo 'y'"; reason = 'git add -A' }
        @{ cmd = "echo `$'a'; git -C C:\new push --force origin x"; reason = 'push forc' }
    ) {
        $result = (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason
        $result | Should -Match $reason
        $result | Should -Not -Match 'lu comme une commande'
    }
    It 'ne laisse pas un séparateur cité cacher une vraie option (<cmd>)' -ForEach @(
        @{ cmd = "git add 'R&D notes.md' ."; reason = 'git add -A' }
        @{ cmd = 'git add "R&D.md" -A'; reason = 'git add -A' }
        @{ cmd = "git add 'a;b' ."; reason = 'git add -A' }
        @{ cmd = "git add --pathspec-from-file='a;b' -A"; reason = 'git add -A' }
        @{ cmd = "git commit --author='A & B <a@b.c>' -a -m `"x (#1)`""; reason = 'git commit -a' }
        @{ cmd = "git commit --author 'A; B <a@b.c>' --all -m `"x (#1)`""; reason = 'git commit -a' }
        @{ cmd = "git rebase --exec 'make; make test' -i HEAD~3"; reason = 'rebase interactif' }
        @{ cmd = 'git rebase --exec="a && b" --interactive HEAD~2'; reason = 'rebase interactif' }
        @{ cmd = "git push -o 'a;b' --force origin x"; reason = 'push forc' }
        @{ cmd = "git push origin 'x|y' --force"; reason = 'push forc' }
    ) {
        $result = (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason
        $result | Should -Match $reason
        $result | Should -Not -Match 'lu comme une commande'
    }
    It 'accepte un séparateur cité sans option interdite (<cmd>)' -ForEach @(
        @{ cmd = "git add 'R&D notes.md'" }
        @{ cmd = "git commit -m 'fix: a; b (#1)'" }
        @{ cmd = "git commit --author='A & B <a@b.c>' -m `"x (#1)`"" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'ne prend pas une redirection pour une fin de commande (<cmd>)' -ForEach @(
        @{ cmd = 'git commit 2>&1 -m "docs: --no-verify (#1)"'; decision = 'allow'; reason = '' }
        @{ cmd = 'git commit -m "docs: --no-verify (#1)" >&2'; decision = 'allow'; reason = '' }
        @{ cmd = 'git status || git commit -m "docs: --no-verify (#1)"'; decision = 'allow'; reason = '' }
        @{ cmd = 'git commit 2>&1 -a -m "x (#1)"'; decision = 'deny'; reason = 'git commit -a' }
        @{ cmd = 'git push origin x 2>&1 --force'; decision = 'deny'; reason = 'push forc' }
        @{ cmd = 'git commit &>log -m "docs: --no-verify (#1)"'; decision = 'allow'; reason = '' }
        @{ cmd = 'git push origin x &>log --force'; decision = 'deny'; reason = 'push forc' }
        @{ cmd = 'git add a.ts &>log -A'; decision = 'deny'; reason = 'git add -A' }
        @{ cmd = 'git commit &>log -a -m "x (#1)"'; decision = 'deny'; reason = 'git commit -a' }
        @{ cmd = 'git rebase HEAD~3 &>log -i'; decision = 'deny'; reason = 'rebase interactif' }
    ) {
        $result = Invoke-Hook -Data (Bash $cmd 'git-ops')
        $result.Decision | Should -Be $decision
        if ($reason) { $result.Reason | Should -Match $reason }
    }
    It 'reconnaît une option de texte dans sa commande (<label>)' -ForEach @(
        @{ label = 'apostrophe doublée, commit'; cmd = "git commit -m 'docs: l''option --no-verify est interdite (#1)'" }
        @{ label = 'apostrophe doublée, -Days'; cmd = "git commit -m 'feat(scripts): l''option -Days est ajoutée (#5)'" }
        @{ label = 'apostrophe doublée, gh'; cmd = "gh issue comment 1 --body 'L''option --no-verify est interdite'" }
        @{ label = 'apostrophe doublée, merge-pr'; cmd = "pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 3 -Subject 'docs: l''option --no-verify est interdite (#1)'" }
        @{ label = 'affectation, commit'; cmd = '$r = git commit -m "feat(scripts): add -Days (#5)"' }
        @{ label = 'affectation, gh'; cmd = "`$url = gh pr create --title x --body 'Never use --no-verify'" }
        @{ label = 'if pwsh'; cmd = 'if ($?) { git commit -m "feat(scripts): add -Days (#5)" }' }
        @{ label = 'if après une commande'; cmd = 'git add a.txt; if ($LASTEXITCODE -eq 0) { git commit -m "feat(scripts): add -Days (#5)" }' }
        @{ label = 'try'; cmd = "try { git commit -m 'docs: --no-verify (#1)' } catch { throw }" }
        @{ label = 'bloc'; cmd = '{ git commit -m "docs: --no-verify (#1)"; }' }
        @{ label = 'if bash'; cmd = 'if git commit -m "docs: --no-verify (#1)"; then echo ok; fi' }
        @{ label = 'négation'; cmd = '! git commit -m "docs: --no-verify (#1)"' }
        @{ label = 'variable d''environnement'; cmd = 'GIT_AUTHOR_DATE=2026-01-01 git commit -m "feat(scripts): add -Days (#5)"' }
        @{ label = 'env'; cmd = 'env X=1 git commit -m "docs: --no-verify (#1)"' }
        @{ label = 'time'; cmd = 'time git commit -m "docs: --no-verify (#1)"' }
        @{ label = 'chemin vers git'; cmd = '/usr/bin/git commit -m "docs: --no-verify (#1)"' }
        @{ label = 'git.exe entre guillemets'; cmd = '& "C:\Program Files\Git\cmd\git.exe" commit -m "docs: --no-verify (#1)"' }
        @{ label = 'parenthèse dans un dossier'; cmd = 'git -C "C:\Program Files (x86)\app" commit -m "feat(scripts): add -Days (#5)"' }
        @{ label = 'parenthèse dans un auteur'; cmd = "git commit --author='A (B) <a@b.c>' -m `"docs: --no-verify (#1)`"" }
        @{ label = 'parenthèse dans un milestone'; cmd = "gh issue create --milestone 'v1 (beta)' --title x --body 'Never use --no-verify'" }
        @{ label = '; dans un titre, puis heredoc'; cmd = "gh pr create --title `"feat: a; b`" --body-file - <<'EOF'`nNever use --no-verify`nEOF" }
        @{ label = '& dans un titre, puis heredoc'; cmd = "gh pr create --title 'a & b' --body-file - <<'EOF'`nNever use --no-verify`nEOF" }
        @{ label = 'accolades dans un mot'; cmd = 'git commit-tree HEAD^{tree} -p HEAD -m "docs: --no-verify (#1)"' }
        @{ label = 'gh issue close --comment'; cmd = 'gh issue close 1 --comment "Never use --no-verify"' }
        @{ label = 'gh issue close -c'; cmd = 'gh issue close 1 -c "Never use --no-verify"' }
        @{ label = 'gh pr close --comment'; cmd = 'gh pr close 1 --comment "Never use --no-verify"' }
        @{ label = 'option avec ='; cmd = "git commit --message='docs: --no-verify (#1)'" }
        @{ label = '-Subject:'; cmd = '.harness/tools/merge-pr.ps1 -Pr 3 -Subject:"docs: --no-verify (#1)"' }
        @{ label = '-subject en minuscules'; cmd = '.harness/tools/merge-pr.ps1 -Pr 3 -subject "docs: --no-verify (#1)"' }
        @{ label = 'pwsh avec une valeur avant -File'; cmd = 'pwsh -ExecutionPolicy Bypass -File .harness/tools/merge-pr.ps1 -Pr 3 -Subject "docs: --no-verify (#1)"' }
        @{ label = 'trailer'; cmd = 'git commit -m "docs: x (#1)" --trailer "Note: never --no-verify"' }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'accepte un texte écrit ou cherché, sans programme qui l''exécute (<label>)' -ForEach @(
        @{ label = 'here-string vers gh'; cmd = "@'`nNever git add -A now.`n'@ | gh pr comment 3 -F -" }
        @{ label = 'here-string vers git'; cmd = "@'`ndocs: never git add -A now (#1)`n'@ | git commit -F -" }
        @{ label = 'here-string vers un fichier'; cmd = "@'`nNever git add -A now.`n'@ | Set-Content c.md" }
        @{ label = 'Set-Content -Value'; cmd = "Set-Content c.md -Value @'`nNever git add -A now.`n'@" }
        @{ label = 'variable $text'; cmd = "`$text = @'`nNever git add -A now.`n'@" }
        @{ label = 'variable $content'; cmd = "`$content = @'`nNever git add -A now.`n'@" }
        @{ label = 'variable $review'; cmd = "`$review = @'`nNever git add -A now.`n'@" }
        @{ label = 'variable $report'; cmd = "`$report = @'`nNever git add -A now.`n'@" }
        @{ label = 'variable bash puis -m'; cmd = "msg='docs: --no-verify (#1)'; git commit -m `"`$msg`"" }
        @{ label = 'variable bash puis --body'; cmd = "body='Never git add -A'; gh issue comment 1 --body `"`$body`"" }
        @{ label = 'variable bash et heredoc'; cmd = "BODY=`$(cat <<'EOF'`nNever git add -A`nEOF`n); gh issue comment 1 --body `"`$BODY`"" }
        @{ label = 'variable +='; cmd = "`$body += 'Never git add -A'" }
        @{ label = 'variable de portée'; cmd = "`$script:body = 'Never git add -A'" }
        @{ label = 'variable typée'; cmd = "[string]`$body = 'Never git add -A'" }
        @{ label = 'variable d''environnement'; cmd = "`$env:MESSAGE = 'Never git add -A'" }
        @{ label = 'heredoc >>'; cmd = "cat >> x.md <<'EOF'`nNever git add -A`nEOF" }
        @{ label = 'heredoc tee'; cmd = "tee x.md <<'EOF'`nNever git add -A`nEOF" }
        @{ label = 'heredoc, fichier avec une espace'; cmd = "cat > 'x y.md' <<'EOF'`nNever git add -A`nEOF" }
        @{ label = 'heredoc, fichier entre guillemets'; cmd = "cat > `"x.md`" <<'EOF'`nNever git add -A`nEOF" }
        @{ label = 'heredoc dans un sous-shell'; cmd = "(cat > x.md <<'EOF'`nNever git add -A`nEOF`n)" }
        @{ label = 'heredoc .markdown'; cmd = "cat > x.markdown <<'EOF'`nNever git add -A`nEOF" }
        @{ label = 'heredoc .MD'; cmd = "cat > x.MD <<'EOF'`nNever git add -A`nEOF" }
        @{ label = 'gh issue list --search'; cmd = "gh issue list --state open --search 'git add -A refus'" }
        @{ label = 'gh pr list -S'; cmd = "gh pr list -S 'git add -A'" }
        @{ label = 'git log -S'; cmd = "git log -S'git add -A'" }
        @{ label = 'git log -G'; cmd = "git log -G'--no-verify x'" }
        @{ label = 'git log --grep'; cmd = 'git log --grep "bad --no-verify"' }
        @{ label = 'git grep -e'; cmd = "git grep -e 'git add -A'" }
        @{ label = 'Set-Content -Path'; cmd = "Set-Content -Path c.md -Value 'Never git add -A' -Encoding utf8" }
        @{ label = 'Set-Content, valeur d''abord'; cmd = "Set-Content -Value 'Never git add -A' -Path c.md" }
        @{ label = 'Out-File'; cmd = "Out-File -FilePath c.md -InputObject 'Never git add -A'" }
        @{ label = 'Set-Content -Force'; cmd = "Set-Content c.md -Value 'Never git add -A' -Force -Encoding utf8" }
        @{ label = 'Set-Content -Value:'; cmd = "Set-Content -Path c.md -Value:'Never git add -A' -NoNewline" }
        @{ label = 'Add-Content'; cmd = "Add-Content c.md -Value 'Never git add -A'" }
        @{ label = 'Out-File -Append'; cmd = "Out-File -FilePath c.md -InputObject 'Never git add -A' -Append" }
        @{ label = 'here-string et -Encoding'; cmd = "@'`nNever git add -A`n'@ | Set-Content c.md -Encoding utf8" }
        @{ label = 'Set-Content -ErrorAction'; cmd = "Set-Content -Path c.md -Value 'Never git add -A' -ErrorAction Stop" }
        @{ label = 'Set-Content -EA'; cmd = "Set-Content -Path c.md -Value 'Never git add -A' -EA Stop" }
        @{ label = 'Set-Content -ErrorAction:'; cmd = "Set-Content c.md -ErrorAction:Stop -Value 'Never git add -A'" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow' }
    It 'ne prend pas pour du texte ce qu''un programme peut exécuter (<label>)' -ForEach @(
        @{ label = 'merge-pr cité par echo'; cmd = "echo merge-pr.ps1 -Subject '; git push --force origin x' | bash" }
        @{ label = 'merge-pr cité par eval'; cmd = "eval echo merge-pr.ps1 -Subject 'x; git push --force origin x'" }
        @{ label = 'merge-pr cité par bash -c'; cmd = "bash -c '`$2' merge-pr.ps1 -Subject 'git push --force origin x'" }
        @{ label = 'merge-pr cité par ssh'; cmd = "ssh hote merge-pr.ps1 -Subject 'x; git push --force origin x'" }
        @{ label = 'merge-pr et substitution'; cmd = "echo merge-pr.ps1 -Subject `"`$(cat <<'EOF'`n; git push --force origin x`nEOF`n)`" | bash" }
        @{ label = 'pwsh -Command'; cmd = "pwsh -Command merge-pr.ps1 -Subject 'x; git push --force origin x'" }
        @{ label = 'autre programme, git'; cmd = "git-wrapper.sh -m 'git push --force origin x'" }
        @{ label = 'autre programme, git.sh'; cmd = "git.sh --message 'git push --force origin x'" }
        @{ label = 'autre programme, gh'; cmd = "gh-run.sh --body 'git push --force origin x'" }
        @{ label = 'sous-commande qui lance une commande'; cmd = "git bisect run bash -c -m 'git push --force origin x'" }
        @{ label = '-t de gh pr list'; cmd = "gh pr list --json number -t 'git push --force origin x' | bash" }
        @{ label = '-t de gh api'; cmd = "gh api /meta -t 'git push --force origin x' | bash" }
        @{ label = '-m en fin de ligne'; cmd = "git status -m`n'git push --force origin x' | iex" }
        @{ label = '-m de commit en fin de ligne'; cmd = "git commit -m`n'git push --force origin x' | iex" }
        @{ label = '-t en fin de ligne'; cmd = "gh pr list -t`n'git push --force origin x' | iex" }
        @{ label = 'variable en fin de ligne'; cmd = "`$body`n'git push --force origin x' | iex" }
        @{ label = 'variable tenant lieu de programme'; cmd = "msg=eval; `$msg 'git push --force origin x'" }
        @{ label = 'variable dans un tube'; cmd = "`$msg = 'git push --force origin x' | iex" }
        @{ label = 'here-string dans un tube'; cmd = "`$body = @'`ngit push --force origin x`n'@ | bash" }
        @{ label = 'git log -F, tube vers sh'; cmd = "git log -F - | sh <<'EOF'`ngit push --force origin x`nEOF" }
        @{ label = 'heredoc vers un shell, puis vers un fichier'; cmd = "bash <<'B'; cat > x.md <<'A'`ngit push --force origin x`nB`nnotes`nA" }
        @{ label = 'heredoc vers un shell, puis vers git'; cmd = "sh <<'B' && git commit -F - <<'A'`ngit push --force origin x`nB`nmsg (#1)`nA" }
        @{ label = 'here-string vers un fichier, puis un shell'; cmd = "@'`ngit push --force origin x`n'@ | Set-Content c.md | bash" }
        @{ label = 'fichier qui n''est pas du texte'; cmd = "@'`ngit push --force origin x`n'@ | Set-Content c.ps1" }
        @{ label = 'variable dans un argument'; cmd = "iex (`$body = 'git push --force origin x')" }
        @{ label = 'variable dans un groupe, tube ensuite'; cmd = "(`$body = 'git push --force origin x') | iex" }
        @{ label = 'tube en tête de ligne'; cmd = "`$body = 'git push --force origin x'`n| iex" }
        @{ label = 'tee dans un sous-shell, tube ensuite'; cmd = "(tee x.md <<'EOF'`ngit push --force origin x`nEOF`n) | bash" }
        @{ label = 'tee dans un bloc, tube ensuite'; cmd = "{ tee x.md <<'EOF'`ngit push --force origin x`nEOF`n} | bash" }
        @{ label = 'cat et tee dans un sous-shell, tube ensuite'; cmd = "(cat <<'EOF' | tee x.md) | bash`ngit push --force origin x`nEOF" }
        @{ label = 'tee dans une substitution'; cmd = "`$(tee x.md <<'EOF'`ngit push --force origin x`nEOF`n)" }
        @{ label = 'chaîne dans un argument, puis -F -'; cmd = "iex ('git push --force origin x'); git commit -F - <<'EOF'`nx (#1)`nEOF" }
        @{ label = '.md dans la valeur'; cmd = "Set-Content c.ps1 -Value 'git push --force origin x #.md'" }
        @{ label = 'plusieurs cibles'; cmd = "Set-Content a.ps1,b.md -Value 'git push --force origin x'" }
        @{ label = '-PassThru'; cmd = "Set-Content c.md -Value 'git push --force origin x' -PassThru | iex" }
        @{ label = 'Set-Content dans un tube'; cmd = "Set-Content c.md -Value 'git push --force origin x' | iex" }
        @{ label = 'pwsh -com abrégé'; cmd = "pwsh -com merge-pr.ps1 -Subject 'x; git push --force origin x' -File merge-pr.ps1" }
        @{ label = 'nom qui contient text'; cmd = "`$context = 'git push --force origin x'; iex `$context" }
        @{ label = 'redirection entre le sous-shell et le tube'; cmd = "(tee x.md <<'EOF'`ngit push --force origin x`nEOF`n) 2>&1 | bash" }
        @{ label = 'redirection entre le bloc et le tube'; cmd = "{ tee x.md <<'EOF'`ngit push --force origin x`nEOF`n} 2>&1 | bash" }
        @{ label = 'variable, 2>&1, tube'; cmd = "(`$body = 'git push --force origin x') 2>&1 | iex" }
        @{ label = 'variable, > fichier, tube'; cmd = "(`$body = 'git push --force origin x') > y.txt | iex" }
        @{ label = 'variable, &> fichier, tube'; cmd = "(`$body = 'git push --force origin x') &>y.txt | iex" }
        @{ label = '-Exclude pris pour le fichier'; cmd = "Set-Content -Exclude x.md c.ps1 -Value 'git push --force origin x'" }
        @{ label = '-Filter pris pour le fichier'; cmd = "Set-Content -Filter x.md c.ps1 -Value 'git push --force origin x'" }
        @{ label = '-Path: et -Exclude'; cmd = "Set-Content -Path:c.ps1 -Exclude a.md -Value 'git push --force origin x'" }
        @{ label = 'pwsh /c'; cmd = "pwsh /c merge-pr.ps1 -Subject 'x; git push --force origin x' -File merge-pr.ps1" }
        @{ label = 'pwsh --command'; cmd = "pwsh --command merge-pr.ps1 -Subject 'x; git push --force origin x' -File merge-pr.ps1" }
        @{ label = 'pwsh --c'; cmd = "pwsh --c merge-pr.ps1 -Subject 'x; git push --force origin x' -File merge-pr.ps1" }
        @{ label = 'variable, *>&1, tube'; cmd = "(`$body = 'git push --force origin x') *>&1 | iex" }
        @{ label = 'variable, *> fichier, tube'; cmd = "(`$body = 'git push --force origin x') *> y.txt | iex" }
        @{ label = '-ErrorAction et -Exclude'; cmd = "Set-Content -ErrorAction Stop -Exclude x.md c.ps1 -Value 'git push --force origin x'" }
        @{ label = '-EA et autre fichier'; cmd = "Set-Content -EA Stop c.ps1 -Value 'git push --force origin x'" }
        @{ label = '-ErrorAction et -PassThru'; cmd = "Set-Content c.md -Value 'git push --force origin x' -ErrorAction Stop -PassThru | iex" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason | Should -Match 'push forc' }
    It 'dit sans se tromper quand un interdit est cité (<label>)' -ForEach @(
        @{ label = 'here-string en entrée'; cmd = 'git add -A <<<x'; cited = $false }
        @{ label = 'heredoc à côté'; cmd = "git add -A; cat > x.md <<'EOF'`nnotes`nEOF"; cited = $false }
        @{ label = 'variable à côté'; cmd = "`$body = @'`ny`n'@; git add -A"; cited = $false }
        @{ label = 'chaîne non analysable à côté'; cmd = 'git add -A; echo "$x"'; cited = $false }
        @{ label = 'dossier entre guillemets, push'; cmd = 'git -C "a b" push --force origin x'; cited = $false }
        @{ label = 'dossier avec une variable'; cmd = 'git -C "$d" push --force origin x'; cited = $false }
        @{ label = 'dossier entre apostrophes, commit'; cmd = "git -C 'a b' commit -a -m `"x (#1)`""; cited = $false }
        @{ label = 'option globale, add'; cmd = 'git --work-tree "a b" add .'; cited = $false }
        @{ label = '2>&1 avant une option'; cmd = 'git push origin x 2>&1 --force'; cited = $false }
        @{ label = '2>&1 avant -a'; cmd = 'git commit 2>&1 -a -m "x (#1)"'; cited = $false }
        @{ label = '&> avant une option'; cmd = 'git push origin x &>log --force'; cited = $false }
        @{ label = 'dans $''…'''; cmd = "bash -c `$'git add .\n'"; cited = $true }
        @{ label = 'dans une chaîne'; cmd = "bash -c 'git add -A'"; cited = $true }
        @{ label = 'chaîne avec une variable'; cmd = 'git commit -m "docs: --no-verify $x (#1)"'; cited = $true }
        @{ label = 'chaîne avec un guillemet échappé'; cmd = 'git commit -m "docs: \"--no-verify\" (#1)"'; cited = $true }
        @{ label = 'chaîne sur plusieurs lignes'; cmd = "git commit -m `"line1`n`nline2 --no-verify (#1)`""; cited = $true }
    ) {
        $reason = (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason
        if ($cited) { $reason | Should -Match 'lu comme une commande' } else { $reason | Should -Not -Match 'lu comme une commande' }
    }
    It 'préfère un refus de trop sur un texte qu''aucune option de texte ne porte, et explique pourquoi (<label>)' -ForEach @(
        @{ label = 'grep'; cmd = "grep -rn 'git add -A' source/" }
        @{ label = 'grep -c'; cmd = "grep -c 'git add -A' CHANGELOG.md" }
        @{ label = 'echo'; cmd = 'echo "git add -A est interdit"' }
        @{ label = 'argument de script'; cmd = "./scripts/check.sh 'git add -A'" }
        @{ label = 'variable qui ne porte pas un nom de texte'; cmd = "`$cmd = 'git add -A'; echo `$cmd" }
        @{ label = '-F - dans une substitution'; cmd = "url=`$(gh pr create --title x --body-file - <<'EOF'`nNever git add -A`nEOF`n)" }
        @{ label = '-F - dans un groupe, tube ensuite'; cmd = "(gh pr comment 3 -F - <<'EOF'`nNever git add -A`nEOF`n) | tail -1" }
        @{ label = 'Set-Content, -Path: collé'; cmd = "Set-Content -Path:c.md -Value 'Never git add -A'" }
        @{ label = 'Out-File, autre option'; cmd = "Out-File -Width 80 c.md -InputObject 'Never git add -A'" }
        @{ label = 'Set-Content -WhatIf'; cmd = "Set-Content -Path c.md -Value 'Never git add -A' -WhatIf" }
        @{ label = '-F - et tube'; cmd = "git commit -F - <<'EOF' 2>&1 | tail -5`nNever git add -A (#1)`nEOF" }
    ) { (Invoke-Hook -Data (Bash $cmd 'git-ops')).Reason | Should -Match 'lu comme une commande' }
    It 'n''explique rien de plus quand l''interdit est bien une option' {
        (Invoke-Hook -Data (Bash 'git commit -a -m "feat: x (#1)"' 'git-ops')).Reason | Should -Not -Match 'lu comme une commande'
    }
    It 'voit la sous-commande git derrière --% de pwsh, pour les opérations réservées' {
        (Invoke-Hook -Data (Bash "git --% commit -m 'feat: x (#1)'" 'dev')).Decision | Should -Be 'deny'
    }
    It 'accepte un chemin Windows entre guillemets doubles (<label>)' -ForEach @(
        @{ label = 'git -C'; cmd = 'git -C "C:\repo\app" commit -m "feat(scripts): add -Days (#16)"' }
        @{ label = 'cd'; cmd = 'cd "C:\repo\app" && git commit -m "feat(scripts): add -Days (#16)"' }
    ) {
        (Invoke-Hook -Data (Bash $cmd 'git-ops')).Decision | Should -Be 'allow'
        (Invoke-Hook -Data (PowerShell $cmd 'git-ops')).Decision | Should -Be 'allow'
    }
    It 'refuse un \ qui échappe, dans une chaîne' {
        (Invoke-Hook -Data (Bash 'git commit -m "x\" -a "y"' 'git-ops')).Decision | Should -Be 'deny'
    }
    It 'refuse une option derrière --%, avec l''outil PowerShell (<cmd>)' -ForEach @(
        @{ cmd = "git --% commit -m 'feat: x (#16) -a'" }, @{ cmd = 'git --% commit "-a" -m x' },
        @{ cmd = 'git --% push origin x "--force"' }, @{ cmd = "git -C . --% commit --no-verify -m 'x'" }
    ) { (Invoke-Hook -Data (PowerShell $cmd 'git-ops')).Decision | Should -Be 'deny' }
    It 'garde un chemin Windows sans masquer la suite' {
        (Invoke-Hook -Data (Bash 'git -C C:\repo\app commit -m "feat(scripts): add -Days (#5)"' 'git-ops')).Decision | Should -Be 'allow'
        (Invoke-Hook -Data (Bash 'git -C C:\repo\app commit -a -m "feat: x (#5)"' 'git-ops')).Decision | Should -Be 'deny'
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
            Invoke-WithEnv $vars {
                $out = pwsh -NoProfile -NonInteractive -File $script:MergeScript @ScriptArgs 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
            }
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
    BeforeAll { Import-Module (Join-Path $script:Root '.harness' 'hooks' 'HarnessHooks.psm1') -Force }
    It 'refuse au premier essai puis accepte la même commande' {
        (Invoke-Hook -Data (Bash 'rm -rf build')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'rm -rf build')).Decision | Should -Be 'allow'
    }
    It 'accepte au deuxième essai chaque commande d''une même session' {
        $cmds = 'rm -rf build', 'git reset --hard HEAD~1', 'git branch -D old'
        foreach ($c in $cmds) {
            (Invoke-Hook -Data (Bash $c)).Decision | Should -Be 'deny'
            (Invoke-Hook -Data (Bash $c)).Decision | Should -Be 'allow'
        }
        foreach ($c in $cmds) { (Invoke-Hook -Data (Bash $c)).Decision | Should -Be 'allow' }
        $state = Get-HarnessStatePath $script:SessionId 'destructive'
        @(Get-Content $state -Raw | ConvertFrom-Json).Count | Should -Be 3
    }
    It 'n''est pas bloqué par un état écrit par l''ancienne version' {
        # L'ancienne version écrivait un tableau d'un seul élément, les empreintes collées, qui ne correspond à aucune commande.
        '["0123456789abcdef0123456789abcdef"]' | Set-Content (Get-HarnessStatePath $script:SessionId 'destructive')
        (Invoke-Hook -Data (Bash 'rm -rf build')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'rm -rf build')).Decision | Should -Be 'allow'
        (Invoke-Hook -Data (Bash 'git branch -D old')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'git branch -D old')).Decision | Should -Be 'allow'
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

Describe 'infra-guard et infra-approval (module infra)' -Skip:(-not $HasInfra) {
    BeforeAll {
        function Get-Code([string] $Reason) { if ($Reason -match 'ok infra (\d{4})') { $Matches[1] } }
    }
    It 'demande un accord pour l''action <cmd>' -ForEach @(
        @{ cmd = 'kubectl --context home apply -f clusters/home/platform/x.yaml' }, @{ cmd = 'kubectl --context=vps rollout restart deploy/web' },
        @{ cmd = 'kubectl --context home -n app exec web -- sh' }, @{ cmd = 'helm --kube-context home upgrade web charts/app' },
        @{ cmd = 'tofu -chdir=tofu/dns apply dns.tfplan' }, @{ cmd = 'tofu import cloudflare_record.www x' }, @{ cmd = 'tofu state rm x.y' },
        @{ cmd = 'wsl ansible-playbook -i ansible/inventory.yml ansible/site.yml' }, @{ cmd = 'wsl ansible all -m ping' },
        @{ cmd = 'wsl ansible edge -m shell -a "uptime" --check' }, @{ cmd = 'argocd app sync web' }, @{ cmd = 'bash -c "kubectl --context home apply -f x.yaml"' },
        @{ cmd = 'wsl ansible-playbook -i ansible/inventory.yml ansible/site.yml -c local' }, @{ cmd = 'wsl -d Ubuntu ansible-playbook ansible/site.yml # --check' },
        @{ cmd = 'tofu -chdir=tofu/dns test' }, @{ cmd = 'kubectl --context home auth reconcile -f rbac.yaml' }, @{ cmd = 'helm --kube-context home test web' },
        @{ cmd = 'argocd appset delete web' }, @{ cmd = 'wsl ansible-pull -U https://example.invalid/repo.git' },
        @{ cmd = '& "C:\tools\tofu.exe" -chdir=tofu/dns apply dns.tfplan' }, @{ cmd = 'ssh node-01 sudo k3s kubectl --context home apply -f x.yaml' },
        @{ cmd = 'wsl bash -lc "ansible-playbook -i inv site.yml"' }, @{ cmd = 'wsl -e bash -lc "ansible-playbook site.yml"' },
        @{ cmd = "wsl -- bash -lc 'cd /mnt/c/infra && ansible-playbook site.yml'" }, @{ cmd = 'bash -lc "kubectl --context home apply -f x.yaml"' },
        @{ cmd = 'cmd /c "kubectl --context home apply -f x.yaml"' }, @{ cmd = 'pwsh -C "kubectl --context home apply -f x.yaml"' },
        @{ cmd = 'Invoke-Expression "kubectl --context home apply -f x.yaml"' }, @{ cmd = 'ssh node-01 "sudo k3s kubectl apply -f x.yaml"' },
        @{ cmd = "ssh node-01 'kubectl --context home -n app scale deploy/web --replicas=0'" },
        @{ cmd = 'KUBECONFIG=clusters/home.yaml kubectl --context home apply -f x.yaml' }, @{ cmd = 'TF_LOG=debug tofu apply dns.tfplan' },
        @{ cmd = 'wsl bash -c "ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook site.yml"' }, @{ cmd = 'timeout 300 kubectl --context home apply -f x.yaml' },
        @{ cmd = 'nohup kubectl --context home apply -f x.yaml &' }, @{ cmd = 'cat pods.txt | xargs kubectl --context home delete pod' },
        @{ cmd = 'wsl.exe -d Ubuntu -- ansible-playbook site.yml' }, @{ cmd = 'kubectl --context="home" apply -f x.yaml' },
        @{ cmd = 'helm --kube-context="home" upgrade web charts/app' }, @{ cmd = 'tofu -chdir="tofu/dns" apply dns.tfplan' },
        @{ cmd = "terraform -chdir='tofu/dns' import cloudflare_record.www x" }, @{ cmd = 'kubectl --request-timeout 30s --context home apply -f x.yaml' },
        @{ cmd = 'kubectl --context home "apply" -f x.yaml' }, @{ cmd = 'kube""ctl --context home apply -f x.yaml' }, @{ cmd = 'tofu apply "dns.tfplan"' },
        @{ cmd = 'wsl ansible-console all' }, @{ cmd = "echo 'kubectl --context home apply -f x.yaml' | bash" },
        @{ cmd = "kubectl --context home \`n  apply -f x.yaml" }, @{ cmd = "kubectl --context home -n app \`r`n  delete pod web-1" },
        @{ cmd = 'kubectl --context home rollout -n app restart deploy/web' }, @{ cmd = 'kubectl --context home rollout --namespace app restart deploy/web' },
        @{ cmd = 'wsl bash -lc "ansible-playbook -i inv site.yml && ansible-playbook -i inv smoke.yml --check"' },
        @{ cmd = 'echo $(kubectl --context home delete ns app)' }, @{ cmd = '(cd tofu/dns && tofu apply dns.tfplan)' },
        @{ cmd = 'kubectl --context home rollout --timeout 60s restart deploy/web' }, @{ cmd = 'kubectl --context home -n $(cat ns.txt) delete pod web-1' },
        @{ cmd = 'kubectl --context home --kubeconfig $(pwd)/kc.yaml apply -f x.yaml' }, @{ cmd = 'echo "applied: $(kubectl --context home apply -f x.yaml)"' },
        @{ cmd = 'echo "x `kubectl --context home apply -f x.yaml`"' }, @{ cmd = 'for f in *.yaml; do kubectl --context home apply -f $f; done' },
        @{ cmd = 'kubectl --context home $VERB -f x.yaml' }, @{ cmd = 'kubectl --context home plugin-thing' },
        @{ cmd = "python -c `"import os; os.system('kubectl --context home apply -f x.yaml')`"" },
        @{ cmd = 'tofu -chdir=tofu/dns init -migrate-state' }, @{ cmd = 'wsl ansible-playbook site.yml -- --check' },
        @{ cmd = 'kubectl --context home run x --image=busybox -- --dry-run=server' }, @{ cmd = 'kubectl --context home --profile get apply -f x.yaml' },
        @{ cmd = "cat <<EOF | bash`nkubectl --context home apply -f x.yaml`nEOF" }, @{ cmd = "echo 'kubectl --context home apply -f x.yaml' > run.sh" },
        @{ cmd = 'C:\tools\kubectl.exe --context home apply -f x.yaml' },
        @{ cmd = 'echo "${#PODS[@]} pods"; kubectl --context home delete pod web-1' }, @{ cmd = "echo $'it\'s'; kubectl --context home apply -f x.yaml" },
        @{ cmd = "git submodule foreach 'kubectl --context home apply -f x.yaml'" }, @{ cmd = 'kubectl --context home --alsologtostderr apply -f x.yaml' },
        @{ cmd = "rg -n '<<EOF' scripts/`nkubectl --context home apply -f x.yaml" }, @{ cmd = "grep -n '<<' deploy.sh`nkubectl --context home apply -f x.yaml" },
        @{ cmd = "git rebase --exec='kubectl --context home apply -f x.yaml' HEAD~1" }, @{ cmd = 'echo ${x:-{}; kubectl --context home apply -f x.yaml' },
        @{ cmd = "python3 -c `"import os; os.system('microk8s.kubectl apply -f x.yaml')`"" },
        @{ cmd = "find . -name x.yaml -exec sh -c 'kubectl --context home apply -f `"`$1`"' _ {} \;" },
        @{ cmd = "git -c credential.helper='!kubectl --context home apply -f x.yaml' fetch" },
        @{ cmd = "git config alias.up '!kubectl --context home apply -f x.yaml'" },
        @{ cmd = "git submodule foreach sh -c 'kubectl --context home apply -f x.yaml'" }, @{ cmd = "git bisect run sh -c 'kubectl --context home apply -f x.yaml'" },
        @{ cmd = "git -c diff.external='kubectl --context home apply -f x.yaml' diff" },
        @{ cmd = "git ls-remote --upload-pack='kubectl --context home apply -f x.yaml' origin" },
        @{ cmd = "git submodule --quiet foreach 'kubectl --context home apply -f x.yaml'" },
        @{ cmd = 'git submodule foreach --recursive kubectl --context home apply -f x.yaml' },
        @{ cmd = "git clone -u 'kubectl --context home apply -f x.yaml' origin x" },
        @{ cmd = "git clone -c core.sshCommand='kubectl --context home apply -f x.yaml' ssh://h/r" },
        @{ cmd = "git ls-remote --upl='kubectl --context home apply -f x.yaml' origin" },
        @{ cmd = "GIT_EXTERNAL_DIFF='kubectl --context home apply -f x.yaml' git diff" },
        @{ cmd = "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0='kubectl --context home apply -f x.yaml' git log" },
        @{ cmd = "GIT_ALLOW_PROTOCOL=ext git ls-remote 'ext::sh -c kubectl% --context% home% apply% -f% x.yaml'" },
        @{ cmd = "git config protocol.ext.allow always && git ls-remote 'ext::sh -c kubectl% --context% home% apply% -f% x.yaml'" },
        @{ cmd = "git -c core.askPass='kubectl --context home apply -f x.yaml' fetch" },
        @{ cmd = "GH_PAGER='kubectl --context home apply -f x.yaml' gh pr list" }, @{ cmd = "GH_EDITOR='kubectl --context home apply -f x.yaml' gh repo view" },
        @{ cmd = "GH_BROWSER='kubectl --context home apply -f x.yaml' gh repo view" }, @{ cmd = "MANPAGER='kubectl --context home apply -f x.yaml' git help log" },
        @{ cmd = "BROWSER='kubectl --context home apply -f x.yaml' gh repo view --web" }, @{ cmd = "LESSCLOSE='kubectl --context home apply -f x.yaml' less x.txt" }
    ) {
        $r = Invoke-Hook -Data (Bash $cmd)
        $r.Decision | Should -Be 'deny'
        Get-Code $r.Reason | Should -Not -BeNullOrEmpty
    }
    It 'demande un accord pour l''action PowerShell <cmd>' -ForEach @(
        @{ cmd = '& "C:\tools\tofu.exe" -chdir=tofu/dns apply dns.tfplan' }, @{ cmd = 'Invoke-Expression "kubectl --context home apply -f x.yaml"' },
        @{ cmd = "kubectl --context home -n app ```n  scale deploy/web --replicas=0" }, @{ cmd = "kubectl --context home ```r`n  apply -f x.yaml" },
        @{ cmd = "tofu -chdir=tofu/dns ```n  apply dns.tfplan" }, @{ cmd = "helm upgrade --install web charts/app ```n  --kube-context home -n app -f values.yaml" },
        @{ cmd = "Start-Process kubectl -ArgumentList '--context','home','apply','-f','x.yaml' -Wait" },
        @{ cmd = 'Write-Output (kubectl --context home apply -f x.yaml)' }, @{ cmd = "Set-Location C:\infra\tofu\dns\`ntofu apply dns.tfplan" },
        @{ cmd = "cd .\tofu\dns\`ntofu apply dns.tfplan" }, @{ cmd = "Copy-Item x.yaml manifests\`nkubectl --context home apply -f manifests/x.yaml" },
        @{ cmd = 'kubectl --context home -n (Get-Content ns.txt) delete pod web-1' }, @{ cmd = 'Write-Output "result: $(kubectl --context home apply -f x.yaml)"' },
        @{ cmd = 'Get-ChildItem *.yaml | ForEach-Object { kubectl --context home apply -f $_.FullName }' },
        @{ cmd = '$k = ''kubectl''; & $k --context home apply -f x.yaml' },
        @{ cmd = "`$m = @'`nit's`n'@`nkubectl --context home apply -f x.yaml" },
        @{ cmd = '$r=kubectl --context home apply -f x.yaml' }, @{ cmd = "[Diagnostics.Process]::Start('kubectl', '--context home apply -f x.yaml')" },
        @{ cmd = "New-Item run.ps1 -Value 'kubectl --context home apply -f x.yaml'" },
        @{ cmd = '[string]$out = kubectl --context home apply -f x.yaml' }, @{ cmd = '[string[]]$lines = helm --kube-context home upgrade web charts/app' },
        @{ cmd = '$a[0]=kubectl --context home apply -f x.yaml' }, @{ cmd = '$h[''web'']=kubectl --context home apply -f x.yaml' },
        @{ cmd = '$x ??= kubectl --context home apply -f x.yaml' }, @{ cmd = '${out} = kubectl --context home apply -f x.yaml' },
        @{ cmd = "Start-Process microk8s.kubectl -ArgumentList 'apply','-f','x.yaml'" },
        @{ cmd = '[string] $out = kubectl --context home apply -f x.yaml' }, @{ cmd = '$a,$b = helm --kube-context home upgrade web charts/app' },
        @{ cmd = '$a, $b = kubectl --context home apply -f x.yaml' }, @{ cmd = '[Dictionary[string, int]] $d = kubectl --context home apply -f x.yaml' },
        @{ cmd = '$h[''a='']=kubectl --context home apply -f x.yaml' },
        @{ cmd = '$p = [Diagnostics.Process]::new(); $p.StartInfo.FileName = ''kubectl''; $p.StartInfo.Arguments = ''--context home apply -f x.yaml''; $p.Start()' },
        @{ cmd = '$env:GIT_EXTERNAL_DIFF = ''kubectl --context home apply -f x.yaml''; git diff' },
        @{ cmd = '$h = @{ out = kubectl --context home apply -f x.yaml }' }, @{ cmd = '$h = @{ ''out'' = kubectl --context home apply -f x.yaml }' },
        @{ cmd = '$env:GIT_ALLOW_PROTOCOL = ''ext''; git ls-remote ''ext::sh -c kubectl% --context% home% apply% -f% x.yaml''' },
        @{ cmd = '$v = ''kubectl --context home apply -f x.yaml''; Set-Item env:GIT_PAGER $v; git log' },
        @{ cmd = '[Environment]::SetEnvironmentVariable(''GIT_PAGER'', ''kubectl --context home apply -f x.yaml''); git log' }
    ) {
        $r = Invoke-Hook -Data (PowerShell $cmd)
        $r.Decision | Should -Be 'deny'
        Get-Code $r.Reason | Should -Not -BeNullOrEmpty
    }
    It 'laisse passer la lecture <cmd>' -ForEach @(
        @{ cmd = 'kubectl --context home get pods -n app' }, @{ cmd = 'kubectl get nodes' }, @{ cmd = 'kubectl --context home diff -f x.yaml' },
        @{ cmd = 'kubectl --context home logs deploy/web' }, @{ cmd = 'tofu -chdir=tofu/dns plan -out=dns.tfplan' }, @{ cmd = 'tofu show dns.tfplan' },
        @{ cmd = 'wsl ansible-playbook -i ansible/inventory.yml ansible/site.yml --check --diff' }, @{ cmd = 'wsl ansible --version' },
        @{ cmd = 'wsl ansible-lint ansible/' }, @{ cmd = 'helm --kube-context home template web charts/app' }, @{ cmd = 'argocd app diff web' },
        @{ cmd = 'echo "feat(tofu): apply the dns plan"' }, @{ cmd = 'kubectl --context home get pods -l run=web' },
        @{ cmd = 'kubectl --context home logs deploy/web -c debug' }, @{ cmd = 'kubectl --context home describe pod debug-7f9c' },
        @{ cmd = 'kubectl --context home get pod run-migrations-x1' }, @{ cmd = 'kubectl get pods -n debug' }, @{ cmd = 'cd ansible && ls' },
        @{ cmd = 'git diff -- ansible tofu' }, @{ cmd = 'tree ansible -L 2' }, @{ cmd = 'grep -rn become ansible roles' }, @{ cmd = 'echo "ansible ok"' },
        @{ cmd = 'rg "kubectl apply" docs' }, @{ cmd = 'git grep -n "helm upgrade"' }, @{ cmd = 'Select-String -Path docs/*.md -Pattern "kubectl apply"' },
        @{ cmd = 'helm plugin install https://example.invalid/plugin' }, @{ cmd = 'git log --oneline --grep "tofu apply"' },
        @{ cmd = 'rg -n UserPromptSubmit .harness' }, @{ cmd = 'cat .harness/modules/infra/rules/UserPromptSubmit/infra-approval.ps1' },
        @{ cmd = 'Get-ChildItem .claude -r' }, @{ cmd = 'kubectl --context home get pods -o yaml' },
        @{ cmd = 'wsl bash -lc "cd /mnt/c/infra/ansible && ansible-playbook -i inventory.yml site.yml --check --diff"' },
        @{ cmd = 'wsl bash -lc "cd /mnt/c/infra/ansible && ls"' }, @{ cmd = 'wsl bash -lc "cd ~/infra/ansible && ansible-inventory --graph"' },
        @{ cmd = 'ssh node-01 "kubectl --context home logs deploy/web -c debug"' }, @{ cmd = 'ssh node-01 "kubectl --context home get pods -n debug"' },
        @{ cmd = 'mkdir -p ansible roles' }, @{ cmd = 'New-Item -ItemType Directory ansible -Force' }, @{ cmd = 'Copy-Item roles/web ansible -Recurse' },
        @{ cmd = 'pip install ansible kubernetes' }, @{ cmd = 'sudo apt install ansible -y' }, @{ cmd = 'wsl ansible-playbook --syntax-check ansible/site.yml' },
        @{ cmd = "Get-Content -Raw 'entree.json' | pwsh -NoProfile -File .harness/hooks/dispatch.ps1 PreToolUse" },
        @{ cmd = 'kubectl --context home apply --dry-run=server -f x.yaml' }, @{ cmd = 'cd C:/repo/claude-harness-infra && git status' },
        @{ cmd = "echo `"`$(cat <<'EOF'`nfeat(infra): kubectl apply du chart`n`nhelm upgrade ensuite`nEOF`n)`"" },
        @{ cmd = 'kubectl --context home get pods 2>&1 | head -20' }, @{ cmd = 'rg -n kubectl docs 2>/dev/null | head' },
        @{ cmd = 'pods=$(kubectl --context home get pods -o name)' }, @{ cmd = 'kubectl --context home get pods | grep web' },
        @{ cmd = 'cat x.yaml | kubectl --context home diff -f -' }, @{ cmd = 'tofu -chdir=tofu/dns validate && tofu -chdir=tofu/dns fmt -check' },
        @{ cmd = 'tofu -chdir=tofu/dns state list' }, @{ cmd = 'helm --kube-context home upgrade web charts/app --dry-run=server' },
        @{ cmd = 'helm --kube-context home history web' }, @{ cmd = 'kubectl --context home rollout status deploy/web' },
        @{ cmd = 'kubectl --context home apply --help' }, @{ cmd = 'kubectl --context home auth can-i create pods' },
        @{ cmd = 'kubectl config get-contexts' }, @{ cmd = 'argocd app get web' }, @{ cmd = 'tofu version' }, @{ cmd = 'yamllint ansible/' },
        @{ cmd = "echo 'kubectl --context home apply -f x.yaml' >> docs/runbook.md" },
        @{ cmd = 'helm --kube-context home upgrade web charts/app --set tag=$(git rev-parse HEAD) --dry-run' },
        @{ cmd = "find tofu -name '*.tf'" }, @{ cmd = 'yamllint ansible' }, @{ cmd = 'du -sh tofu/dns/.terraform' },
        @{ cmd = "watch -n 5 'kubectl --context home get pods'" }, @{ cmd = 'echo "${#PODS[@]} pods"' },
        @{ cmd = "find tofu -name '*.tf' -exec grep -l helm {} +" }, @{ cmd = 'kubectl' }, @{ cmd = 'helm' },
        @{ cmd = 'git -C tofu log --oneline' }, @{ cmd = 'git config user.name "helm bot"' },
        @{ cmd = "git submodule foreach 'git grep -n kubectl || true'" },
        @{ cmd = 'git grep -c kubectl' }, @{ cmd = 'git ls-files config tofu' }, @{ cmd = 'git log -c --stat -- helm' },
        @{ cmd = 'git -C tofu grep -n "tofu apply"' }, @{ cmd = 'GIT_PAGER=cat git log --oneline' },
        @{ cmd = "git -c http.extraHeader='X: kubectl' fetch" }, @{ cmd = "find docs -exec grep -lE 'kubectl|helm' {} +" },
        @{ cmd = 'GIT_PAGER=cat git log -S helm --oneline' }, @{ cmd = 'echo "$EDITOR"; kubectl --context home get pods' },
        @{ cmd = 'export EDITOR=vim; kubectl --context home get pods' }, @{ cmd = "rg -n 'GIT_SSH_COMMAND' -- ansible" }
    ) { (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'allow' }
    It 'laisse passer la lecture PowerShell <cmd>' -ForEach @(
        @{ cmd = "Get-Content -Raw 'entree.json' | pwsh -NoProfile -File .harness/hooks/dispatch.ps1 PreToolUse" },
        @{ cmd = 'Get-Content -Raw "entree.json" | pwsh -NoProfile -NonInteractive -File "$env:CLAUDE_PROJECT_DIR/.harness/hooks/dispatch.ps1" PreToolUse' },
        @{ cmd = "(Get-Content docs/runbook.md) -match 'kubectl apply'" }, @{ cmd = "Select-String -Path (Get-ChildItem docs -Filter *.md) -Pattern 'helm upgrade'" },
        @{ cmd = 'Write-Host ("Étape suivante : kubectl --context home apply -f x.yaml")' }, @{ cmd = 'rg -n kubectl docs | Select-Object -First 5' },
        @{ cmd = 'kubectl --context home get pods -o json | ConvertFrom-Json' }, @{ cmd = '$pods = kubectl --context home get pods -o name' },
        @{ cmd = 'if (Test-Path tofu/dns) { tofu -chdir=tofu/dns plan -out=dns.tfplan }' },
        @{ cmd = "Get-ChildItem clusters -Recurse -Filter *.yaml | Where-Object { `$_.Name -match 'helm' }" },
        @{ cmd = '$msg=''kubectl apply a échoué''' }, @{ cmd = '$msg="échec de helm upgrade"; Write-Warning $msg' },
        @{ cmd = '[regex]::Matches((Get-Content runbook.md -Raw), ''kubectl apply'').Count' }, @{ cmd = '[IO.Path]::Combine($PWD, ''tofu'', ''dns'')' },
        @{ cmd = '$sw = [Diagnostics.Stopwatch]::StartNew(); kubectl --context home get pods; $sw.Stop()' },
        @{ cmd = '$f = [IO.File]::CreateText(''notes-helm.txt''); $f.Close()' }, @{ cmd = '$a = [ordered] @{ a = ''kubectl apply'' }' },
        @{ cmd = '$env:EDITOR = ''code --wait''; kubectl --context home get pods' }
    ) { (Invoke-Hook -Data (PowerShell $cmd)).Decision | Should -Be 'allow' }
    It 'exige le cluster nommé pour <cmd>' -ForEach @(
        @{ cmd = 'kubectl apply -f x.yaml' }, @{ cmd = 'kubectl -n app scale deploy/web --replicas=2' }, @{ cmd = 'helm upgrade web charts/app' },
        @{ cmd = 'kubectl apply -f x.yaml # --context home' }, @{ cmd = 'kubectl --context $(kubectl config current-context) apply -f x.yaml' },
        @{ cmd = 'kubectl --context $CTX apply -f x.yaml' }
    ) {
        $r = Invoke-Hook -Data (Bash $cmd)
        $r.Decision | Should -Be 'deny'
        $r.Reason | Should -Match '--context'
    }
    It 'exige un plan enregistré pour <cmd>' -ForEach @(
        @{ cmd = 'tofu apply' }, @{ cmd = 'tofu -chdir=tofu/dns apply -auto-approve' }, @{ cmd = 'terraform apply -var-file=x' }, @{ cmd = 'tofu destroy' },
        @{ cmd = 'tofu apply -auto-approve -var x=a.tfplan' }
    ) {
        $r = Invoke-Hook -Data (Bash $cmd) -Env @{ HARNESS_DISABLED_HOOKS = 'destructive-guard,secret-guard' }
        $r.Decision | Should -Be 'deny'
        $r.Reason | Should -Match 'tfplan'
    }
    It 'laisse passer la commande une fois, après l''accord de l''utilisateur' {
        $cmd = 'kubectl --context home apply -f clusters/home/platform/x.yaml'
        $code = Get-Code (Invoke-Hook -Data (Bash $cmd)).Reason
        (Invoke-Hook -Data (Bash $cmd)).Reason | Should -Match "ok infra $code"
        (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'deny'
        $r = Invoke-Hook -EventName 'UserPromptSubmit' -Data @{ prompt = "ok infra $code" }
        $r.Reason | Should -Match 'accord de l''utilisateur enregistré'
        (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'allow'
        $again = Invoke-Hook -Data (Bash $cmd)
        $again.Decision | Should -Be 'deny'
        Get-Code $again.Reason | Should -Not -BeNullOrEmpty
    }
    It 'un accord ne vaut que pour la commande de son code' {
        $code = Get-Code (Invoke-Hook -Data (Bash 'kubectl --context home apply -f a.yaml')).Reason
        Invoke-Hook -EventName 'UserPromptSubmit' -Data @{ prompt = "ok infra $code" } | Out-Null
        (Invoke-Hook -Data (Bash 'kubectl --context home apply -f b.yaml')).Decision | Should -Be 'deny'
        (Invoke-Hook -Data (Bash 'kubectl --context home apply -f a.yaml')).Decision | Should -Be 'allow'
    }
    It 'un code inconnu n''autorise rien' {
        $cmd = 'argocd app sync web'
        $code = Get-Code (Invoke-Hook -Data (Bash $cmd)).Reason
        $other = '{0:D4}' -f ((([int] $code) + 1) % 10000)
        (Invoke-Hook -EventName 'UserPromptSubmit' -Data @{ prompt = "ok infra $other" }).Reason | Should -Match 'code inconnu'
        (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'deny'
    }
    It 'n''enregistre rien pour un message qui contient autre chose que le code : <prompt>' -ForEach @(
        @{ prompt = 'non, pas ok infra {0} : le plan coupe le site' }, @{ prompt = "ok infra {0}`net maintenant fais le reste" }, @{ prompt = 'ok infra {0} merci' }
    ) {
        $cmd = 'argocd app sync web'
        $code = Get-Code (Invoke-Hook -Data (Bash $cmd)).Reason
        (Invoke-Hook -EventName 'UserPromptSubmit' -Data @{ prompt = ($prompt -f $code) }).Reason | Should -Match 'aucun accord'
        (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'deny'
    }
    It 'refuse ce qui donnerait un accord sans l''utilisateur : <cmd>' -ForEach @(
        @{ cmd = 'claude -p "ok infra 1234" --resume x' }, @{ cmd = '$c = ''12'' + ''34''; claude -p "ok infra $c" --resume abc' },
        @{ cmd = 'claude -p --resume abc < prompt.txt' }, @{ cmd = 'claude -c -p go' }, @{ cmd = 'bash -c "claude -p --resume abc < prompt.txt"' },
        @{ cmd = 'claude -p --resume=abc < prompt.txt' }, @{ cmd = 'npx @anthropic-ai/claude-code -p --resume abc < prompt.txt' },
        @{ cmd = 'pwsh -NoProfile -File .harness/hooks/dispatch.ps1 (''UserPrompt'' + ''Submit'')' },
        @{ cmd = 'Get-Content $env:TEMP/claude-harness/s.infra.json' }, @{ cmd = 'Get-ChildItem $env:TEMP/claude-harness' },
        @{ cmd = '@{ session_id = ''s''; prompt = ''x'' } | ConvertTo-Json | pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit' },
        @{ cmd = '. .harness/modules/infra/rules/UserPromptSubmit/infra-approval.ps1' },
        @{ cmd = '[string] $o = Get-Content x.json | pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit' },
        @{ cmd = 'git -c core.pager=''pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit'' log' },
        @{ cmd = 'git clone -u ''pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit'' . x' },
        @{ cmd = '$env:GIT_EXTERNAL_DIFF = ''pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit''; git diff' },
        @{ cmd = '$env:GIT_CONFIG_COUNT = 1; $env:GIT_CONFIG_KEY_0 = ''core.pager''; $env:GIT_CONFIG_VALUE_0 = ''pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit''; git log' },
        @{ cmd = 'git submodule --quiet foreach ''pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit''' },
        @{ cmd = '$i = [Diagnostics.ProcessStartInfo]::new(''pwsh'', ''-NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit''); [Diagnostics.Process]::Start($i)' },
        @{ cmd = 'git config alias.x ''!pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit''' },
        @{ cmd = '$env:GIT_ALLOW_PROTOCOL = ''ext''; git ls-remote ''ext::sh -c pwsh% -NoProfile% -File% .harness/hooks/dispatch.ps1% UserPromptSubmit''' },
        @{ cmd = 'Add-Content .git/config "[alias]`n  f = !pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit"' },
        @{ cmd = 'printf ''#!/bin/sh\npwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit\n'' > .git/hooks/post-checkout' },
        @{ cmd = 'printf ''[alias]\n  f = !pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit\n'' >> .git/config' }
    ) { (Invoke-Hook -Data (PowerShell $cmd)).Decision | Should -Be 'deny' }
    It 'refuse l''écriture de l''état des accords : <path>' -ForEach @(
        @{ path = 'C:/Users/x/AppData/Local/Temp/claude-harness/s.infra.json'; content = '{}' },
        @{ path = 'C:/Users/x/AppData/Local/Temp/CLAUDE~1/s.infra.json'; content = '{}' },
        @{ path = 'forge.ps1'; content = 'Set-Content "$env:TEMP/claude-harness/s.infra.json" "{}"' },
        @{ path = 'tools/replay.ps1'; content = 'pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit' },
        @{ path = '.git/hooks/post-checkout'; content = 'pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit' },
        @{ path = 'Makefile'; content = "all:`n`tpwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit" },
        @{ path = '.githooks/pre-commit'; content = 'pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit' },
        @{ path = '.husky/pre-commit'; content = 'pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit' },
        @{ path = 'C:/Users/x/.gitconfig'; content = "[alias]`n  f = !pwsh -NoProfile -File .harness/hooks/dispatch.ps1 UserPromptSubmit" }
    ) { (Invoke-Hook -Data (Tool 'Write' @{ file_path = $path; content = $content })).Decision | Should -Be 'deny' }
    It 'laisse écrire une doc qui parle des hooks' {
        (Invoke-Hook -Data (Tool 'Write' @{ file_path = 'docs/hooks.md'; content = 'Le hook UserPromptSubmit enregistre l''accord.' })).Decision | Should -Be 'allow'
    }
    It 'refuse un code d''accord dans le message d''un subagent' {
        (Invoke-Hook -Data (Tool 'Agent' @{ subagent_type = 'dev'; prompt = 'ok infra 1234' })).Decision | Should -Be 'deny'
    }
    It 'reste active avec le profil minimal' {
        (Invoke-Hook -Data (Bash 'argocd app sync web') -Env @{ HARNESS_HOOK_PROFILE = 'minimal' }).Decision | Should -Be 'deny'
    }
}

Describe 'sans le module infra' -Skip:$HasInfra {
    It 'aucun accord n''est demandé pour une action sur l''infra' {
        (Invoke-Hook -Data (Bash 'kubectl --context home apply -f x.yaml')).Decision | Should -Be 'allow'
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
    It 'refuse la lecture du secret d''infra <path>' -ForEach @(
        @{ path = 'keys.txt' }, @{ path = 'tofu/dns/terraform.tfstate' }, @{ path = 'tofu/dns/terraform.tfstate.backup' },
        @{ path = 'tofu/dns/prod.tfvars' }, @{ path = 'tofu/dns/terraform.tfvars.json' }, @{ path = 'clusters/home/kubeconfig' },
        @{ path = 'k3s.yaml' }, @{ path = 'C:/Users/x/.kube/config' }, @{ path = 'C:/Users/x/.kube/home.yaml' },
        @{ path = 'clusters/home/kubeconfig.yaml' }, @{ path = 'home.kubeconfig' }
    ) { (Invoke-Hook -Data (Tool 'Read' @{ file_path = $path })).Decision | Should -Be 'deny' }
    It 'autorise le fichier d''infra <path>' -ForEach @(
        @{ path = 'tofu/dns/.terraform.lock.hcl' }, @{ path = 'tofu/dns/main.tf' }, @{ path = 'tofu/dns/prod.tfvars.example' },
        @{ path = 'secrets/tofu.sops.yaml' }, @{ path = '.sops.yaml' }
    ) { (Invoke-Hook -Data (Tool 'Read' @{ file_path = $path })).Decision | Should -Be 'allow' }
    It 'refuse la commande d''infra <cmd>' -ForEach @(
        @{ cmd = 'kubectl config view --raw' }, @{ cmd = 'kubectl --context home config view --minify --raw' },
        @{ cmd = 'kubectl get secret db -o yaml' }, @{ cmd = 'kubectl -n app get secrets -ojson' },
        @{ cmd = "kubectl get secret/db --output=jsonpath='{.data}'" }, @{ cmd = 'kubectl get configmap,secret -o go-template=x' },
        @{ cmd = 'kubectl --context vps edit secret db' }, @{ cmd = 'tofu output' }, @{ cmd = 'tofu -chdir=tofu/dns output -json' },
        @{ cmd = 'terraform output -raw token' }, @{ cmd = 'tofu show -json dns.tfplan' }, @{ cmd = 'tofu state pull' },
        @{ cmd = 'helm get values app' }, @{ cmd = 'helm get manifest app -n app' }, @{ cmd = 'helm --kube-context home get all app' },
        @{ cmd = 'cat ~/.kube/config' }, @{ cmd = 'Get-Content tofu/dns/terraform.tfstate' }, @{ cmd = 'bash -c "kubectl get secret db -o yaml"' },
        @{ cmd = 'kubectl get -n app secret db -o yaml' }, @{ cmd = 'kubectl get --namespace=app secret db -o json' },
        @{ cmd = 'kubectl get -A secrets -o yaml' }, @{ cmd = "kubectl --context home get -n app secret db -o jsonpath='{.data.password}'" },
        @{ cmd = 'kubectl edit -n app secret db' }, @{ cmd = "kubectl get secret db --template='{{.data.password}}'" },
        @{ cmd = 'kubectl get secret db -o template=x' }, @{ cmd = 'kubectl get secret db -o kyaml' },
        @{ cmd = 'kubectl get secret db -o custom-columns=P:.data.password' }, @{ cmd = 'kubectl config view --flatten' },
        @{ cmd = 'kubectl config view --minify --flatten' }, @{ cmd = 'tofu show --json' },
        @{ cmd = 'cat ~/.kube/home.yaml' }, @{ cmd = 'tar czf /tmp/k.tgz ~/.kube' }, @{ cmd = 'unzip -p dns.tfplan tfstate' },
        @{ cmd = 'tar -xOf dns.tfplan tfstate' }, @{ cmd = 'tofu plan -show-sensitive' },
        @{ cmd = 'tofu -chdir=tofu/dns state show -show-sensitive x' }, @{ cmd = 'tofu show --show-sensitive' },
        @{ cmd = 'tofu.exe output' }, @{ cmd = 'kubectl get --raw /api/v1/namespaces/app/secrets/db' },
        @{ cmd = 'ssh vps sudo cat /var/lib/rancher/k3s/server/token' }, @{ cmd = 'ssh vps sudo cat /var/lib/rancher/k3s/server/agent-token' },
        @{ cmd = 'kubectl get "secret/db" -o jsonpath="{.data.password}"' }, @{ cmd = "kubectl get 'secret/db' -o yaml" },
        @{ cmd = 'kubectl get "secret" db -o yaml' }, @{ cmd = 'kubectl edit -n app "secret/db"' },
        @{ cmd = 'kubectl get -f ./secrets/db.sops.yaml -o yaml' }, @{ cmd = 'kubectl get -f k8s/app/secret.yaml -o yaml' },
        @{ cmd = '& "C:\tools\tofu.exe" output -json' }
    ) { (Invoke-Hook -Data (Bash $cmd)).Decision | Should -Be 'deny' }
    It 'autorise la commande d''infra <cmd>' -ForEach @(
        @{ cmd = 'kubectl --context home get pods -o yaml' }, @{ cmd = 'kubectl get secrets' }, @{ cmd = 'kubectl describe secret db' },
        @{ cmd = 'kubectl config view' }, @{ cmd = 'tofu -chdir=tofu/dns plan -out=dns.tfplan' }, @{ cmd = 'tofu show dns.tfplan' },
        @{ cmd = 'tofu fmt -check -recursive' }, @{ cmd = 'helm get notes app' }, @{ cmd = 'echo "feat(tofu): add the dns output"' },
        @{ cmd = 'tofu apply dns.tfplan' }, @{ cmd = 'kubectl get -n app pods -o yaml' },
        @{ cmd = 'kubectl --context home get pods -n external-secrets -o yaml' }, @{ cmd = 'kubectl get deploy -n sealed-secrets -o yaml' },
        @{ cmd = 'kubectl get pods -o yaml -l app=secret-store' },
        @{ cmd = "kubectl get pod web -o jsonpath='{.spec.volumes[*].secret.secretName}'" }, @{ cmd = 'kubectl get --raw /healthz' },
        @{ cmd = 'kubectl get -f k8s/apps/secret-store/deploy.yaml -o yaml' }, @{ cmd = 'kubectl get secretstores -o yaml' },
        @{ cmd = 'kubectl get events --field-selector involvedObject.kind=Secret -o yaml' }
    ) { (Invoke-Hook -Data (Bash $cmd) -Env @{ HARNESS_DISABLED_HOOKS = 'infra-guard' }).Decision | Should -Be 'allow' }
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
    It 'doc-sprawl ignore à la racine les fichiers de project-ideas (<path>)' -Skip:(-not $IsRoot) -ForEach @(@{ path = 'project-ideas/IDEAS.md' }, @{ path = 'project-ideas/ideas/0007-carnet.md' }) {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Write' @{ file_path = (Join-Path $script:Root $path); content = 'x' })).Decision | Should -Be 'allow'
    }
    It 'doc-sprawl signale toujours un autre Markdown de project-ideas' -Skip:(-not $IsRoot) {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Write' @{ file_path = (Join-Path $script:Root 'project-ideas/notes.md'); content = 'x' })).Decision | Should -Be 'context'
    }
    It 'doc-sprawl ignore les notes d''un hôte avec le module infra' -Skip:(-not $HasInfra) {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Write' @{ file_path = (Join-Path $script:Root 'hosts/node-01/install-notes.md'); content = 'x' })).Decision | Should -Be 'allow'
    }
    It 'doc-sprawl signale un Markdown plus profond sous hosts/ (<path>)' -ForEach @(@{ path = 'hosts/node-01/sub/notes.md' }, @{ path = 'hosts/notes.md' }) {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Write' @{ file_path = (Join-Path $script:Root $path); content = 'x' })).Decision | Should -Be 'context'
    }
    It 'doc-sprawl signale les notes d''un hôte sans le module infra' -Skip:$HasInfra {
        (Invoke-Hook -EventName 'PostToolUse' -Data (Tool 'Write' @{ file_path = (Join-Path $script:Root 'hosts/node-01/install-notes.md'); content = 'x' })).Decision | Should -Be 'context'
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

Describe 'remise de l''environnement (Invoke-WithEnv)' {
    BeforeAll {
        # Trois témoins : absent, vide et défini.
        $script:Witness = @{ ZZ_HARNESS_ABSENT = $null; ZZ_HARNESS_EMPTY = ''; ZZ_HARNESS_SET = 'avant' }
        function Get-EnvState { foreach ($n in $script:Witness.Keys | Sort-Object) { "$n=$(Test-Path "env:$n")=$([Environment]::GetEnvironmentVariable($n))" } }
    }
    BeforeEach { foreach ($n in $script:Witness.Keys) { Set-EnvVar $n $script:Witness[$n] } }
    AfterAll { foreach ($n in $script:Witness.Keys) { Set-EnvVar $n $null } }

    It 'remet chaque témoin comme avant (valeur posée : <label>)' -ForEach @(
        @{ label = 'définie'; value = 'x' }, @{ label = '$null'; value = $null }, @{ label = 'vide'; value = '' }
    ) {
        $before = @(Get-EnvState)
        $vars = @{}; foreach ($n in $script:Witness.Keys) { $vars[$n] = $value }
        Invoke-WithEnv $vars { } | Out-Null
        @(Get-EnvState) | Should -Be $before
    }
    It 'pose les valeurs pendant le bloc, vues par un processus enfant' {
        Invoke-WithEnv @{ ZZ_HARNESS_SET = 'pendant'; ZZ_HARNESS_ABSENT = 'x' } { pwsh -NoProfile -Command '$env:ZZ_HARNESS_SET + "/" + $env:ZZ_HARNESS_ABSENT' } | Should -Be 'pendant/x'
    }
    It 'retire pendant le bloc une variable posée à $null' {
        Invoke-WithEnv @{ ZZ_HARNESS_SET = $null } { Test-Path env:ZZ_HARNESS_SET } | Should -BeFalse
    }
    It 'remet l''environnement même si le bloc échoue' {
        $before = @(Get-EnvState)
        { Invoke-WithEnv @{ ZZ_HARNESS_ABSENT = 'x'; ZZ_HARNESS_EMPTY = 'y'; ZZ_HARNESS_SET = $null } { throw 'échec' } } | Should -Throw
        @(Get-EnvState) | Should -Be $before
    }
    It 'git ne lit ni la config du poste ni celle du système' {
        $env:GIT_CONFIG_NOSYSTEM | Should -Be '1'
        git config --global --list 2>$null | Should -BeNullOrEmpty
        git var GIT_COMMITTER_IDENT | Should -Match '^harness-test <harness-test@example\.invalid>'
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
    Context 'fichiers SOPS' {
        BeforeAll {
            # Valeurs tronquées, de la forme que produit SOPS 3.x (indentation à 4 espaces). Le bloc sops:
            # suit celui de SOPS : un bloc plus sommaire déclenche la règle kubernetes-secret-yaml de gitleaks.
            $script:Enc = 'ENC[AES256_GCM,data:rF6t,iv:aXY=,tag:dGFn,type:str]'
            $script:Meta = "sops:`n    age:`n        - enc: |`n            -----BEGIN AGE ENCRYPTED FILE-----`n            YWdlLWVuY3J5cHRpb24ub3JnL3YxCg==`n            -----END AGE ENCRYPTED FILE-----`n          recipient: age1$('q' * 58)`n    lastmodified: `"2026-11-15T10:00:00Z`"`n    mac: $script:Enc`n    version: 3.13.3"
            function Test-Sops([string] $Name, [string] $Content) {
                $path = Join-Path $script:Repo $Name
                New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
                Set-Content $path $Content
                git -C $script:Repo add -f $Name
                Test-PreCommit
            }
        }
        It 'accepte un fichier chiffré en entier' {
            Test-Sops 'secrets/tofu.sops.yaml' "token: $Enc`ncloudflare:`n    zone_id: $Enc`nhosts:`n    - $Enc`n    - name: $Enc`n$Meta" | Should -Be 0
        }
        It 'accepte un Secret Kubernetes dont seuls data et stringData sont chiffrés' {
            Test-Sops 'secrets/k8s/db.sops.yaml' "apiVersion: v1`nkind: Secret`nmetadata:`n    name: db`ntype: Opaque`nstringData:`n    password: $Enc`ndata:`n    user: $Enc`n$Meta" | Should -Be 0
        }
        It 'refuse un fichier à plat chiffré par une règle data|stringData' {
            Test-Sops 'secrets/wrong.sops.yaml' "token: abc123`ncloudflare:`n    zone_id: z1`n$Meta" | Should -Not -Be 0
        }
        It 'refuse un Secret Kubernetes dont stringData est en clair' {
            Test-Sops 'secrets/k8s/db.sops.yaml' "apiVersion: v1`nkind: Secret`nmetadata:`n    name: db`nstringData:`n    password: hunter2`n$Meta" | Should -Not -Be 0
        }
        It 'refuse un fichier jamais chiffré' {
            Test-Sops 'secrets/app.sops.yaml' "token: $Enc" | Should -Not -Be 0
        }
        It 'refuse un texte en bloc laissé en clair' {
            Test-Sops 'secrets/note.sops.yaml' "token: $Enc`nnote: |`n    ligne en clair`n$Meta" | Should -Not -Be 0
        }
        It 'accepte le fichier de règles .sops.yaml' {
            Test-Sops '.sops.yaml' "creation_rules:`n    - path_regex: \.sops\.yaml`$`n      age: age1exemple" | Should -Be 0
        }
        It 'refuse une valeur en clair ajoutée après le bloc sops:' {
            Test-Sops 'secrets/app.sops.yaml' "token: $Enc`n$Meta`nnew_token: abc123" | Should -Not -Be 0
        }
        It 'accepte un fichier de plusieurs documents chiffrés' {
            Test-Sops 'secrets/k8s/multi.sops.yaml' "apiVersion: v1`nkind: Secret`nmetadata:`n    name: a`ndata:`n    p: $Enc`n$Meta`n---`napiVersion: v1`nkind: Secret`nmetadata:`n    name: b`ndata:`n    p: $Enc`n$Meta" | Should -Be 0
        }
        It 'refuse un second document laissé en clair' {
            Test-Sops 'secrets/k8s/multi.sops.yaml' "apiVersion: v1`nkind: Secret`nmetadata:`n    name: a`ndata:`n    p: $Enc`n$Meta`n---`napiVersion: v1`nkind: Secret`nmetadata:`n    name: b`nstringData:`n    password: hunter2" | Should -Not -Be 0
        }
        It 'accepte les valeurs vides que SOPS laisse en clair' {
            Test-Sops 'secrets/empty.sops.yaml' "token: $Enc`nnone: null`ntilde: ~`nblank: `"`"`nmap: {}`nlist: []`n$Meta" | Should -Be 0
        }
        It 'refuse un commentaire en clair dans un fichier chiffré en entier' {
            Test-Sops 'secrets/comment.sops.yaml' "#ENC[AES256_GCM,data:aGk=,iv:aXY=,tag:dGFn,type:comment]`n# ancien jeton : abc123`ntoken: $Enc`n$Meta" | Should -Not -Be 0
        }
        It 'refuse kind: Secret sans apiVersion v1 : le fichier reste à chiffrer en entier' {
            Test-Sops 'secrets/flat.sops.yaml' "kind: Secret`ndata:`n    p: $Enc`ntoken: abc123`n$Meta" | Should -Not -Be 0
        }
        It 'refuse un fichier en clair au nom non ASCII' {
            Test-Sops 'secrets/équipe.sops.yaml' "token: abc123" | Should -Not -Be 0
        }
        It 'refuse une ligne indentée ajoutée après le dernier bloc sops:' {
            Test-Sops 'secrets/tail.sops.yaml' "token: $Enc`n$Meta`n    note: hunter2" | Should -Not -Be 0
        }
        It 'refuse un plan OpenTofu indexé de force' {
            Set-Content (Join-Path $script:Repo 'dns.tfplan') 'PK'
            git -C $script:Repo add -f dns.tfplan
            Test-PreCommit | Should -Not -Be 0
        }
    }
}
}

Describe 'doctor -Fix' {
    BeforeAll {
        # Faux claude et codegraph en tête du PATH : -Fix n'installe rien pour de vrai et ne crée aucun index,
        # et chaque appel est noté. Un HOME vide donne un registre de plugins vide : les plugins du template manquent.
        $script:Fake = Join-Path ([IO.Path]::GetTempPath()) "harness-fake-$([guid]::NewGuid())"
        $script:Calls = Join-Path $script:Fake 'calls.log'
        New-Item -ItemType Directory -Force (Join-Path $script:Fake 'bin'), (Join-Path $script:Fake 'home') | Out-Null
        foreach ($tool in 'claude', 'codegraph') {
            Set-Content (Join-Path $script:Fake 'bin' "$tool.ps1") "Add-Content '$($script:Calls)' ('$tool ' + (`$args -join ' '))"
        }
        # Une copie du projet, avec un fichier du harness modifié et le bloc de .gitignore retiré.
        function New-ProjectCopy {
            $copy = Join-Path $script:Fake "project-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Force $copy | Out-Null
            foreach ($item in '.harness', '.claude', 'CLAUDE.md', '.copier-answers.harness.yml') {
                Copy-Item (Join-Path $script:Root $item) $copy -Recurse
            }
            Set-Content (Join-Path $copy '.gitignore') 'node_modules/'
            git -C $copy init -q -b main
            Add-Content (Join-Path $copy '.harness' 'hooks' 'rules' 'PreToolUse' 'secret-guard.ps1') '# modifié à la main'
            $copy
        }
        function Invoke-DoctorFix([string] $Project, [hashtable] $Env) {
            $fakeHome = Join-Path $script:Fake 'home'
            $vars = @{ PATH = (Join-Path $script:Fake 'bin') + [IO.Path]::PathSeparator + $env:PATH; HOME = $fakeHome; USERPROFILE = $fakeHome } + $Env
            Remove-Item $script:Calls -ErrorAction SilentlyContinue
            Invoke-WithEnv $vars { pwsh -NoProfile -NonInteractive -File (Join-Path $Project '.harness' 'tools' 'doctor.ps1') -Fix -Offline *>&1 | Out-String }
        }
        function Get-Calls { if (Test-Path $script:Calls) { Get-Content $script:Calls } else { @() } }

        $script:Copy = New-ProjectCopy
        $script:Manifest = Join-Path $script:Copy '.harness' 'manifest.json'
        $script:ManifestBefore = Get-FileHash $script:Manifest
        $script:EnvBefore = foreach ($k in 'HOME', 'USERPROFILE') { "$k=$(Test-Path "env:$k")=$([Environment]::GetEnvironmentVariable($k))" }
        $script:Output = Invoke-DoctorFix $script:Copy @{ HARNESS_SKIP_PLUGINS = '1' }
        $script:EnvAfter = foreach ($k in 'HOME', 'USERPROFILE') { "$k=$(Test-Path "env:$k")=$([Environment]::GetEnvironmentVariable($k))" }
        $script:SkipCalls = @(Get-Calls)
    }
    AfterAll { Remove-Item $script:Fake -Recurse -Force -ErrorAction SilentlyContinue }

    It 'remet HOME et USERPROFILE comme avant : une variable absente ne reste pas vide' {
        # Une variable vide n'est pas absente : avec HOME vide, git ne trouve plus ~/.gitconfig.
        $script:EnvAfter | Should -Be $script:EnvBefore
    }
    It 'répare le bloc de .gitignore' {
        Get-Content (Join-Path $script:Copy '.gitignore') -Raw | Should -Match '# >>> harness'
    }
    It 'ne réécrit pas le manifeste : un fichier du harness modifié reste visible' {
        (Get-FileHash $script:Manifest).Hash | Should -Be $script:ManifestBefore.Hash
        $script:Output | Should -Match 'fichiers du harness\s+FAIL'
    }
    It 'respecte HARNESS_SKIP_PLUGINS : aucun plugin installé' {
        $script:SkipCalls | Where-Object { $_ -match '^claude plugin install' } | Should -BeNullOrEmpty
    }
    It 'installe les plugins manquants sans HARNESS_SKIP_PLUGINS (le faux claude est bien appelé)' {
        Invoke-DoctorFix (New-ProjectCopy) @{ HARNESS_SKIP_PLUGINS = $null } | Out-Null
        Get-Calls | Where-Object { $_ -match '^claude plugin install \S+ --scope project' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'outils du harness : aide lisible par Get-Help' {
    # Un bloc <# #> collé à la ligne #Requires n'est pas reconnu comme une aide : Get-Help ne rend que la syntaxe.
    It '<name> a un .SYNOPSIS que Get-Help affiche' -ForEach $Tools {
        (Get-Help $path).Synopsis | Should -Not -BeNullOrEmpty
        (Get-Help $path).Synopsis | Should -Not -Match '\.ps1\b.*\['
    }
}

Describe 'modules installés' {
    It 'les conventions du module <name> sont importées par core.md' -AllowNullOrEmptyForEach -ForEach @(Get-ChildItem (Join-Path $PSScriptRoot '..' 'modules') -Directory -ErrorAction SilentlyContinue | ForEach-Object { @{ name = $_.Name } }) {
        Get-Content (Join-Path $PSScriptRoot '..' 'agents' 'core.md') -Raw | Should -Match ([regex]::Escape("@../modules/$name/conventions.md"))
    }
}

Describe 'lint infra (module infra)' -Skip:(-not $HasInfra) {
    BeforeAll {
        # Copie jetable du harness dans un dépôt vide, et de faux outils sur un PATH réduit : les
        # vrais outils ne tournent pas, et un outil absent du PATH l'est vraiment.
        $script:Repo = Join-Path ([IO.Path]::GetTempPath()) "harness-lint-$([guid]::NewGuid())"
        $script:Bin = Join-Path $Repo '_bin'
        New-Item -ItemType Directory -Force $Bin | Out-Null
        Copy-Item (Join-Path $script:Root '.harness') $Repo -Recurse
        git -C $Repo init -q
        Set-Content (Join-Path $Repo '.gitignore') '_bin/'
        $script:Lint = Join-Path $Repo '.harness' 'modules' 'infra' 'lint.ps1'
        $script:Log = Join-Path $Bin 'calls.log'
        # Un faux outil note ses arguments, puis rend la sortie et le code demandés par
        # FAKE_<OUTIL>_<1er argument>_OUT / _EXIT, ou à défaut FAKE_<OUTIL>_OUT / _EXIT.
        $fake = @'
$name = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
Add-Content $env:FAKE_LOG "$name $($args -join ' ')"
$key = "FAKE_$($name.ToUpper() -replace '-', '_')"
$sub = "$($key)_$("$($args[0])".TrimStart('-').ToUpper() -replace '-', '_')"
$out = [Environment]::GetEnvironmentVariable("$($sub)_OUT") ?? [Environment]::GetEnvironmentVariable("$($key)_OUT")
$code = [Environment]::GetEnvironmentVariable("$($sub)_EXIT") ?? [Environment]::GetEnvironmentVariable("$($key)_EXIT") ?? '0'
if ($out) { $out }
exit [int] $code
'@
        foreach ($t in 'tofu', 'tflint', 'kubeconform', 'yamllint', 'wsl') { Set-Content (Join-Path $Bin "$t.ps1") $fake }
        $script:GitDir = Split-Path (Get-Command git -CommandType Application | Select-Object -First 1).Source

        # Lance le lint avec, sur le PATH, les faux outils de -Tools seulement.
        function Invoke-Lint([string[]] $LintArgs, [string[]] $Tools = @(), [hashtable] $Env = @{}) {
            $dir = Join-Path $Bin ([guid]::NewGuid())
            New-Item -ItemType Directory -Force $dir | Out-Null
            foreach ($t in $Tools) { Copy-Item (Join-Path $Bin "$t.ps1") $dir }
            if (Test-Path $Log) { Remove-Item $Log }
            # Le faux wsl connaît les distributions Ubuntu et Debian (wsl -l -q).
            $Env = @{ Path = "$dir;$PSHOME;$GitDir"; FAKE_LOG = $Log; FAKE_WSL_L_OUT = "Ubuntu`nDebian" } + $Env
            Invoke-WithEnv $Env {
                $out = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $Lint @LintArgs 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out; Calls = @(if (Test-Path $Log) { Get-Content $Log }) }
            }
        }
        # Commit de préparation : un échec arrête le test au lieu de fausser ce qu'il vérifie.
        function Save-Repo([string] $Message) {
            $out = git -C $Repo add -A 2>&1
            if ($LASTEXITCODE -eq 0) { $out = git -C $Repo commit -q --no-verify --allow-empty -m $Message 2>&1 }
            if ($LASTEXITCODE -ne 0) { throw "commit de préparation refusé : $($out | Out-String)" }
        }
        function Set-File([string] $Rel, [string] $Text = 'x: 1') {
            $file = Join-Path $Repo $Rel
            New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
            Set-Content $file $Text
        }
        $script:Manifest = "apiVersion: v1`nkind: ConfigMap`nmetadata:`n  name: a"
    }
    AfterAll { if (Test-Path $Repo) { Remove-Item $Repo -Recurse -Force } }
    BeforeEach {
        # Chaque test part d'un dépôt sans fichier d'infra modifié.
        foreach ($d in 'tofu', 'clusters', 'ansible', 'charts', 'secrets', 'docs') { $p = Join-Path $Repo $d; if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
        Save-Repo reset
    }

    It 'stop-checks lance le lint d''infra déclaré par le module' {
        $checks = (Get-Content (Join-Path $Repo '.harness' 'modules' 'infra' 'module.json') -Raw | ConvertFrom-Json).stopChecks
        @($checks.name) | Should -Be @('tofu', 'kubeconform', 'yamllint', 'ansible-lint')
        foreach ($c in $checks) { $c.command | Should -Be "& ./.harness/modules/infra/lint.ps1 $($c.name)" }
    }
    It 'ne lance rien sans fichier concerné' {
        Set-File 'docs/notes.md' '# notes'
        $r = Invoke-Lint @('yamllint') -Tools 'yamllint'
        $r.Code | Should -Be 0
        $r.Calls | Should -BeNullOrEmpty
    }
    It 'un outil absent échoue et dit comment l''installer (<missing>)' -ForEach @(
        @{ tool = 'tofu'; file = 'tofu/dns/main.tf'; present = @('tflint'); missing = 'tofu' }
        @{ tool = 'tofu'; file = 'tofu/dns/main.tf'; present = @('tofu'); missing = 'tflint' }
        @{ tool = 'kubeconform'; file = 'clusters/home/cm.yaml'; present = @(); missing = 'kubeconform' }
        @{ tool = 'yamllint'; file = 'clusters/home/cm.yaml'; present = @(); missing = 'yamllint' }
        @{ tool = 'ansible-lint'; file = 'ansible/site.yml'; present = @(); missing = 'ansible-lint' }
    ) {
        Set-File $file $Manifest
        $r = Invoke-Lint @($tool) -Tools $present
        $r.Code | Should -Be 1
        $r.Output | Should -Match "$missing est introuvable, le lint n'a pas tourné"
        $r.Output | Should -Match 'setup-workstation\.ps1'
    }
    It 'ansible-lint absent de WSL est signalé, avec la distribution (HARNESS_WSL_DISTRO)' {
        Set-File 'ansible/site.yml'
        $r = Invoke-Lint @('ansible-lint') -Tools 'wsl' -Env @{ FAKE_WSL_D_EXIT = '1'; HARNESS_WSL_DISTRO = 'Debian' }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'ansible-lint est introuvable.*wsl -d Debian'
        $r.Calls | Should -Not -Match 'ansible-lint --nocolor'
    }
    It '-Missing liste les outils absents' {
        $r = Invoke-Lint @('-Missing') -Tools 'tofu', 'yamllint'
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'tflint'
        $r.Output | Should -Match 'kubeconform'
        $r.Output | Should -Match 'ansible-lint'
        $r.Output | Should -Not -Match '(?m)^tofu\s'
        $r.Output | Should -Not -Match '(?m)^yamllint\s'
    }
    It 'yamllint ne lit que le YAML modifié, hors secrets SOPS et templates de chart' {
        Set-File 'clusters/home/apps/blog/values.yaml'
        Set-File 'secrets/app.sops.yaml'
        Set-File 'charts/app/templates/deployment.yaml' '{{ .Values.x }}'
        Set-File 'charts/app/values.yaml'
        Set-File 'docs/notes.md' '# notes'
        $r = Invoke-Lint @('yamllint') -Tools 'yamllint'
        $r.Code | Should -Be 0
        $r.Calls.Count | Should -Be 1
        $r.Calls[0] | Should -Match 'clusters/home/apps/blog/values\.yaml'
        $r.Calls[0] | Should -Match 'charts/app/values\.yaml'
        $r.Calls[0] | Should -Not -Match 'sops|templates|notes'
        # Sans .yamllint dans le dépôt, une config compatible avec ansible-lint est passée.
        $r.Calls[0] | Should -Match '-d \{extends: default'
    }
    It 'yamllint garde la config du dépôt quand elle existe' {
        Set-File 'clusters/home/cm.yaml'
        Set-File '.yamllint' 'extends: relaxed'
        try {
            $r = Invoke-Lint @('yamllint') -Tools 'yamllint'
            $r.Calls[0] | Should -Not -Match ' -d '
        }
        finally { Remove-Item (Join-Path $Repo '.yamllint') }
    }
    It 'une erreur de yamllint fait échouer le lint et montre sa sortie' {
        Set-File 'clusters/home/cm.yaml'
        $r = Invoke-Lint @('yamllint') -Tools 'yamllint' -Env @{ FAKE_YAMLLINT_EXIT = '1'; FAKE_YAMLLINT_OUT = 'cm.yaml:1:1: [error] trailing spaces' }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'yamllint :'
        $r.Output | Should -Match 'trailing spaces'
    }
    It 'kubeconform ne lit que les manifestes (clé kind:) sous clusters/' {
        Set-File 'clusters/home/apps/blog/deployment.yaml' $Manifest
        Set-File 'clusters/home/apps/blog/values.yaml' 'replicaCount: 1'
        Set-File 'clusters/home/secret.sops.yaml' $Manifest
        Set-File 'ansible/site.yml' $Manifest
        $r = Invoke-Lint @('kubeconform') -Tools 'kubeconform'
        $r.Code | Should -Be 0
        $r.Calls.Count | Should -Be 1
        $r.Calls[0] | Should -Match '^kubeconform -strict '
        $r.Calls[0] | Should -Match 'deployment\.yaml$'
        $r.Calls[0] | Should -Not -Match 'values|sops|ansible'
    }
    It 'tofu lance fmt, validate et tflint dans chaque dossier touché, et rien ailleurs' {
        Set-File 'tofu/dns/main.tf' 'terraform {}'
        Set-File 'tofu/vpn/variables.tf' 'terraform {}'
        Set-File 'tofu/vpn/README.md' '# vpn'
        Set-File 'tofu/proxmox/notes.md' '# notes'
        $r = Invoke-Lint @('tofu') -Tools 'tofu', 'tflint'
        $r.Code | Should -Be 0
        @($r.Calls | Where-Object { $_ -match '^tofu fmt -check' }).Count | Should -Be 2
        @($r.Calls | Where-Object { $_ -match '^tofu validate' }).Count | Should -Be 2
        @($r.Calls | Where-Object { $_ -match '^tflint' }).Count | Should -Be 2
        $r.Calls | Should -Not -Match 'init'
    }
    It 'tofu validate sans init dit de lancer tofu init, sans le lancer' {
        Set-File 'tofu/dns/main.tf' 'terraform {}'
        $r = Invoke-Lint @('tofu') -Tools 'tofu', 'tflint' -Env @{ FAKE_TOFU_VALIDATE_EXIT = '1'; FAKE_TOFU_VALIDATE_OUT = 'Error: Missing required provider. Run "tofu init".' }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'lancer une fois `tofu init` dans tofu/dns'
        $r.Calls | Should -Not -Match '^tofu init'
    }
    It 'une erreur de tofu validate est signalée avec sa sortie' {
        Set-File 'tofu/dns/main.tf' 'terraform {}'
        $r = Invoke-Lint @('tofu') -Tools 'tofu', 'tflint' -Env @{ FAKE_TOFU_VALIDATE_EXIT = '1'; FAKE_TOFU_VALIDATE_OUT = 'Error: Reference to undeclared input variable' }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'tofu validate \(tofu/dns\) :'
        $r.Output | Should -Match 'undeclared input variable'
        $r.Output | Should -Not -Match 'tofu init'
    }
    It 'tofu fmt en échec est signalé avec le dossier' {
        Set-File 'tofu/dns/main.tf' 'terraform {}'
        $r = Invoke-Lint @('tofu') -Tools 'tofu', 'tflint' -Env @{ FAKE_TOFU_FMT_EXIT = '3'; FAKE_TOFU_FMT_OUT = 'main.tf' }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'tofu fmt \(tofu/dns'
    }
    It 'ansible-lint tourne dans WSL avec les chemins en arguments' {
        Set-File 'ansible/site.yml'
        Set-File 'ansible/group_vars/all.sops.yaml'
        Set-File 'clusters/home/cm.yaml'
        $r = Invoke-Lint @('ansible-lint') -Tools 'wsl' -Env @{ HARNESS_WSL_DISTRO = 'Debian' }
        $r.Code | Should -Be 0
        $run = @($r.Calls | Where-Object { $_ -match 'ansible-lint --nocolor' })
        $run.Count | Should -Be 1
        $run[0] | Should -Match '^wsl -d Debian --cd .+ --exec bash -lc ansible-lint --nocolor --offline -q "\$@" ansible-lint ansible/site\.yml$'
    }
    It 'un fichier supprimé n''est pas lu' {
        Set-File 'clusters/home/cm.yaml'
        Save-Repo cm
        Remove-Item (Join-Path $Repo 'clusters/home/cm.yaml')
        $r = Invoke-Lint @('yamllint') -Tools 'yamllint'
        $r.Code | Should -Be 0
        $r.Calls | Should -BeNullOrEmpty
    }
    It 'un fichier renommé est lu sous son nouveau nom' {
        # Un ancien nom court : lu comme une entrée de plus, il ferait échouer le lint.
        Set-File 'ab' 'a: 1'
        Save-Repo old
        New-Item -ItemType Directory -Force (Join-Path $Repo 'clusters/home') | Out-Null
        git -C $Repo mv ab clusters/home/new.yaml
        try {
            $r = Invoke-Lint @('yamllint') -Tools 'yamllint'
            $r.Code | Should -Be 0
            $r.Calls[0] | Should -Match 'clusters/home/new\.yaml$'
        }
        finally { Save-Repo rm }
    }
    It 'ne lit jamais les fichiers protégés du harness ni les fichiers de secrets, même sans yamllint' {
        # Le vrai fichier de réponses de Copier : sa liste non indentée est refusée par yamllint.
        $answers = Join-Path $script:Root '.copier-answers.harness.yml'
        if (Test-Path $answers) { Copy-Item $answers $Repo } else { Set-File '.copier-answers.harness.yml' "modules:`n- infra" }
        Add-Content (Join-Path $Repo '.copier-answers.harness.yml') '# mise à jour'
        Set-File '.github/workflows/ci.yml'
        Set-File '.sops.yaml' 'creation_rules: []'
        Set-File 'clusters/home/kubeconfig.yaml' $Manifest
        Set-File 'clusters/home/k3s.yaml' $Manifest
        Set-File 'secrets/app.sops.yaml'
        try {
            foreach ($tool in 'yamllint', 'kubeconform') {
                $r = Invoke-Lint @($tool) -Tools @()
                $r.Code | Should -Be 0 -Because "$tool n'a rien à lire : $($r.Output)"
            }
            (Invoke-Lint @('yamllint') -Tools 'yamllint').Calls | Should -BeNullOrEmpty
        }
        finally { foreach ($f in '.copier-answers.harness.yml', '.github', '.sops.yaml') { Remove-Item (Join-Path $Repo $f) -Recurse -Force } }
    }
    It 'yamllint et kubeconform écartent tout dossier templates/' {
        Set-File 'clusters/home/apps/blog/templates/deployment.yaml' $Manifest
        Set-File 'charts/app/templates/service.yaml' $Manifest
        Set-File 'clusters/home/apps/blog/values.yaml'
        $r = Invoke-Lint @('yamllint') -Tools 'yamllint'
        $r.Calls[0] | Should -Match 'values\.yaml'
        $r.Calls[0] | Should -Not -Match 'templates'
        (Invoke-Lint @('kubeconform') -Tools 'kubeconform').Calls | Should -BeNullOrEmpty
    }
    It 'la config yamllint par défaut laisse les fins de ligne à .gitattributes' {
        Set-File 'clusters/home/cm.yaml'
        (Invoke-Lint @('yamllint') -Tools 'yamllint').Calls[0] | Should -Match 'new-lines: disable'
    }
    It 'un .tf supprimé fait valider son dossier' {
        Set-File 'tofu/dns/main.tf' 'terraform {}'
        Set-File 'tofu/dns/variables.tf' 'variable "zone" {}'
        Save-Repo tf
        Remove-Item (Join-Path $Repo 'tofu/dns/variables.tf')
        $r = Invoke-Lint @('tofu') -Tools 'tofu', 'tflint'
        @($r.Calls | Where-Object { $_ -match '^tofu validate' }).Count | Should -Be 1
        @($r.Calls | Where-Object { $_ -match '^tflint' }).Count | Should -Be 1
        # Aucun fichier modifié encore présent : fmt n'a rien à lire.
        $r.Calls | Should -Not -Match '^tofu fmt'
    }
    It 'un dossier tofu renommé est contrôlé sous son nouveau nom' {
        Set-File 'tofu/old/main.tf' 'terraform {}'
        Save-Repo tf
        git -C $Repo mv tofu/old tofu/new
        $r = Invoke-Lint @('tofu') -Tools 'tofu', 'tflint'
        $r.Code | Should -Be 0
        @($r.Calls | Where-Object { $_ -match '^tofu validate' }).Count | Should -Be 1
    }
    It 'tofu fmt ne lit que les .tf modifiés, jamais un *.tfvars' {
        Set-File 'tofu/dns/main.tf' 'terraform {}'
        Set-File 'tofu/dns/other.tf' 'terraform {}'
        Save-Repo tf
        Add-Content (Join-Path $Repo 'tofu/dns/main.tf') '# x'
        Set-File 'tofu/dns/terraform.tfvars' 'zone = "x"'
        $fmt = @((Invoke-Lint @('tofu') -Tools 'tofu', 'tflint').Calls | Where-Object { $_ -match '^tofu fmt' })
        $fmt.Count | Should -Be 1
        $fmt[0] | Should -Match ' main\.tf$'
        $fmt[0] | Should -Not -Match 'other|tfvars'
    }
    It 'une sortie qui cite un *.tfvars est masquée (<check>)' -ForEach @(
        @{ check = 'tofu validate'; extra = @{ FAKE_TOFU_VALIDATE_EXIT = '1'; FAKE_TOFU_VALIDATE_OUT = "Error: Invalid expression`n  on terraform.tfvars line 2:`n   2: zone = `"{valeur}`" oops" } }
        @{ check = 'tflint'; extra = @{ FAKE_TFLINT_EXIT = '1'; FAKE_TFLINT_OUT = "Error: terraform.tfvars:2,9: zone = `"{valeur}`"" } }
        @{ check = 'tofu validate'; extra = @{ FAKE_TOFU_VALIDATE_EXIT = '1'; FAKE_TOFU_VALIDATE_OUT = "Run tofu init. secrets.auto.tfvars.json: `"{valeur}`"" } }
    ) {
        # Valeur assemblée à l'exécution : rien que gitleaks puisse prendre pour un secret.
        $valeur = 'VALEUR' + '-MASQUEE-' + (Get-Random -Maximum 1000)
        $sortie = @{}; foreach ($k in $extra.Keys) { $sortie[$k] = $extra[$k].Replace('{valeur}', $valeur) }
        Set-File 'tofu/dns/main.tf' 'terraform {}'
        $r = Invoke-Lint @('tofu') -Tools 'tofu', 'tflint' -Env $sortie
        $r.Code | Should -Be 1
        $r.Output | Should -Match "$check \(tofu/dns\) : erreur dans un fichier \*\.tfvars"
        $r.Output | Should -Not -Match ([regex]::Escape($valeur))
    }
    It 'ansible-lint : des collections absentes, il dit de lancer ansible-galaxy' {
        Set-File 'ansible/site.yml'
        # Le faux wsl échoue seulement à l'appel d'ansible-lint, pas à `command -v`.
        $fakeWsl = Join-Path $Bin 'wsl.ps1'
        $saved = Get-Content $fakeWsl -Raw
        try {
            $hook = 'if ("$args" -match ''ansible-lint --nocolor'') { "syntax-check[unknown-module]: couldn''t resolve module/action ''community.sops.load_vars''"; exit 2 }'
            Set-Content $fakeWsl ($saved -replace '(?m)^exit \[int\] \$code', "$hook`nexit [int] `$code")
            $r = Invoke-Lint @('ansible-lint') -Tools 'wsl'
            $r.Code | Should -Be 1
            $r.Output | Should -Match 'ansible-galaxy install -r ansible/requirements\.yml'
            $r.Output | Should -Match 'infra-guard'
        }
        finally { Set-Content $fakeWsl $saved -NoNewline }
    }
    It 'une distribution WSL absente est nommée comme telle' {
        Set-File 'ansible/site.yml'
        $r = Invoke-Lint @('ansible-lint') -Tools 'wsl' -Env @{ HARNESS_WSL_DISTRO = 'Fedora' }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'distribution WSL « Fedora » est absente'
        $r.Output | Should -Not -Match 'uv tool install ansible-lint'
        $r.Calls | Should -Not -Match 'ansible-lint --nocolor'
    }
}

AfterAll {
    Restore-Env $script:GitEnvBefore
    Remove-Item $script:GitConfig -ErrorAction SilentlyContinue
}

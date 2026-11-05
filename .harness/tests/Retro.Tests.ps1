#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }

# Autotests du script d'analyse de /retro (.claude/skills/retro/scripts/scan-transcripts.ps1) :
# des transcripts simulés, au format de Claude Code, et le rapport qu'il en tire.
# Lancés par `.harness/tools/doctor.ps1 -Deep`.

BeforeAll {
    # La sortie du script, en UTF-8, se décode avec l'encodage de la console : sans ceci, une console
    # Windows en page 850 abîme les accents, et les tests échouent hors de `doctor -Deep`.
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $script:Scan =Join-Path $PSScriptRoot '..' '..' '.claude' 'skills' 'retro' 'scripts' 'scan-transcripts.ps1'
    $script:Guard = 'PreToolUse:PowerShell hook error: harness/git-guard : la session principale ne peut pas lancer cette commande, réservée à : git-ops.'

    # Un projet simulé, avec un dépôt imbriqué et les motifs de secrets du harness.
    $script:Proj = Join-Path $TestDrive 'proj'
    New-Item -ItemType Directory -Force (Join-Path $Proj 'src'), (Join-Path $Proj 'nested' '.git'), (Join-Path $Proj '.harness') | Out-Null
    @{ secretTokens = @{ 'jeton GitHub' = '(gh[pousr]_[A-Za-z0-9]{36,})' } } | ConvertTo-Json | Set-Content (Join-Path $Proj '.harness' 'harness.json')

    $script:N = 0
    function New-Line([hashtable] $Fields) {
        $script:N++
        $base = @{ uuid = "u$script:N"; sessionId = 's1'; cwd = $Proj; timestamp = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o') }
        foreach ($k in $Fields.Keys) { $base[$k] = $Fields[$k] }
        $base | ConvertTo-Json -Depth 10 -Compress
    }
    function New-Run([string] $Id, [string] $Command, [string] $Result, [bool] $IsError = $true, [hashtable] $Extra = @{}) {
        New-Line (@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = $Id; name = 'PowerShell'; input = @{ command = $Command } }) } } + $Extra)
        New-Line (@{ type = 'user'; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = $Id; content = $Result; is_error = $IsError }) } } + $Extra)
    }
    function New-Said([string] $Text, [hashtable] $Extra = @{}) { New-Line (@{ type = 'user'; message = @{ role = 'user'; content = $Text } } + $Extra) }

    function Invoke-Scan([string[]] $Lines, [string] $Extra = '') {
        $dir = Join-Path $TestDrive "t$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory $dir | Out-Null
        ($Lines -join "`n") | Set-Content -Encoding utf8 (Join-Path $dir 'a.jsonl')
        if ($Extra) { $Extra | Set-Content -Encoding utf8 (Join-Path $dir 'b.jsonl') }
        (pwsh -NoProfile -NonInteractive -File $Scan -Path $dir -Root $Proj -Days 7 -NoPrs) -join "`n"
    }
}

Describe 'scan-transcripts (/retro)' {
    It 'relève un refus de hook au format réel, avec sa règle et sa commande' {
        $out = Invoke-Scan (New-Run 't1' 'git merge-base --is-ancestor v1 HEAD' $Guard)
        $out | Should -Match '\*\*1×\*\* \(1 session\(s\)\) git-guard : la session principale'
        $out | Should -Match '1× `git merge-base --is-ancestor v1 HEAD`'
    }

    It 'ne compte qu''une fois un message recopié par une session reprise' {
        $lines = New-Run 't2' 'git merge-base x' $Guard
        $out = Invoke-Scan $lines ($lines -join "`n")
        $out | Should -Match '\*\*1×\*\*'
        $out | Should -Not -Match '\*\*2×\*\*'
    }

    It 'repère la même commande en échec deux fois' {
        $lines = @(New-Run 't3' 'npm test' 'exit 1: 2 failing') + @(New-Run 't4' 'npm test' 'exit 1: 2 failing')
        Invoke-Scan $lines | Should -Match '\*\*2×\*\* `PowerShell : npm test`'
    }

    It 'ne signale pas une commande en échec une seule fois' {
        Invoke-Scan (New-Run 't5' 'npm test' 'exit 1') | Should -Match '## Échecs répétés \(2 fois ou plus\)\nAucun\.'
    }

    It 'repère une correction, apostrophe droite ou typographique' {
        $apos = [char] 0x2019
        $out = Invoke-Scan @((New-Said "je t${apos}ai déjà dit : exports/archive/"), (New-Said "non, pas dans archive/"))
        $out | Should -Match 'exports/archive/'
        $out | Should -Match 'non, pas dans archive/'
    }

    # Pas de chevrons dans le nom d'un test : Pester les prend pour un gabarit (<nom>).
    It 'ignore un message injecté par le client et un message ordinaire' {
        $out = Invoke-Scan @((New-Said '<command-name>non merci</command-name>'), (New-Said 'lance les tests'))
        $out | Should -Match "## Corrections de l'utilisateur.*\nAucune\."
    }

    It 'exclut une ligne plus ancienne que la période' {
        $old = @{ timestamp = (Get-Date).ToUniversalTime().AddDays(-10).ToString('o') }
        Invoke-Scan (New-Run 't6' 'git merge-base y' $Guard $true $old) | Should -Match '## Refus de hooks\nAucun\.'
    }

    It 'exclut un message hors du projet, ou dans un dépôt Git rangé sous sa racine' {
        $outside = @{ cwd = (Join-Path $TestDrive 'other') }
        $nested = @{ cwd = (Join-Path $Proj 'nested') }
        $out = Invoke-Scan (@(New-Run 't7' 'git merge-base a' $Guard $true $outside) + @(New-Run 't8' 'git merge-base b' $Guard $true $nested))
        $out | Should -Match '## Refus de hooks\nAucun\.'
    }

    It 'garde un message d''un sous-dossier du projet' {
        Invoke-Scan (New-Run 't9' 'git merge-base c' $Guard $true @{ cwd = (Join-Path $Proj 'src') }) | Should -Match 'git merge-base c'
    }

    It 'dit qu''il n''a rien lu quand aucun message n''est du projet' {
        Invoke-Scan (New-Said 'non, rien' @{ cwd = (Join-Path $TestDrive 'other') }) | Should -Match 'Aucun message de ce projet sur la période'
    }

    It 'ne compte pas une ligne technique comme un message du projet' {
        $blob = New-Line @{ type = 'api-request-blob'; message = @{ role = 'user'; content = 'non, technique' } }
        Invoke-Scan $blob | Should -Match 'Aucun message de ce projet sur la période'
    }

    It 'masque un jeton reconnu par les secretTokens du projet qui porte le script' {
        # Dans un projet généré, ce sont ceux de son propre .harness/harness.json, lus en premier.
        $token = 'ghp_' + ('a' * 36)
        $out = Invoke-Scan (New-Run 't10' "gh auth login --with-token $token" $Guard)
        $out | Should -Match '\[secret masqué\]'
        $out | Should -Not -Match $token
    }

    It 'masque un jeton même quand -Root désigne un ancien chemin sans .harness' {
        # Les motifs se lisent alors dans le projet qui porte le script.
        $moved = Join-Path $TestDrive 'old' 'location'
        $token = 'ghp_' + ('b' * 36)
        $dir = Join-Path $TestDrive 'moved'; New-Item -ItemType Directory -Force $dir | Out-Null
        ((New-Run 't11' "gh auth login --with-token $token" $Guard $true @{ cwd = $moved }) -join "`n") | Set-Content -Encoding utf8 (Join-Path $dir 'a.jsonl')
        $out = (pwsh -NoProfile -NonInteractive -File $Scan -Path $dir -Root $moved -Days 7 -NoPrs) -join "`n"
        $out | Should -Match 'gh auth login'
        $out | Should -Not -Match $token
        $out | Should -Not -Match 'Masquage des secrets inactif'
    }

    Context 'script hors d''un projet du harness' {
        BeforeAll {
            # Une copie du script dans une arborescence sans .harness : seul -Root peut fournir les motifs.
            $script:Iso = Join-Path $TestDrive 'iso' '.claude' 'skills' 'retro' 'scripts' 'scan-transcripts.ps1'
            New-Item -ItemType Directory -Force (Split-Path $Iso) | Out-Null
            Copy-Item $Scan $Iso
            $script:IsoToken = 'ghp_' + ('c' * 36)
            $script:IsoDir = Join-Path $TestDrive 'iso-transcripts'; New-Item -ItemType Directory -Force $IsoDir | Out-Null
            ((New-Run 't12' "gh auth login --with-token $IsoToken" $Guard) -join "`n") | Set-Content -Encoding utf8 (Join-Path $IsoDir 'a.jsonl')
        }

        It 'se replie sur les secretTokens de -Root' {
            $out = (pwsh -NoProfile -NonInteractive -File $Iso -Path $IsoDir -Root $Proj -Days 7 -NoPrs) -join "`n"
            $out | Should -Match '\[secret masqué\]'
            $out | Should -Not -Match $IsoToken
            $out | Should -Not -Match 'Masquage des secrets inactif'
        }

        It 'dit que le masquage est inactif quand aucun motif n''est trouvé' {
            $bare = Join-Path $TestDrive 'bare'; New-Item -ItemType Directory -Force $bare | Out-Null
            $out = (pwsh -NoProfile -NonInteractive -File $Iso -Path $IsoDir -Root $bare -Days 7 -NoPrs) -join "`n"
            $out | Should -Match 'Masquage des secrets inactif'
        }
    }

    It 'extrait les constats d''auditor, titre en gras compris' {
        $body = "# Audit`n`n**I1. Le préfixe ``**security**:`` est redondant** — ``cliff.toml:22```n`n**M2. Une autre chose** — ``x.ps1:1```n`n<!-- auditor: sha=abc1234 verdict=changes -->"
        $json = Join-Path $TestDrive 'prs.json'
        ConvertTo-Json -Depth 5 -InputObject @(@{ number = 7; title = 'Une PR'; comments = @(@{ body = $body }) }) | Set-Content $json
        $dir = Join-Path $TestDrive 'empty'; New-Item -ItemType Directory -Force $dir | Out-Null
        $out = (pwsh -NoProfile -NonInteractive -File $Scan -Path $dir -Root $Proj -Days 7 -PrsJson $json) -join "`n"
        $out | Should -Match '- #7 Une PR'
        $out | Should -Match 'I1 Le préfixe `\*\*security\*\*:` est redondant'
        $out | Should -Match 'M2 Une autre chose'
    }
}

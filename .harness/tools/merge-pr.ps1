#Requires -Version 7.4
<#
.SYNOPSIS
    Fusionne une PR, seulement si elle a une revue auditor approuvée sur son dernier commit.

.DESCRIPTION
    Seul chemin de fusion autorisé : le hook git-guard refuse tout `gh pr merge` direct, et réserve
    ce script à l'agent git-ops. Les paramètres sont typés, il n'y a donc aucune ligne de commande
    à interpréter. La fusion est faite avec `--match-head-commit` : GitHub la refuse si la PR a reçu
    un commit après la revue.

.PARAMETER Pr
    Numéro de la PR, dans le dépôt courant.

.PARAMETER Strategy
    squash (feature, par défaut) ou merge (branche release/* ou hotfix/*, gitflow).

.PARAMETER Subject
    Message du commit fusionné, obligatoire en squash : en anglais, Conventional Commits,
    numéro d'issue en fin de titre. Exemple : "feat(api): add PDF export for invoices (#42)".

.EXAMPLE
    pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr 12 -Subject "feat(api): add PDF export for invoices (#42)"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateRange(1, [int]::MaxValue)] [int] $Pr,
    [ValidateSet('squash', 'merge')] [string] $Strategy = 'squash',
    [string] $Subject
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Fail([string] $Message) { Write-Host "merge-pr : $Message" -ForegroundColor Red; exit 1 }

# 1. Le message du commit fusionné.
if ($Strategy -eq 'squash') {
    if (-not $Subject) { Fail 'en squash, -Subject est obligatoire (sinon GitHub reprend le titre de la PR, en français).' }
    if ($Subject -notmatch '^(feat|fix|refactor|perf|test|docs|build|ci|chore|revert)(\([a-z0-9-]+\))?!?: \S.* \(#\d+\)$') {
        Fail "-Subject doit suivre Conventional Commits, avec le numéro d'issue en fin de titre : `"feat(api): add PDF export for invoices (#42)`"."
    }
}

# 2. La PR et sa revue auditor.
# Des données de PR simulées (autotests) ne sont acceptées qu'en mode essai : sinon, une fausse PR
# « approuvée » portant le vrai SHA permettrait une vraie fusion sans revue.
if (($env:HARNESS_TEST_PR_JSON -or $env:HARNESS_TEST_GH_LOGIN) -and -not $env:HARNESS_TEST_DRYRUN) { Fail 'HARNESS_TEST_* exige HARNESS_TEST_DRYRUN : des données simulées ne fusionnent jamais pour de vrai.' }
$prData = if ($env:HARNESS_TEST_PR_JSON) { Get-Content $env:HARNESS_TEST_PR_JSON -Raw | ConvertFrom-Json -AsHashtable }
      else { gh pr view $Pr --json number,state,url,headRefOid,comments 2>$null | ConvertFrom-Json -AsHashtable }
if (-not $prData) { Fail "impossible de lire la PR #$Pr." }
if ([int] $prData.number -ne $Pr) { Fail "la PR lue (#$($prData.number)) n'est pas la PR #$Pr." }
if ($prData.state -ne 'OPEN') { Fail "la PR #$Pr n'est pas ouverte ($($prData.state))." }

# 3. Jamais de fusion dans homelab par un agent : fusionner dans homelab, c'est déployer.
# On juge sur l'URL de la PR réellement lue, pas sur `origin` (GH_REPO ou --repo changeraient la cible).
if ([string] $prData.url -notmatch '^https://github\.com/(?<repo>[^/]+/[^/]+)/pull/\d+$') { Fail "URL de PR inattendue : $($prData.url)" }
$repo = $Matches['repo']
if ($repo -match '/homelab$') { Fail "une PR de homelab ne se fusionne qu'à la main, par le propriétaire." }

# 4. La revue : le dernier marqueur auditor, posé par le compte qui fait tourner les agents.
# Les dépôts sont publics : un commentaire d'un autre compte ne vaut jamais approbation.
$trusted = if ($env:HARNESS_TEST_GH_LOGIN) { $env:HARNESS_TEST_GH_LOGIN } else { gh api user --jq .login 2>$null }
if (-not $trusted) { Fail 'impossible de lire le compte GitHub courant (gh auth status).' }
$head = [string] $prData.headRefOid
$verdict = $null
foreach ($comment in @($prData.comments)) {
    $author = if ($comment.author) { [string] $comment.author.login } else { '' }
    if ($author -ne $trusted) { continue }
    if ($comment.body -match '<!--\s*auditor:\s*sha=(?<sha>[0-9a-f]{7,40})\s+verdict=(?<v>\w+)\s*-->') {
        $verdict = @{ Sha = $Matches['sha']; Value = $Matches['v'] }
    }
}
if (-not $verdict) { Fail "la PR #$Pr n'a pas de revue auditor (de $trusted). Lancer /audit-pr avant de fusionner." }
if (-not $head.StartsWith($verdict.Sha)) { Fail "la revue auditor porte sur $($verdict.Sha), mais la PR a reçu des commits depuis (dernier : $($head.Substring(0, 7))). Relancer /audit-pr." }
if ($verdict.Value -ne 'approve') { Fail "la dernière revue auditor demande des changements ($($verdict.Value)). Corriger puis relancer /audit-pr." }

# 5. La fusion, du commit revu et de lui seul, dans le dépôt de la PR lue.
# Branche supprimée seulement en squash : une release/* ou un hotfix/* doit encore être fusionné dans develop.
$ghArgs = @('pr', 'merge', $Pr, '--repo', $repo, "--$Strategy", '--match-head-commit', $head)
if ($Strategy -eq 'squash') { $ghArgs += @('--subject', $Subject, '--delete-branch') }
if ($env:HARNESS_TEST_DRYRUN) { Write-Host "merge-pr (essai) : gh $($ghArgs -join ' ')"; exit 0 }
gh @ghArgs
if ($LASTEXITCODE -ne 0) {
    # La fusion a pu réussir alors qu'une étape annexe (suppression de branche locale) a échoué.
    $state = gh pr view $Pr --repo $repo --json state --jq .state 2>$null
    if ($state -ne 'MERGED') { Fail "gh pr merge a échoué (code $LASTEXITCODE)." }
    Write-Host "merge-pr : PR #$Pr fusionnée, mais une étape annexe a échoué (suppression de branche ?)." -ForegroundColor Yellow
    exit 0
}
Write-Host "merge-pr : PR #$Pr fusionnée ($Strategy, commit revu $($head.Substring(0, 7)))."
#Requires -Version 7.4

<#
.SYNOPSIS
    Place la carte d'une issue dans une colonne du GitHub Project de l'écosystème.

.DESCRIPTION
    Ajoute l'issue au Project si elle n'y est pas encore, puis règle son champ Status.
    Le Project est cherché par son nom chez le propriétaire du dépôt courant ; il est créé
    par scripts/github-setup.ps1, à la racine de services. Réservé à git-ops par git-guard,
    comme toute écriture sur GitHub.

.PARAMETER Issue
    Numéro de l'issue, dans le dépôt courant (ou dans -Repo).

.PARAMETER Status
    La colonne : Idée, Prêt, En cours, En revue ou Fait.

.PARAMETER Repo
    owner/nom du dépôt de l'issue. Par défaut, le dépôt courant.

.PARAMETER Project
    Nom du Project. Par défaut : services.

.EXAMPLE
    pwsh -NoProfile -File .harness/tools/board.ps1 -Issue 42 -Status 'En revue'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateRange(1, [int]::MaxValue)] [int] $Issue,
    [Parameter(Mandatory)] [ValidateSet('Idée', 'Prêt', 'En cours', 'En revue', 'Fait')] [string] $Status,
    [ValidatePattern('^[\w.-]+/[\w.-]+$')] [string] $Repo,
    [string] $Project = 'services'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Fail([string] $Message) { Write-Host "board : $Message" -ForegroundColor Red; exit 1 }

# Chaque appel gh en échec arrête le script : une lecture ratée ne doit jamais passer pour « rien trouvé ».
function Get-GhJson([string[]] $GhArgs) {
    $out = gh @GhArgs
    if ($LASTEXITCODE -ne 0) { Fail "échec de : gh $($GhArgs -join ' ')" }
    if ($out) { $out | ConvertFrom-Json }
}

if (-not $Repo) { $Repo = (Get-GhJson 'repo', 'view', '--json', 'nameWithOwner').nameWithOwner }
if (-not $Repo) { Fail 'dépôt courant introuvable (lancer depuis le dépôt, ou passer -Repo owner/nom).' }
$owner = $Repo.Split('/')[0]

# Le statut exact, avec sa casse et ses accents (ValidateSet accepte « en revue »).
$Status = @('Idée', 'Prêt', 'En cours', 'En revue', 'Fait') | Where-Object { $_ -eq $Status } | Select-Object -First 1

$board = (Get-GhJson 'project', 'list', '--owner', $owner, '--limit', '100', '--format', 'json').projects |
    Where-Object title -eq $Project | Select-Object -First 1
if (-not $board) { Fail "aucun Project « $Project » ouvert chez $owner : le créer avec scripts/github-setup.ps1 (racine services)." }

$field = (Get-GhJson 'project', 'field-list', $board.number, '--owner', $owner, '--format', 'json').fields |
    Where-Object name -eq 'Status' | Select-Object -First 1
if (-not $field) { Fail "le Project « $Project » n'a pas de champ Status : le recréer avec scripts/github-setup.ps1 (racine services)." }
$option = @($field.options) | Where-Object name -eq $Status | Select-Object -First 1
if (-not $option) { Fail "le Project « $Project » n'a pas de colonne « $Status » (colonnes : $(@($field.options.name) -join ', '))." }

# item-add est idempotent : il renvoie la carte existante si l'issue est déjà sur le board.
$item = Get-GhJson 'project', 'item-add', $board.number, '--owner', $owner, '--url', "https://github.com/$Repo/issues/$Issue", '--format', 'json'
if (-not $item.id) { Fail "impossible d'ajouter $Repo#$Issue au Project." }

gh project item-edit --id $item.id --project-id $board.id --field-id $field.id --single-select-option-id $option.id | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "impossible de passer $Repo#$Issue en « $Status »." }
Write-Host "board : $Repo#$Issue → « $Status » (Project $Project)."

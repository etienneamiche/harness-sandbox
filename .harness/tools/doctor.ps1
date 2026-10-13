#Requires -Version 7.4
<#
.SYNOPSIS
    Doctor du harness pour ce dépôt : tout est-il en place et fonctionnel ?

.PARAMETER Fix
    Applique les réparations sans risque (hook Git, .gitignore, plugins, index codegraph).

.PARAMETER Deep
    Lance aussi les autotests Pester des hooks (.harness/tests).

.PARAMETER Offline
    Ne vérifie pas la dernière version publiée du harness (pas d'accès réseau).

.PARAMETER Quiet
    N'affiche que le bilan. Le code de sortie vaut 1 s'il y a au moins un FAIL.
#>
[CmdletBinding()]
param([switch] $Fix, [switch] $Deep, [switch] $Offline, [switch] $Quiet)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$config = Get-Content (Join-Path $root '.harness' 'harness.json') -Raw | ConvertFrom-Json -AsHashtable
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Item, [string] $State, [string] $Detail = '') {
    $results.Add([pscustomobject]@{ Controle = $Item; Etat = $State; Detail = $Detail })
}

# --- Version ----------------------------------------------------------------------
$answers = Get-Content (Join-Path $root '.copier-answers.harness.yml') -Raw
$version = if ($answers -match '(?m)^_commit:\s*[''"]?([^''"\s]+)') { $Matches[1] } else { '' }
$source = if ($answers -match '(?m)^_src_path:\s*[''"]?([^''"\s]+)') { $Matches[1] } else { '' }
if (-not $version) { Add-Result 'version' 'FAIL' '.copier-answers.harness.yml illisible' }
elseif ($Offline -or -not $source) { Add-Result 'version' 'OK' "$version (dernière version non vérifiée)" }
else {
    $url = $source -replace '^gh:', 'https://github.com/'
    $tags = @(git ls-remote --tags --refs $url 2>$null | ForEach-Object { ($_ -split 'refs/tags/')[1] } |
        Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | Sort-Object { [version]($_.TrimStart('v')) })
    $latest = $tags | Select-Object -Last 1
    if ($latest) {
        $cacheDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-harness'
        New-Item -ItemType Directory -Force $cacheDir | Out-Null
        @{ version = $latest; checked = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $cacheDir 'latest-version.json')
    }
    if (-not $latest) { Add-Result 'version' 'WARN' "$version (dépôt source injoignable : $url)" }
    elseif ($version -eq $latest) { Add-Result 'version' 'OK' "$version (à jour)" }
    else { Add-Result 'version' 'WARN' "$version, dernière version : $latest (scripts/harness-sync.ps1)" }
}

# --- Intégrité des fichiers du harness -------------------------------------------
$manifestPath = Join-Path $root '.harness' 'manifest.json'
if (-not (Test-Path $manifestPath)) { Add-Result 'fichiers du harness' 'FAIL' 'manifest.json absent (.harness/tools/post-install.ps1)' }
else {
    $expected = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $actual = & (Join-Path $PSScriptRoot 'write-manifest.ps1') -Print
    $modified = @($expected.Keys | Where-Object { $actual.Contains($_) -and $actual[$_] -ne $expected[$_] })
    $missing = @($expected.Keys | Where-Object { -not $actual.Contains($_) })
    $extra = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) })
    if ($modified -or $missing) {
        $parts = @()
        if ($modified) { $parts += "modifiés : $($modified -join ', ')" }
        if ($missing) { $parts += "absents : $($missing -join ', ')" }
        Add-Result 'fichiers du harness' 'FAIL' "$($parts -join ' ; ') (restaurer : copier recopy)"
    }
    elseif ($extra) { Add-Result 'fichiers du harness' 'WARN' "fichiers ajoutés hors harness : $($extra -join ', ')" }
    else { Add-Result 'fichiers du harness' 'OK' "$($expected.Count) fichiers intacts" }
}

# --- Hooks Claude Code ------------------------------------------------------------
$settings = Get-Content (Join-Path $root '.claude' 'settings.json') -Raw | ConvertFrom-Json -AsHashtable
$events = 'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'
$wired = @($events | Where-Object {
    $settings.hooks.ContainsKey($_) -and (($settings.hooks[$_] | ConvertTo-Json -Depth 10) -match 'dispatch\.ps1')
})
if ($wired.Count -eq $events.Count) { Add-Result 'hooks Claude Code' 'OK' "$($events.Count) événements branchés" }
else { Add-Result 'hooks Claude Code' 'FAIL' "non branchés : $(($events | Where-Object { $wired -notcontains $_ }) -join ', ')" }

if ($config.kind -ne 'root') {
    if ($settings.ContainsKey('claudeMdExcludes')) { Add-Result 'claudeMdExcludes' 'OK' 'instructions de la racine exclues' }
    else { Add-Result 'claudeMdExcludes' 'FAIL' 'absent : les instructions de services/ fuiraient dans ce projet' }
}

# --- Subagents : modèle déclaré conforme à la liste blanche ----------------------
$agentIssues = foreach ($file in Get-ChildItem (Join-Path $root '.claude' 'agents') -Filter *.md -ErrorAction SilentlyContinue) {
    $text = Get-Content $file.FullName -Raw
    $name = if ($text -match '(?m)^name:\s*(\S+)') { $Matches[1] } else { $file.BaseName }
    $model = if ($text -match '(?m)^model:\s*(\S+)') { $Matches[1] } else { '(aucun)' }
    if (-not $config.allowedAgents.ContainsKey($name)) { "$name non autorisé" }
    elseif ($config.allowedAgents[$name] -ne $model) { "$name en $model au lieu de $($config.allowedAgents[$name])" }
}
if ($agentIssues) { Add-Result 'subagents' 'FAIL' ($agentIssues -join ' ; ') }
else { Add-Result 'subagents' 'OK' 'modèles conformes' }

# --- Hook Git pre-commit ----------------------------------------------------------
if (Test-Path (Join-Path $root '.git')) {
    $hooksPath = git -C $root config core.hooksPath
    if ($hooksPath -ne '.harness/githooks' -and $Fix) { git -C $root config core.hooksPath .harness/githooks; $hooksPath = '.harness/githooks' }
    if ($hooksPath -eq '.harness/githooks') { Add-Result 'hook pre-commit' 'OK' 'core.hooksPath' }
    else { Add-Result 'hook pre-commit' 'FAIL' 'core.hooksPath non réglé (-Fix)' }
}
else { Add-Result 'hook pre-commit' 'WARN' "pas de dépôt Git" }

if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) { Add-Result 'gitleaks' 'FAIL' 'absent : tout commit sera refusé' }

# --- .gitignore -------------------------------------------------------------------
$gitignore = Join-Path $root '.gitignore'
$hasBlock = (Test-Path $gitignore) -and ((Get-Content $gitignore -Raw) -match '# >>> harness')
if (-not $hasBlock -and $Fix) { & (Join-Path $PSScriptRoot 'post-install.ps1') -SkipPlugins | Out-Null; $hasBlock = $true }
if ($hasBlock) { Add-Result '.gitignore' 'OK' 'bloc harness présent' } else { Add-Result '.gitignore' 'FAIL' 'bloc harness absent (-Fix)' }

# --- Plugins ----------------------------------------------------------------------
$registry = Join-Path $HOME '.claude' 'plugins' 'installed_plugins.json'
$installed = if (Test-Path $registry) { (Get-Content $registry -Raw | ConvertFrom-Json -AsHashtable).plugins } else { @{} }
$missingPlugins = @(@($settings.enabledPlugins.Keys) | Where-Object {
    $plugin = $_
    -not ($installed.ContainsKey($plugin) -and @($installed[$plugin] | Where-Object {
        $_.scope -eq 'user' -or ($_.projectPath -and [IO.Path]::GetFullPath($_.projectPath) -eq $root)
    }))
})
if ($missingPlugins -and $Fix -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    Push-Location $root
    try { foreach ($p in $missingPlugins) { claude plugin install $p --scope project --json 2>$null | Out-Null } }
    finally { Pop-Location }
    $missingPlugins = @()
}
if ($env:HARNESS_SKIP_PLUGINS) { Add-Result 'plugins' 'WARN' 'non vérifiés (HARNESS_SKIP_PLUGINS)' }
elseif ($missingPlugins) { Add-Result 'plugins' 'FAIL' "non installés : $($missingPlugins -join ', ') (-Fix)" }
else { Add-Result 'plugins' 'OK' (@($settings.enabledPlugins.Keys) -join ', ') }

# --- codegraph --------------------------------------------------------------------
$hasIndex = Test-Path (Join-Path $root '.codegraph')
if (-not $hasIndex -and $Fix -and (Get-Command codegraph -ErrorAction SilentlyContinue)) { codegraph init $root | Out-Null; $hasIndex = Test-Path (Join-Path $root '.codegraph') }
if ($hasIndex) { Add-Result 'codegraph' 'OK' 'index présent' } else { Add-Result 'codegraph' 'WARN' 'index absent (-Fix ou codegraph init)' }

# --- Autotests --------------------------------------------------------------------
if ($Deep) {
    $pester = Invoke-Pester -Path (Join-Path $root '.harness' 'tests') -PassThru -Output None
    if ($pester.FailedCount -eq 0) { Add-Result 'autotests' 'OK' "$($pester.PassedCount) tests verts" }
    else { Add-Result 'autotests' 'FAIL' "$($pester.FailedCount) en échec : $(($pester.Failed | Select-Object -First 3 | ForEach-Object ExpandedName) -join ' ; ')" }
}

# --- Bilan ------------------------------------------------------------------------
$failed = @($results | Where-Object Etat -eq 'FAIL').Count
if (-not $Quiet) { $results | Format-Table -AutoSize -Wrap | Out-Host }
Write-Host ("{0} : {1} échec(s), {2} avertissement(s)." -f (Split-Path $root -Leaf), $failed, @($results | Where-Object Etat -eq 'WARN').Count)
exit ([int]($failed -gt 0))

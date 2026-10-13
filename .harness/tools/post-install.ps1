#Requires -Version 7.4
<#
.SYNOPSIS
    Finalise l'installation ou la mise à jour du harness dans un projet.

.DESCRIPTION
    Lancé par Copier (`_tasks`) après `copier copy` ou `copier update`, dans le dossier du projet.
    Idempotent. Étapes :
      1. hook Git pre-commit (core.hooksPath) ;
      2. bloc géré dans .gitignore ;
      3. plugins Claude Code du projet (`claude plugin install --scope project`) ;
      4. manifeste des fichiers du harness (détection des modifications manuelles).
#>
[CmdletBinding()]
param([switch] $SkipPlugins)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $root

function Step([string] $Text) { Write-Host "harness : $Text" }

# 1. Hook Git
if (Test-Path (Join-Path $root '.git')) {
    git config core.hooksPath .harness/githooks
    Step 'hook pre-commit activé (core.hooksPath)'
}
else {
    Step "pas de dépôt Git ici : hook pre-commit à activer après 'git init' (relancer ce script)"
}

# 2. Bloc géré dans .gitignore : seul ce qui est entre les marqueurs appartient au harness.
$gitignore = Join-Path $root '.gitignore'
$begin, $end = '# >>> harness (géré automatiquement, ne pas modifier)', '# <<< harness'
$block = @($begin) + @(Get-Content (Join-Path $root '.harness' 'gitignore.txt')) + @($end)
[string[]] $current = @(if (Test-Path $gitignore) { Get-Content $gitignore })
$start = [Array]::IndexOf($current, $begin)
$stop = [Array]::IndexOf($current, $end)
if ($start -ge 0 -and $stop -gt $start) {
    $before = if ($start -gt 0) { $current[0..($start - 1)] } else { @() }
    $after = if ($stop -lt $current.Count - 1) { $current[($stop + 1)..($current.Count - 1)] } else { @() }
    $updated = @($before) + $block + @($after)
}
else {
    $updated = $block + @('') + $current
}
[IO.File]::WriteAllText($gitignore, (($updated -join "`n").TrimEnd() + "`n"), [Text.UTF8Encoding]::new($false))
Step '.gitignore à jour'

# 3. Plugins : les déclarer dans settings.json ne suffit pas à les installer (spike phase 1).
if ($env:HARNESS_SKIP_PLUGINS) { $SkipPlugins = $true }
if (-not $SkipPlugins -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    $settings = Get-Content (Join-Path $root '.claude' 'settings.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($plugin in @($settings.enabledPlugins.Keys)) {
        $result = claude plugin install $plugin --scope project --json 2>$null | Select-Object -Last 1 | ConvertFrom-Json -ErrorAction SilentlyContinue
        Step "plugin $plugin : $(if ($result) { $result.outcome } else { 'échec' })"
    }
}

# 4. Manifeste : empreinte de chaque fichier géré par le harness.
& (Join-Path $PSScriptRoot 'write-manifest.ps1')
Step 'manifeste écrit'

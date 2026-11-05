#Requires -Version 7.4

<#
.SYNOPSIS
    Écrit .harness/manifest.json : l'empreinte SHA-256 de chaque fichier géré par le harness.

.DESCRIPTION
    Le doctor compare ce manifeste à l'état réel pour détecter une modification manuelle.
    Lancé par post-install.ps1 après `copier copy` ou `copier update`. Les fins de ligne sont
    normalisées : un checkout CRLF ou LF ne compte pas comme une modification.

.PARAMETER Print
    Rend le manifeste au lieu de l'écrire.

.EXAMPLE
    pwsh -NoProfile -File .harness/tools/write-manifest.ps1
#>
param([switch] $Print)

$root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

function Get-HarnessFiles {
    $paths = @('CLAUDE.md', '.claude/settings.json')
    foreach ($dir in '.harness', '.claude/agents', '.claude/skills') {
        $full = Join-Path $root $dir
        if (Test-Path $full) {
            $paths += Get-ChildItem $full -Recurse -File | ForEach-Object {
                [IO.Path]::GetRelativePath($root, $_.FullName) -replace '\\', '/'
            }
        }
    }
    # Exclus : le manifeste lui-même et les caches.
    $paths | Where-Object { $_ -notmatch '^\.harness/(manifest\.json|\.cache/)' -and (Test-Path (Join-Path $root $_)) } | Sort-Object -Unique
}

$manifest = [ordered]@{}
foreach ($file in Get-HarnessFiles) {
    # Normalisation des fins de ligne : un checkout CRLF/LF ne doit pas compter comme une modification.
    $text = [IO.File]::ReadAllText((Join-Path $root $file)) -replace "`r`n", "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $manifest[$file] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

if ($Print) { return $manifest }
$json = $manifest | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $root '.harness' 'manifest.json'), $json + "`n", [Text.UTF8Encoding]::new($false))

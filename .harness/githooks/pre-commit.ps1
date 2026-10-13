#Requires -Version 7.4
# pre-commit : aucun secret ne part dans un commit, qu'il vienne d'un agent ou d'un humain.
# Échec fermé : sans gitleaks, le commit est refusé.

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = git rev-parse --show-toplevel

# 1. Noms de fichiers : un fichier secret ne s'indexe pas, même vide.
$config = Get-Content (Join-Path $root '.harness' 'harness.json') -Raw | ConvertFrom-Json -AsHashtable
$staged = @(git diff --cached --name-only --diff-filter=ACMR)
foreach ($file in $staged) {
    $isSecret = @($config.secretPaths | Where-Object { $file -match $_ }).Count -gt 0
    $isAllowed = @($config.secretPathsAllow | Where-Object { $file -match $_ }).Count -gt 0
    if ($isSecret -and -not $isAllowed) {
        Write-Host "harness/pre-commit : '$file' est un fichier secret, il ne doit pas être commité." -ForegroundColor Red
        Write-Host "  Le retirer de l'index : git restore --staged '$file'" -ForegroundColor Red
        exit 1
    }
}

# 2. Contenu : gitleaks sur les modifications indexées.
if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    Write-Host 'harness/pre-commit : gitleaks est introuvable, commit refusé (scripts/setup-workstation.ps1).' -ForegroundColor Red
    exit 1
}
gitleaks git --pre-commit --staged --redact --no-banner --log-level warn $root
if ($LASTEXITCODE -ne 0) {
    Write-Host 'harness/pre-commit : gitleaks a détecté un secret, commit refusé.' -ForegroundColor Red
    Write-Host "  Retirer le secret du fichier. S'il est réel, le révoquer : il a peut-être déjà fuité ailleurs." -ForegroundColor Red
    exit 1
}
exit 0

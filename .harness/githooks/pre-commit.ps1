#Requires -Version 7.4
# pre-commit : aucun secret ne part dans un commit, qu'il vienne d'un agent ou d'un humain.
# Échec fermé : sans gitleaks, le commit est refusé.

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = git rev-parse --show-toplevel

# 1. Noms de fichiers : un fichier secret ne s'indexe pas, même vide.
$config = Get-Content (Join-Path $root '.harness' 'harness.json') -Raw | ConvertFrom-Json -AsHashtable
# -z et quotePath=false : un nom non ASCII arrive tel quel, pas entre guillemets avec des \303.
$staged = @((git -c core.quotePath=false diff --cached --name-only -z --diff-filter=ACMR) -join '' -split "`0" | Where-Object { $_ })
foreach ($file in $staged) {
    # Un plan OpenTofu contient l'état en clair. Il n'est pas dans secretPaths, pour que
    # `tofu plan -out=x.tfplan` et `tofu apply x.tfplan` restent permis à secret-guard.
    $isSecret = $file -match '\.tfplan$' -or @($config.secretPaths | Where-Object { $file -match $_ }).Count -gt 0
    $isAllowed = @($config.secretPathsAllow | Where-Object { $file -match $_ }).Count -gt 0
    if ($isSecret -and -not $isAllowed) {
        Write-Host "harness/pre-commit : '$file' est un fichier secret, il ne doit pas être commité." -ForegroundColor Red
        Write-Host "  Le retirer de l'index : git restore --staged '$file'" -ForegroundColor Red
        exit 1
    }
}

# 2. Fichiers SOPS : chaque *.sops.yaml indexé est chiffré (`sops -e` oublié = secret en clair).
#    Un manifeste `Secret` de Kubernetes n'a que `data` et `stringData` chiffrés ; tout autre fichier
#    l'est en entier, commentaires compris. Lecture ligne à ligne de la version indexée, document
#    YAML par document (SOPS écrit un bloc sops: par document) : chaque valeur doit être un ENC[…].
$sopsKeys = '^\s+(age|kms|gcp_kms|azure_kv|hc_vault|hckms|pgp|key_groups|shamir_threshold|lastmodified|mac|mac_only_encrypted|version|(un)?encrypted_(suffix|regex|comment_regex)):'
function Get-SopsProblem([string[]] $Lines) {
    $docs = [Collections.Generic.List[object]]::new()
    $doc = [Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line -match '^---\s*$') { $docs.Add($doc); $doc = [Collections.Generic.List[string]]::new() } else { $doc.Add($line) }
    }
    $docs.Add($doc)
    foreach ($doc in $docs) {
        if (-not @($doc | Where-Object { $_ -match '\S' })) { continue }
        # Le bloc sops: va jusqu'à la ligne suivante qui n'est pas indentée : ce qui suit est contrôlé.
        # À son premier niveau, seules les clés de SOPS sont admises : une ligne indentée ajoutée en
        # fin de fichier lui serait sinon rattachée sans contrôle.
        $inSops = $false; $hasMac = $false; $strays = 0; $sopsIndent = $null
        $body = @(foreach ($line in $doc) {
            if ($line -match '^\S') { $inSops = $line -match '^sops:\s*$'; $sopsIndent = $null; if ($inSops) { continue } }
            if ($inSops) {
                if ($line -match '^\s+mac:\s*ENC\[') { $hasMac = $true }
                if ($line -match '^(\s+)\S') {
                    if ($null -eq $sopsIndent) { $sopsIndent = $Matches[1].Length }
                    if ($Matches[1].Length -le $sopsIndent -and $line -notmatch $sopsKeys) { $strays++ }
                }
                continue
            }
            $line
        })
        if (-not $hasMac) { return 'un document n''a pas de bloc sops: avec un mac chiffré' }
        if ($strays) { return "$strays ligne(s) étrangère(s) au bloc sops:" }
        $isK8sSecret = @($body -match '^kind:\s*Secret\s*$').Count -gt 0 -and @($body -match '^apiVersion:\s*v1\s*$').Count -gt 0
        $section = ''
        $plain = @(foreach ($line in $body) {
            if ($line -match '^([^\s#][^:]*):') { $section = $Matches[1] }
            if ($isK8sSecret -and $section -notin 'data', 'stringData') { continue }
            if ($line -match '^\s*$' -or $line -match '^\s*(-\s+)?#?ENC\[') { continue }
            if ($line -match '^\s*#') { $line; continue }
            # Une valeur : après `clé:` ou après `- `. `clé:` seul ouvre un bloc, sans valeur.
            $value = if ($line -match '^\s*(-\s+)?[^\s#:-][^:]*:\s*(.*)$') { $Matches[2] } elseif ($line -match '^\s*-\s+(.*)$') { $Matches[1] } else { $line.Trim() }
            # SOPS laisse en clair les valeurs vides : "", null, ~, {} et [].
            if ($value -and $value -notmatch '^ENC\[' -and $value -notmatch '^(""|''''|null|~|\{\}|\[\])\s*$') { $line }
        })
        if ($plain) { return "$($plain.Count) valeur(s) ou commentaire(s) en clair" }
    }
}
foreach ($file in $staged | Where-Object { $_ -match '(^|/)[^/]+\.sops\.ya?ml$' }) {
    $problem = Get-SopsProblem (@(git show ":$file") -replace '\r$', '')
    if ($problem) {
        Write-Host "harness/pre-commit : '$file' n'est pas chiffré ($problem), commit refusé." -ForegroundColor Red
        Write-Host "  Le chiffrer d'abord : sops -e -i '$file', ou le modifier par sops edit. Tout fichier se chiffre en entier (pas de clé *_unencrypted ni de commentaire en clair), sauf les manifestes Secret de Kubernetes, dont seuls data et stringData le sont." -ForegroundColor Red
        exit 1
    }
}

# 3. Contenu : gitleaks sur les modifications indexées.
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

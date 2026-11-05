#Requires -Version 7.4

<#
.SYNOPSIS
    Relève, en lecture seule, ce qui a gêné le travail dans les transcripts Claude Code du projet et dans les revues auditor.

.DESCRIPTION
    Lit les transcripts Claude Code sur une période et ne garde que les messages du projet : ceux dont le dossier
    de travail (cwd) est la racine du projet ou un de ses sous-dossiers. Les sessions ouvertes depuis un dossier
    parent (la racine d'un écosystème, par exemple) sont donc lues elles aussi. Chaque message n'est compté
    qu'une fois, même quand une session reprise le recopie dans un autre fichier.

    Rend un rapport Markdown :
      - les refus de hooks, groupés par règle et par raison, avec chaque commande refusée ;
      - les commandes qui ont échoué au moins deux fois ;
      - les messages de l'utilisateur qui ressemblent à une correction (« non, … », « je t'ai dit… ») ;
      - les constats d'auditor (B1, I1, M1…) des PR fusionnées sur la période, sauf avec -NoPrs.
    Les extraits sont tronqués, et les jetons reconnus par secretTokens (.harness/harness.json) sont masqués.
    Ne modifie rien. Le tri des constats revient à la session : ce rapport n'est que la matière.

.PARAMETER Days
    Période couverte, en jours (14 par défaut).

.PARAMETER Path
    Dossier(s) de transcripts. Par défaut, ceux de la racine du projet et de ses dossiers parents, sous
    ~/.claude/projects : le chemin, chaque caractère non alphanumérique remplacé par « - ».

.PARAMETER Root
    Racine du projet. Par défaut, la racine Git du dossier courant.

.PARAMETER Prs
    Nombre maximal de PR fusionnées à lire pour les constats d'auditor (10 par défaut).

.PARAMETER NoPrs
    Ne lit pas les PR (pas de gh, pas de réseau).

.PARAMETER PrsJson
    Fichier JSON à la place de `gh pr list` (tests) : une liste de PR avec number, title et comments.

.EXAMPLE
    pwsh -NoProfile -File .claude/skills/retro/scripts/scan-transcripts.ps1 -Days 30
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 365)] [int] $Days = 14,
    [string[]] $Path,
    [string] $Root,
    [ValidateRange(1, 50)] [int] $Prs = 10,
    [switch] $NoPrs,
    [string] $PrsJson
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not $Root) { $Root = git rev-parse --show-toplevel 2>$null }
if (-not $Root) { $Root = (Get-Location).Path }
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
$since = (Get-Date).AddDays(-$Days)
$projects = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude' 'projects'
function ConvertTo-ProjectDir([string] $Dir) { Join-Path $projects ($Dir -replace '[^A-Za-z0-9]', '-') }

# Les dossiers à lire : celui de la racine, et ceux des dossiers parents (sessions ouvertes plus haut).
$ownDir = ConvertTo-ProjectDir $Root
if (-not $Path) {
    $Path = @(); $d = $Root
    while ($d) { $Path += ConvertTo-ProjectDir $d; $d = Split-Path $d -Parent }
}
$Path = @($Path | Where-Object { Test-Path -LiteralPath $_ })

$inProject = @{}   # cache : cwd → appartient au projet
function Test-InProject([string] $Cwd) {
    if ($inProject.ContainsKey($Cwd)) { return $inProject[$Cwd] }
    $full = [IO.Path]::GetFullPath($Cwd).TrimEnd('\', '/')
    $ok = $full -ieq $Root -or $full.StartsWith("$Root\", 'OrdinalIgnoreCase') -or $full.StartsWith("$Root/", 'OrdinalIgnoreCase')
    # Un dépôt Git rangé sous la racine (un clone dans le dossier d'un écosystème) est un autre projet.
    $d = $full
    while ($ok -and $d.Length -gt $Root.Length) {
        if (Test-Path -LiteralPath (Join-Path $d '.git')) { $ok = $false }
        $d = Split-Path $d -Parent
    }
    $inProject[$Cwd] = $ok
    $ok
}

# Les secrets ne quittent pas le poste : les motifs du harness masquent les jetons dans les extraits.
# Ils se lisent d'abord dans le projet qui porte ce script (.claude/skills/retro/scripts → 4 niveaux) :
# -Root peut désigner un ancien chemin, où .harness n'existe plus.
$secretPatterns = @()
$harnessJson = @(
    (Join-Path $PSScriptRoot '..' '..' '..' '..' '.harness' 'harness.json')
    (Join-Path $Root '.harness' 'harness.json')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($harnessJson) {
    $tokens = (Get-Content -LiteralPath $harnessJson -Raw | ConvertFrom-Json).secretTokens
    if ($tokens) { $secretPatterns = @($tokens.PSObject.Properties | ForEach-Object Value) }
}

function Get-Text($content) {
    if ($content -is [string]) { return $content }
    (@($content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
}
function Get-Short([string] $Text, [int] $Max = 140) {
    $one = ($Text -replace '\s+', ' ').Trim()
    foreach ($p in $secretPatterns) { $one = [regex]::Replace($one, $p, '[secret masqué]') }
    if ($one.Length -le $Max) { $one } else { $one.Substring(0, $Max) + '…' }
}

$denials = @{}; $failures = @{}; $corrections = [System.Collections.Generic.List[object]]::new()
$sessions = [System.Collections.Generic.HashSet[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()   # uuid des messages déjà lus (sessions reprises)
$calls = @{}                                                  # tool_use id → outil et commande, tous fichiers
$messages = 0
# Une correction commence par un refus ou un rappel ; les messages injectés (<…>) sont ignorés.
$correction = '^(non\b|nan\b|pas (ça|comme)|arr[eê]te|stop\b|je t[''\u2019]ai (déjà )?(dit|demandé)|j[''\u2019]ai (déjà )?dit|on avait dit|ne (fais|touche|mets|lance|modifie)|n[''\u2019]utilise pas|toujours\b|jamais\b)'

$files = @(foreach ($p in $Path) { Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*.jsonl' | Where-Object LastWriteTime -ge $since })
# Les fichiers les plus anciens d'abord : une session reprise recopie l'historique dans un fichier plus récent.
$files = @($files | Sort-Object LastWriteTime)

foreach ($file in $files) {
    $inOwnDir = $file.FullName.StartsWith($ownDir, 'OrdinalIgnoreCase')
    foreach ($line in [IO.File]::ReadLines($file.FullName)) {
        $o = try { $line | ConvertFrom-Json -Depth 20 } catch { $null }
        # Seuls les échanges comptent : les lignes techniques (api-request-blob…) ne sont pas des messages.
        if (-not $o -or -not $o.message -or $o.type -notin 'user', 'assistant') { continue }
        if ($o.uuid -and -not $seen.Add([string] $o.uuid)) { continue }
        if ($o.timestamp -and ([datetime] $o.timestamp) -lt $since) { continue }
        # Un message sans cwd n'est gardé que dans le dossier propre au projet.
        if ($o.cwd) { if (-not (Test-InProject $o.cwd)) { continue } } elseif (-not $inOwnDir -and -not $PSBoundParameters.ContainsKey('Path')) { continue }
        $messages++
        if ($o.sessionId) { [void] $sessions.Add($o.sessionId) }
        $content = $o.message.content
        if ($o.type -eq 'assistant') {
            foreach ($c in @($content) | Where-Object { $_.type -eq 'tool_use' }) {
                $what = if ($c.input.command) { $c.input.command } elseif ($c.input.file_path) { $c.input.file_path } else { '' }
                $calls[$c.id] = @{ Tool = $c.name; What = [string] $what }
            }
            continue
        }
        $results = @(@($content) | Where-Object { $_ -isnot [string] -and $_.type -eq 'tool_result' })
        foreach ($r in $results | Where-Object { $_.is_error }) {
            $text = Get-Text $r.content
            $call = $calls[$r.tool_use_id]
            $cmd = if ($call) { Get-Short $call.What 120 } else { '' }
            if ($text -match 'hook error:\s*(?:harness/)?([\w-]+)\s*:\s*(.+)') {
                $key = "$($Matches[1]) : $(Get-Short $Matches[2] 160)"
                if (-not $denials[$key]) { $denials[$key] = @{ Count = 0; Commands = @{}; Sessions = [System.Collections.Generic.HashSet[string]]::new() } }
                $denials[$key].Count++; [void] $denials[$key].Sessions.Add([string] $o.sessionId)
                # Une même raison couvre des gestes différents : chaque commande refusée garde son compte.
                if ($cmd) { $denials[$key].Commands[$cmd] = 1 + [int] $denials[$key].Commands[$cmd] }
            }
            elseif ($call) {
                # Même commande exacte, ou même outil et même erreur quand l'appel n'a pas de commande.
                $key = if ($call.What) { "$($call.Tool) : $($call.What.Trim())" } else { "$($call.Tool) : $(Get-Short $text 60)" }
                if (-not $failures[$key]) { $failures[$key] = @{ Count = 0; Label = $(if ($cmd) { "$($call.Tool) : $cmd" } else { $call.Tool }); Error = Get-Short $text 160 } }
                $failures[$key].Count++
            }
        }
        if (-not $results) {
            $text = (Get-Text $content).Trim()
            if ($text -and -not $text.StartsWith('<') -and $text -match "(?i)$correction") {
                $corrections.Add([pscustomobject]@{ Time = [datetime] $o.timestamp; Text = Get-Short $text 200 })
            }
        }
    }
}

$out = [System.Collections.Generic.List[string]]::new()
$out.Add("# Matière de la rétro — $(Split-Path $Root -Leaf), $Days derniers jours")
$out.Add('')
$dirs = if ($Path) { ($Path | ForEach-Object { '`' + $_ + '`' }) -join ', ' } else { 'aucun dossier trouvé' }
$out.Add("Projet : ``$Root``. Transcripts lus : $dirs.")
$out.Add("$($files.Count) fichier(s), $($sessions.Count) session(s), $messages message(s) du projet.")
if (-not $secretPatterns) { $out.Add("**Masquage des secrets inactif** : aucun ``.harness/harness.json`` avec ``secretTokens`` trouvé. Relire les extraits avant d'en citer un.") }
if (-not $messages) {
    $out.Add('')
    $out.Add("**Aucun message de ce projet sur la période** : la rétro n'a pas de matière tirée des transcripts. Ce n'est pas le signe que tout va bien. Vérifier la période (``-Days``), l'ancien chemin d'un projet déplacé ou lancé ailleurs (``-Root``), ou le dossier des transcripts (``-Path``).")
}

$out.Add(''); $out.Add('## Refus de hooks')
if ($denials.Count) {
    foreach ($e in $denials.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending) {
        $out.Add("- **$($e.Value.Count)×** ($($e.Value.Sessions.Count) session(s)) $($e.Key)")
        foreach ($c in $e.Value.Commands.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8) { $out.Add("  - $($c.Value)× ``$($c.Key)``") }
    }
} else { $out.Add('Aucun.') }

$out.Add(''); $out.Add('## Échecs répétés (2 fois ou plus)')
$repeated = @($failures.GetEnumerator() | Where-Object { $_.Value.Count -ge 2 } | Sort-Object { $_.Value.Count } -Descending)
if ($repeated) { foreach ($e in $repeated) { $out.Add("- **$($e.Value.Count)×** ``$($e.Value.Label)`` — $($e.Value.Error)") } } else { $out.Add('Aucun.') }

$out.Add(''); $out.Add("## Corrections de l'utilisateur (à relire : repérées par leurs premiers mots)")
if ($corrections.Count) {
    foreach ($c in $corrections | Sort-Object Time | Select-Object -Last 30) { $out.Add("- $($c.Time.ToString('yyyy-MM-dd')) : « $($c.Text) »") }
} else { $out.Add('Aucune.') }

if (-not $NoPrs) {
    $out.Add(''); $out.Add("## Constats d'auditor (PR fusionnées depuis le $($since.ToString('yyyy-MM-dd')), $Prs au plus)")
    $list = if ($PrsJson) { Get-Content $PrsJson -Raw }
            else { gh pr list --state merged --search "merged:>=$($since.ToString('yyyy-MM-dd'))" --limit $Prs --json number,title,comments 2>$null }
    if (-not $PrsJson -and $LASTEXITCODE -ne 0) { $out.Add('Lecture impossible (gh).') }
    else {
        $any = $false
        foreach ($pr in $list | ConvertFrom-Json) {
            $titles = foreach ($c in $pr.comments | Where-Object { $_.body -match 'auditor:\s*sha=' }) {
                [regex]::Matches($c.body, '(?m)^\*\*([BIM]\d+)\.\s*(.+?)\*\*(?=\s*(?:—|$))') | ForEach-Object { "$($_.Groups[1].Value) $(Get-Short $_.Groups[2].Value 160)" }
            }
            if ($titles) { $any = $true; $out.Add("- #$($pr.number) $($pr.title)"); foreach ($t in $titles | Select-Object -Unique) { $out.Add("  - $t") } }
        }
        if (-not $any) { $out.Add('Aucun constat.') }
    }
}
$out -join "`n"

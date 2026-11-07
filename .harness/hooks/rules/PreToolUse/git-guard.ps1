# git-guard : opérations Git et GitHub réservées à certains agents, gestes interdits,
# format des commits, et revue `auditor` obligatoire avant toute fusion.
@{
    Name     = 'git-guard'
    Event    = 'PreToolUse'
    Tools    = 'Bash|PowerShell'
    Profiles = 'minimal', 'standard', 'strict'
    Kind     = 'guard'
    Run      = {
        param($ctx)
        $cmd = Get-Value $ctx.ToolInput 'command' ''
        $raw = $cmd
        # merge-pr.ps1 et board.ps1 ne contiennent ni « git » ni « gh » : ils doivent quand même passer par les règles.
        if ($cmd -notmatch '\b(git|gh)\b|(?<![\w.-])(merge-pr|board)\.ps1') { return }
        # Options globales de git (-C dossier, -c clé=valeur, --git-dir…) retirées avant l'analyse :
        # `git -C x push` reste un `git push`. Le dossier visé sert à lire la branche courante.
        $gitDir = $ctx.Cwd
        if ($cmd -match '\bgit\s+-C\s+("(?<d>[^"]+)"|''(?<d>[^'']+)''|(?<d>\S+))') { $gitDir = [IO.Path]::GetFullPath($Matches['d'], $ctx.Cwd) }
        # Un alias git défini en ligne (`git -c alias.p=push p`) masquerait la vraie sous-commande.
        if ($cmd -match '\bgit\b[^;&|]*\s-c\s*["'']?alias\.') {
            return @{ Decision = 'deny'; Reason = "pas d'alias git défini dans la commande (-c alias.…) : écrire la sous-commande en clair." }
        }
        # Toute option placée avant la sous-commande est retirée (celles qui prennent une valeur avec elle,
        # et --% de pwsh) : `git -C x --% push` reste un `git push`. Même chose pour gh : -R / --repo peut
        # se placer avant ou après le groupe (`gh pr -R x merge`).
        $normalize = {
            param([string] $t)
            $t = [regex]::Replace($t, '\bgit((\s+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env|--super-prefix)(=|\s+)("[^"]*"|''[^'']*''|\S+))|(\s+--?[A-Za-z][\w-]*(=\S+)?)|(\s+--%))+', 'git')
            [regex]::Replace($t, '\s(-R|--repo)(?<=\bgh\b[^;&|\n]*\s(?:-R|--repo))(=|\s+)("[^"]*"|''[^'']*''|\S+)', '')
        }
        $cmd = & $normalize $cmd
        $agent = $ctx.AgentType
        $config = $ctx.Config
        $who = if ($agent) { "l'agent '$agent'" } else { 'la session principale' }

        # 1. Interdits pour tout le monde. Ils portent sur les options de la commande, pas sur le texte
        # qu'elle transporte : un message de commit qui parle de `-Days` ou de `--no-verify` n'est pas une option.
        # La commande est découpée hors des chaînes : des commandes (séparées par ; & | ( ) { } et les fins de
        # ligne), puis leurs mots, un mot pouvant coller plusieurs chaînes ('l''option'). Seul le texte d'un
        # programme identifié est retiré de l'analyse. Une autre chaîne peut être exécutée (bash -c, iex, trap,
        # awk…) : elle reste visible, et ses guillemets se lisent comme des espaces.
        # Ce qui peut être retiré, si bash ET pwsh le traitent à coup sûr comme littéral : une chaîne '…' ou "…"
        # fermée sur sa ligne ("…" sans $ ni `, et dont chaque \ précède un caractère de chemin), le corps d'une
        # here-string @'…'@ sans apostrophe, un "$(cat <<'EOF' … EOF)", et le corps d'un heredoc à délimiteur cité.
        # Ce qui l'est :
        #  - la valeur d'une option de texte de ce programme et de cette sous-commande ($textOptions), sa sortie
        #    pouvant partir dans un tube (git log --grep '…' | head) ;
        #  - la valeur d'une variable nommée comme un texte, seule dans sa commande et sans tube ($textName) ;
        #  - ce qui part vers le texte de git ou de gh (-F -) ou dans un fichier .md ou .txt, sans tube ensuite (Test-TextSink).
        # Au premier passage ambigu (guillemet non fermé ou non littéral, heredoc non cité, here-string
        # refusée, commentaire, échappement autre qu'un caractère de chemin, backtick, --%, guillemet
        # typographique), tout le reste de la commande est recopié tel quel : les deux shells pourraient
        # ne plus découper pareil. Dans le doute, le texte reste visible (au pire, un refus de trop).
        # --% (pwsh) passe la suite telle quelle à git : il est remplacé par une espace, et la suite reste visible.
        $bodyAndTitle = '-b', '--body', '-t', '--title'
        $search = '-S', '--search'
        $textOptions = @{
            'git commit' = '-m', '--message', '--trailer'; 'git commit-tree' = @('-m'); 'git tag' = '-m', '--message'
            'git merge' = '-m', '--message'; 'git stash' = '-m', '--message'; 'git notes' = '-m', '--message'
            'git log' = '-S', '-G', '--grep'; 'git grep' = @('-e')
            'gh pr create' = $bodyAndTitle; 'gh pr edit' = $bodyAndTitle; 'gh pr comment' = '-b', '--body'; 'gh pr review' = '-b', '--body'
            'gh pr close' = '-c', '--comment'; 'gh pr merge' = '-b', '--body', '-t', '--subject'; 'gh pr list' = $search
            'gh issue create' = $bodyAndTitle; 'gh issue edit' = $bodyAndTitle; 'gh issue comment' = '-b', '--body'
            'gh issue close' = '-c', '--comment'; 'gh issue list' = $search
            'gh release create' = '-n', '--notes', '-t', '--title'; 'gh release edit' = '-n', '--notes', '-t', '--title'
            'merge-pr.ps1' = @('-Subject'); 'text-file' = '-Value', '-InputObject'
        }
        $textName = '(?:\w+:)?(?!\w*context)\w*(?:body|comment|content|message|msg|notes|report|review|subject|text|title)\w*'
        $textFile = '\.(?:md|markdown|txt)$'

        # Le texte de la commande, en morceaux dans l'ordre (Pieces), et ses commandes, chacune avec ses mots.
        function Split-Command([string] $s) {
            $smart = '[\u2018-\u201F]'
            # Les caractères à examiner un par un. La boucle lit la chaîne par ses propres méthodes : passer une longue
            # chaîne en argument d'une méthode .NET coûte environ 2 ms par appel sous Windows, d'où ce découpage.
            $special = [char[]] (@(0x09..0x0D) + @(0x2018..0x201F) + @([int[]][char[]] ' ;&|(){}''"\`#$<@-'))
            $heredoc = [regex] '\G<<-?[ \t]*([''"])(\w+)\1(?=[\s;|&)<>]|$)'
            $catHeredoc = [regex] '\G(?<q>"?)\$\(cat <<''(?<d>\w+)''\r?\n(?:(?!\k<d>\r?\n)[^\n]*\n)*\k<d>\r?\n\)\k<q>'
            $pieces = [Collections.Generic.List[hashtable]]::new()
            $commands = [Collections.Generic.List[hashtable]]::new()
            $docs = [Collections.Generic.Queue[hashtable]]::new()
            $groups = [Collections.Generic.Stack[hashtable]]::new()
            $st = @{ Plain = [Text.StringBuilder]::new(); Command = $null; Word = $null; Group = $null }
            # ( ou { ouvre un groupe. Après un mot (iex (…), $(…)), sa sortie va à ce mot : son texte reste visible.
            $openGroup = { param([bool] $fed) $groups.Push(@{ From = $commands.Count; Fed = $fed }) }
            $closeGroup = {
                if ($groups.Count) {
                    $st.Group = $groups.Pop()
                    if ($st.Group.Fed) { for ($k = $st.Group.From; $k -lt $commands.Count; $k++) { $commands[$k].Rest = $true } }
                }
            }
            $flush = { if ($st.Plain.Length) { $pieces.Add(@{ Raw = $st.Plain.ToString(); Mask = $null; Hide = $false }); [void] $st.Plain.Clear() } }
            $open = {
                if ($null -eq $st.Command) {
                    $st.Command = @{ Words = [Collections.Generic.List[hashtable]]::new(); Docs = [Collections.Generic.List[hashtable]]::new(); Names = @(); Piped = $false; Rest = $false }
                    $commands.Add($st.Command)
                }
            }
            $word = {
                & $open
                if ($null -eq $st.Word) {
                    $st.Word = @{ Text = ''; Lead = ''; Parts = [Collections.Generic.List[hashtable]]::new() }
                    $st.Command.Words.Add($st.Word)
                }
            }
            # Texte hors chaîne, dans un mot. Lead : ce qui précède la première chaîne du mot.
            $plain = {
                param([string] $t)
                [void] $st.Plain.Append($t); & $word
                $st.Word.Text += $t
                if (-not $st.Word.Parts.Count) { $st.Word.Lead += $t }
            }
            # Texte hors chaîne, entre deux mots, et éventuellement entre deux commandes.
            $between = {
                param([string] $t, [bool] $endsCommand, [bool] $piped)
                [void] $st.Plain.Append($t); $st.Word = $null
                if ($endsCommand -and $null -ne $st.Command) { $st.Command.Piped = $piped; $st.Command = $null }
            }
            # Une chaîne : un morceau qui pourra être retiré, dans le mot en cours.
            $cited = {
                param([string] $rawText, [string] $text)
                & $flush; & $word
                $part = @{ Raw = $rawText; Mask = "''"; Hide = $false }
                $pieces.Add($part); $st.Word.Parts.Add($part); $st.Word.Text += $text
            }
            $i = 0; $n = $s.Length
            while ($i -lt $n) {
                $next = $s.IndexOfAny($special, $i); if ($next -lt 0) { $next = $n }
                if ($next -gt $i) { & $plain $s.Substring($i, $next - $i); $i = $next; continue }
                $c = [string] $s[$i]
                $head = $s.Substring($i, [Math]::Min(3, $n - $i))
                $rest = $false
                if ($c -eq "`n") {
                    & $between $c $true $false; $i++; & $flush
                    # Corps des heredocs cités ouverts sur la ligne qui se termine : jusqu'à leur ligne de fin.
                    while ($docs.Count) {
                        $doc = $docs.Dequeue(); $from = $i
                        while ($i -lt $n) {
                            $end = $s.IndexOf("`n", $i); if ($end -lt 0) { $end = $n }
                            $line = $s.Substring($i, $end - $i).TrimEnd("`r").TrimStart("`t")
                            $i = [Math]::Min($end + 1, $n)
                            if ($line -ceq $doc.Delim) { break }
                        }
                        $piece = @{ Raw = $s.Substring($from, $i - $from); Mask = "''`n"; Hide = $false }
                        $pieces.Add($piece); $doc.Command.Docs.Add($piece)
                    }
                    continue
                }
                elseif ([char]::IsWhiteSpace($s[$i])) { & $between $c $false $false; $i++; continue }
                # 2>&1, >&2, &>x : une redirection, pas la fin de la commande.
                elseif ($c -eq '&' -and (($i -gt 0 -and $s[$i - 1] -eq '>') -or ($i + 1 -lt $n -and $s[$i + 1] -eq '>'))) { & $plain $c; $i++; continue }
                elseif ($c -in ';', '&') { & $between $c $true $false; $i++; continue }
                elseif ($c -eq '(') { & $openGroup ($null -ne $st.Command); & $between $c $true $false; $i++; continue }
                elseif ($c -eq ')') { & $between $c $true $false; & $closeGroup; $i++; continue }
                elseif ($c -eq '|') {
                    if ($i + 1 -lt $n -and $s[$i + 1] -eq '|') { & $between '||' $true $false; $i += 2; continue }
                    # Sans commande en cours, le tube prend la sortie de ce qui précède : un groupe (…) | x, ou la ligne d'avant (⏎| x, pwsh 7).
                    # Une redirection placée entre les deux ((…) 2>&1 | x) ne change rien : elle est lue comme une commande.
                    if (($null -eq $st.Command -or ($st.Command.Words.Count -and $st.Command.Words[0].Text -match '^[\d*]*&?[<>]')) -and $commands.Count) {
                        $from = if ($null -ne $st.Group) { $st.Group.From } else { $commands.Count - 1 }
                        for ($k = $from; $k -lt $commands.Count; $k++) { $commands[$k].Piped = $true }
                    }
                    & $between $c $true $true; $i++; continue
                }
                elseif ($c -eq '{' -or $c -eq '}') {
                    # Dans un mot, c'est une partie du mot : HEAD^{tree}, stash@{0}, ${x}.
                    $after = $i + 1 -ge $n -or [char]::IsWhiteSpace($s[$i + 1])
                    $inside = $null -ne $st.Word -and (($c -eq '{' -and -not $after) -or ($c -eq '}' -and $st.Word.Text.Contains('{')))
                    if ($inside) { & $plain $c }
                    elseif ($c -eq '{') { & $openGroup $false; & $between $c $true $false }
                    else { & $between $c $true $false; & $closeGroup }
                    $i++; continue
                }
                elseif ($c -eq '\') {
                    if ($i + 1 -lt $n -and $s[$i + 1] -match '[\w./:-]') { & $plain $s.Substring($i, 2); $i += 2; continue }
                    $rest = $true
                }
                elseif ($c -eq '`' -or $c -match $smart -or $c -eq '#') { $rest = $true }
                elseif ($c -eq '$' -and $i + 1 -lt $n -and ($s[$i + 1] -eq "'" -or $s[$i + 1] -eq '"')) { $rest = $true }
                elseif ($c -eq '$' -and $head -clike '$(*' -and ($m = $catHeredoc.Match($s, $i)).Success) { & $cited $m.Value ''; $i += $m.Length; continue }
                elseif ($c -eq '-' -and $head -ceq '--%') { & $between (' ' + $s.Substring($i + 3).Replace('"', '')) $false $false; $i = $n; break }
                elseif ($c -eq '<' -and $head -clike '<#*') { $rest = $true }
                elseif ($c -eq '<' -and $head -ceq '<<<') { & $plain '<<<'; $i += 3; continue }
                elseif ($c -eq '<' -and $head -clike '<<*') {
                    $m = $heredoc.Match($s, $i)
                    if ($m.Success) {
                        & $open
                        $docs.Enqueue(@{ Delim = $m.Groups[2].Value; Command = $st.Command })
                        & $between $m.Value $false $false; $i += $m.Length; continue
                    }
                    $rest = $true
                }
                elseif ($c -eq '@' -and $i + 2 -lt $n -and ($s[$i + 1] -eq "'" -or $s[$i + 1] -eq '"') -and $s[$i + 2] -match '[\r\n]') {
                    $close = $s.IndexOf("`n'@", $i + 2)
                    $body = if ($s[$i + 1] -eq "'" -and $close -ge 0) { $s.Substring($i + 2, $close - $i - 2) } else { $null }
                    if ($null -ne $body -and $body -notmatch "'" -and $body -notmatch $smart) { & $cited $s.Substring($i, $close + 3 - $i) ''; $i = $close + 3; continue }
                    $rest = $true
                }
                elseif ($c -eq '"' -and $head -ceq '"$(' -and ($m = $catHeredoc.Match($s, $i)).Success) { & $cited $m.Value ''; $i += $m.Length; continue }
                elseif ($c -eq "'" -or $c -eq '"') {
                    $close = $s.IndexOf($c, $i + 1)
                    $content = if ($close -gt $i -and $s.IndexOf("`n", $i, $close - $i) -lt 0) { $s.Substring($i + 1, $close - $i - 1) } else { $null }
                    if ($null -ne $content -and $content -notmatch $smart -and ($c -eq "'" -or ($content -notmatch '[$`]' -and $content -notmatch '\\(?![\w./:-])'))) {
                        & $cited $s.Substring($i, $close + 1 - $i) $content; $i = $close + 1; continue
                    }
                    $rest = $true
                }
                else { & $plain $c; $i++; continue }
                if ($rest) {
                    if ($null -ne $st.Command) { $st.Command.Rest = $true }
                    [void] $st.Plain.Append($s, $i, $n - $i); break
                }
            }
            & $flush
            foreach ($command in $commands) { $command.Names = @(foreach ($w in $command.Words) { $w.Text }) }
            @{ Pieces = $pieces; Commands = $commands }
        }
        # Le programme d'une commande, et sa sous-commande : la clé de $textOptions. Ce qui le précède sans
        # changer l'analyse est sauté ($r = git…, if git…, X=1 git…, time git…), et un chemin vers lui vaut lui.
        function Get-Program([string[]] $w) {
            $k = 0
            while ($k -lt $w.Count) {
                if ($w[$k] -cin 'if', 'then', 'elif', 'else', 'do', 'while', 'until', 'time', 'env', '!' -or $w[$k] -match '^\w+=') { $k++ }
                elseif ($k + 1 -lt $w.Count -and $w[$k + 1] -in '=', '+=' -and $w[$k] -match '^(?:\[[^\]]+\])?\$[\w:]+$') { $k += 2 }
                else { break }
            }
            if ($k -ge $w.Count) { return $null }
            $name = ($w[$k] -split '[\\/]')[-1]
            $after = @(if ($k + 1 -lt $w.Count) { $w[($k + 1)..($w.Count - 1)] })
            if ($name -imatch '^git(\.exe)?$') {
                $j = 0
                while ($j -lt $after.Count -and $after[$j] -match '^-') {
                    $j += if ($after[$j] -cin '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--config-env', '--super-prefix') { 2 } else { 1 }
                }
                return "git $(if ($j -lt $after.Count) { $after[$j] })"
            }
            if ($name -imatch '^gh(\.exe)?$') {
                $names = @(); $j = 0
                while ($j -lt $after.Count -and $names.Count -lt 2) {
                    if ($after[$j] -cin '-R', '--repo') { $j += 2 }
                    elseif ($after[$j] -match '^-') { $j++ }
                    else { $names += $after[$j]; $j++ }
                }
                return "gh $($names -join ' ')"
            }
            if ($name -ieq 'merge-pr.ps1') { return 'merge-pr.ps1' }
            if ($name -imatch '^(pwsh|powershell)(\.exe)?$') {
                # pwsh -File <script> : ce qui suit n'est pas exécuté par pwsh. Pas -Command, ni une commande encodée.
                for ($j = 0; $j -lt $after.Count - 1; $j++) {
                    if ($after[$j] -imatch '^(--?|/)(c\w*|e|ec|en\w*)$') { return $null }
                    if ($after[$j] -imatch '^-f(ile)?$') { return $(if (($after[$j + 1] -split '[\\/]')[-1] -ieq 'merge-pr.ps1') { 'merge-pr.ps1' }) }
                }
                return $null
            }
            if ($name -in 'Set-Content', 'Add-Content', 'Out-File') {
                # Le fichier écrit, et lui seul : pas la valeur, ni plusieurs cibles. Une autre option peut prendre une
                # valeur (-Exclude x.md) ou rendre le texte (-PassThru) : la commande n'est alors pas vue comme un texte.
                $target = $null
                for ($j = 0; $j -lt $after.Count; $j++) {
                    if ($after[$j] -imatch '^-(path|literalpath|filepath)$') { $target = if ($j + 1 -lt $after.Count) { $after[$j + 1] }; $j++ }
                    elseif ($after[$j] -imatch '^-(value|inputobject|encoding|erroraction|ea)$') { $j++ }
                    elseif ($after[$j] -notmatch '^-') {
                        if ($after[$j] -match '^,') { return $null }
                        if ($null -eq $target) { $target = $after[$j] }
                    }
                    elseif ($after[$j] -inotmatch '^-(value|inputobject|encoding|erroraction|ea):|^-(force|nonewline|append|noclobber)$') { return $null }
                }
                if ($target -imatch $textFile -and $target -notmatch ',') { return 'text-file' }
            }
            $null
        }
        # La commande écrit-elle ce qu'elle reçoit dans un texte de git ou de gh (-F -), ou dans un fichier de texte ?
        function Test-TextSink($command) {
            $w = $command.Names
            if ($command.Piped -or $command.Rest -or -not $w.Count) { return $false }
            $program = Get-Program $w
            if ($program -eq 'text-file') { return $true }
            if ($program -cmatch '^(git (commit|commit-tree|tag|merge|notes)|gh (pr|issue) (create|edit|comment|review)|gh release (create|edit))$') {
                return ($w -join ' ') -cmatch '(^| )(-F|--file|--body-file|--notes-file)( |=)-( |$)'
            }
            if ($w[0] -ceq 'cat') { return (($w.Count -eq 3 -and $w[1] -in '>', '>>') -or ($w.Count -eq 2 -and $w[1] -match '^>')) -and $w[-1] -imatch $textFile }
            if ($w[0] -ceq 'tee') { return ($w.Count -eq 2 -or ($w.Count -eq 3 -and $w[1] -ceq '-a')) -and $w[-1] -imatch $textFile }
            $false
        }
        function Hide-CarriedText($commands) {
            for ($c = 0; $c -lt $commands.Count; $c++) {
                $command = $commands[$c]; $w = $command.Names; $words = $command.Words
                $next = if ($command.Piped -and $c + 1 -lt $commands.Count) { $commands[$c + 1] }
                $hide = @()
                # $body = '…', $body='…', msg='…' : seuls dans leur commande, et sans tube.
                if (-not $command.Piped -and -not $command.Rest) {
                    if ($w.Count -eq 3 -and $w[1] -in '=', '+=' -and $w[0] -match "^(?:\[[^\]]+\])?\`$$textName`$") { $hide += $words[2] }
                    elseif ($w.Count -eq 1 -and $words[0].Lead -match "^(?:\[[^\]]+\])?\`$?$textName\+?=`$") { $hide += $words[0] }
                }
                # '…' | git commit -F -, @'…'@ | Set-Content x.md
                if ($w.Count -eq 1 -and $words[0].Lead -eq '' -and $null -ne $next -and (Test-TextSink $next)) { $hide += $words[0] }
                # La valeur d'une option de texte : séparée de l'option (-m '…'), ou collée (--body='…', -Subject:'…', -S'…').
                $program = Get-Program $w
                if ($program -and $textOptions.ContainsKey($program) -and -not ($program -eq 'text-file' -and ($command.Piped -or $command.Rest))) {
                    $options = $textOptions[$program]
                    $anyCase = $program -in 'merge-pr.ps1', 'text-file'
                    $isOption = { param([string] $t) if ($anyCase) { $options -icontains $t } else { $options -ccontains $t } }
                    for ($k = 1; $k -lt $words.Count; $k++) {
                        $lead = $words[$k].Lead
                        if ((-not $words[$k - 1].Parts.Count -and (& $isOption $w[$k - 1])) -or ($lead -and ((& $isOption $lead) -or (& $isOption ($lead -replace '[=:]$', ''))))) { $hide += $words[$k] }
                    }
                }
                foreach ($h in $hide) { foreach ($part in $h.Parts) { $part.Hide = $true } }
                # Un heredoc n'est retiré que si sa commande, ou le tube cat <<'EOF' | …, l'envoie vers un texte.
                if ((Test-TextSink $command) -or ($w.Count -eq 1 -and $w[0] -ceq 'cat' -and $null -ne $next -and (Test-TextSink $next))) {
                    foreach ($doc in $command.Docs) { $doc.Hide = $true }
                }
            }
        }
        $split = Split-Command $raw
        Hide-CarriedText $split.Commands
        # Les guillemets se lisent comme des espaces après la normalisation : `bash -c 'git add -A'` se lit comme
        # `git add -A`, et `git -C "a b" commit -a` garde son dossier d'un seul tenant le temps de le retirer.
        # >& et &> sont des redirections : leur & ne coupe pas un motif.
        $unredirect = { param([string] $t) $t.Replace('>&', '> ').Replace('&>', ' >') }
        $render = {
            param([bool] $allCited, [bool] $ansiC)
            $text = -join @(foreach ($p in $split.Pieces) { if ($p.Hide -or ($allCited -and $null -ne $p.Mask)) { $p.Mask } else { $p.Raw } })
            if ($ansiC) { $text = [regex]::Replace($text, '(?<![^\s=(;|&])\$''(?:[^''\\]|\\.)*''', { param($m) $m.Value -replace '\\[nrt]', ' ' }) }
            & $unredirect ((& $normalize $text) -replace '[''"`]', ' ')
        }
        $bare = & $render $false $false
        # La même commande sans aucune chaîne : un ; & ou | cité y arrêterait les motifs, et cacherait une vraie option
        # placée après lui (git add 'R&D.md' .).
        $noText = & $render $true $false
        # Dans $'…', qui commence un mot, \n, \r et \t sont des blancs. Une lecture de plus, jamais à la place des autres :
        # 'a $' peut ressembler à l'ouverture d'un $'…', et y remplacer \n couperait le chemin C:\new qui suit.
        $ansiC = if ($raw.Contains("`$'")) { & $render $false $true } else { '' }
        $forbidden = [ordered]@{
            'git\s+worktree\b'                                   = 'les worktrees sont interdits : on travaille par branches simples.'
            'git\s+rebase\b[^;&|]*\s(-i|--interactive)\b'        = 'le rebase interactif est interdit.'
            'git\s+push\b[^;&|]*(\s--force(-with-lease)?\b|\s-f\b|\s\+\S)' = 'le push forcé est interdit.'
            '--no-verify\b'                                      = 'contourner les hooks Git (--no-verify) est interdit.'
            'git\s+add\b[^;&|]*\s((-A|--all)(?=\s|$|;|&|\||\)|\}|>|\\)|\.(?:[\\/]\.?)*(?=\s|$|;|&|\||\)|\}|>))' = "git add -A / git add . sont interdits : ajouter les fichiers un par un, après les avoir vérifiés."
            'git\s+commit\b[^;&|]*\s(-(?!-)[a-zA-Z]*a|--all\b)' = "git commit -a est interdit : ajouter les fichiers un par un."
        }
        foreach ($pattern in $forbidden.Keys) {
            if ($bare -cmatch $pattern -or $noText -cmatch $pattern -or $ansiC -cmatch $pattern) {
                # Interdit vu seulement dans un texte cité, même d'une chaîne que la règle ne sait pas analyser
                # ("… $x …") : le dire, sinon le motif accuse d'une option absente. La chaîne devient un mot vide le
                # temps de normaliser : git -C "a b" add garde son dossier.
                $withoutStrings = (& $normalize ($raw -replace '(?s)"(?:[^"\\]|\\.)*"|''[^'']*''', "''")) -replace "''", ' '
                $hint = if ($noText -cnotmatch $pattern -or (& $unredirect $withoutStrings) -cnotmatch $pattern) { " Ce texte cité a été lu comme une commande : s'il ne s'exécute pas, l'écrire dans un fichier (--body-file, -F) ou une variable de texte (`$body = …), et chercher dans le dépôt avec l'outil Grep, dans l'historique avec git log -S ou --grep, sur GitHub avec --search." } else { '' }
                return @{ Decision = 'deny'; Reason = $forbidden[$pattern] + $hint }
            }
        }

        # 2. Opérations réservées : classe d'opération → agents autorisés.
        $restricted = Get-Value $config 'restrictedCommands' @{}
        foreach ($pattern in $restricted.Keys) {
            $owners = @($restricted[$pattern])
            if ($cmd -match $pattern -and $owners -notcontains $agent) {
                $reason = if ($owners) { "$who ne peut pas lancer cette commande, réservée à : $($owners -join ', '). Déléguer à l'agent concerné." }
                          else { "cette commande est réservée à l'utilisateur : la lui proposer, sans la lancer." }
                return @{ Decision = 'deny'; Reason = $reason }
            }
        }

        # 2 bis. Le marqueur de revue n'est écrit que par auditor : tout autre agent qui l'écrirait
        # s'auto-approuverait (texte de la commande ou fichier passé par --body-file).
        if ($agent -ne 'auditor' -and $cmd -match '\bgh\b') {
            $text = $cmd
            if ($cmd -match '\s(--body-file|-F)(=|\s+)("(?<f>[^"]+)"|''(?<f>[^'']+)''|(?<f>\S+))') {
                $bodyFile = [IO.Path]::GetFullPath($Matches['f'], $ctx.Cwd)
                if (Test-Path $bodyFile -PathType Leaf) { $text += "`n" + (Get-Content $bodyFile -Raw) }
            }
            if ($text -match '<!--\s*auditor:') {
                return @{ Decision = 'deny'; Reason = "seul l'agent auditor écrit le marqueur de revue (<!-- auditor: … -->)." }
            }
        }

        # 3. Push vers une branche protégée.
        $protected = @(Get-Value $config 'protectedBranches' @())
        if ($protected -and $cmd -match 'git\s+push\b(?<args>[^;&|]*)') {
            # `git push [options] <remote> <refspec>` : sans refspec, c'est la branche courante.
            $positional = @($Matches['args'].Trim() -split '\s+' | Where-Object { $_ -and $_ -notmatch '^-' })
            $branch = if ($positional.Count -ge 2) {
                (($positional[1] -split ':')[-1]) -replace '^\+', '' -replace '^refs/heads/', ''
            }
            else { git -C $gitDir branch --show-current 2>$null }
            if ($protected -contains $branch) {
                return @{ Decision = 'deny'; Reason = "push direct sur '$branch' interdit : passer par une PR." }
            }
        }

        # 4. Message de commit avec le numéro d'issue.
        if ((Get-Value $config 'requireIssueRef' $false) -and $cmd -match 'git\s+commit\b') {
            if ($cmd -notmatch '\s(-m|--message)[\s=]' -and $cmd -notmatch '\s(-F|--file)[\s=]') {
                return @{ Decision = 'deny'; Reason = 'commit sans message en ligne de commande : utiliser -m "type(scope): description (#n)".' }
            }
            # Message en ligne (-m), lu sur l'entrée standard (-F - avec un heredoc : il est
            # dans la commande elle-même), ou dans un fichier (-F <fichier>).
            $message = $cmd
            if ($cmd -match '\s(-F|--file)[\s=]+"?([^"\s]+)' -and $Matches[2] -ne '-') {
                $file = [IO.Path]::GetFullPath($Matches[2], $ctx.Cwd)
                $message = if (Test-Path $file) { Get-Content $file -Raw } else { '' }
            }
            if ($message -notmatch '#\d+') {
                return @{ Decision = 'deny'; Reason = 'le message de commit doit citer le numéro d''issue : "type(scope): description (#n)".' }
            }
        }

        # 5. Fusion d'une PR : jamais par `gh pr merge` direct. Une ligne de commande ne se laisse pas
        # analyser de façon fiable (échappements, commandes enchaînées, --repo…) : la fusion passe par
        # .harness/tools/merge-pr.ps1, aux paramètres typés, qui vérifie la revue auditor et fusionne
        # le commit revu et lui seul (--match-head-commit). Ce script est réservé à git-ops (§2).
        if ($cmd -match '\bgh(\s+(-R|--repo)(=|\s+)\S+|\s+--?[\w-]+)*\s+pr\s+merge\b') {
            return @{ Decision = 'deny'; Reason = "pas de 'gh pr merge' direct : fusionner avec pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr <n> -Subject `"type(scope): description (#n)`" (-Strategy merge pour une release ou un hotfix)." }
        }
    }
}

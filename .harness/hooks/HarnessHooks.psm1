#Requires -Version 7.4
# Bibliothèque des hooks du harness : lecture de l'entrée, chargement des règles,
# réponses au format attendu par Claude Code. Voir docs du harness (README).

Set-StrictMode -Version Latest

# Claude Code envoie du JSON en UTF-8 : sans ça, pwsh le lit avec la page de code
# de la console et les accents sont corrompus (spike phase 1).
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$script:ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

function Get-HarnessProjectDir { $script:ProjectDir }

function Get-HarnessConfig {
    $path = Join-Path $script:ProjectDir '.harness' 'harness.json'
    Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
}

function Get-HarnessProfile([hashtable] $Config) {
    if ($env:HARNESS_HOOK_PROFILE) { return $env:HARNESS_HOOK_PROFILE }
    if ($Config.ContainsKey('profile')) { return $Config.profile }
    'standard'
}

function Get-Value([hashtable] $Table, [string] $Key, $Default = $null) {
    # Accès tolérant aux clés absentes (StrictMode).
    if ($null -ne $Table -and $Table.ContainsKey($Key)) { return $Table[$Key] }
    $Default
}

function ConvertTo-RelativePath([string] $Path) {
    # Chemin relatif au projet, séparateurs `/`, pour comparer aux motifs de la config.
    if (-not $Path) { return '' }
    $full = [IO.Path]::GetFullPath($Path, $script:ProjectDir)
    $rel = [IO.Path]::GetRelativePath($script:ProjectDir, $full)
    $rel -replace '\\', '/'
}

function Test-AnyMatch([string] $Text, [object[]] $Patterns) {
    foreach ($p in $Patterns) { if ($Text -match $p) { return $true } }
    $false
}

function New-HookContext([hashtable] $HookInput, [string] $EventName) {
    $config = Get-HarnessConfig
    @{
        Input      = $HookInput
        Event      = $EventName
        ToolName   = Get-Value $HookInput 'tool_name' ''
        ToolInput  = Get-Value $HookInput 'tool_input' @{}
        # Absent dans la session principale, présent dans un subagent (spike phase 1).
        AgentType  = Get-Value $HookInput 'agent_type' ''
        SessionId  = Get-Value $HookInput 'session_id' 'sans-session'
        Cwd        = Get-Value $HookInput 'cwd' $script:ProjectDir
        Config     = $config
        Profile    = Get-HarnessProfile $config
        ProjectDir = $script:ProjectDir
    }
}

function Get-HarnessRules([string] $EventName, [hashtable] $Context) {
    # Règles rangées par événement : on ne charge que celles de l'événement courant.
    # Cœur : .harness/hooks/rules/<Événement>/*.ps1 ; modules : .harness/modules/<nom>/rules/<Événement>/*.ps1
    $files = @(Get-ChildItem (Join-Path $PSScriptRoot 'rules' $EventName) -Filter *.ps1 -ErrorAction SilentlyContinue)
    $files += @(Get-ChildItem (Join-Path $script:ProjectDir '.harness' 'modules' '*' 'rules' $EventName) -Filter *.ps1 -ErrorAction SilentlyContinue)
    $disabled = @(($env:HARNESS_DISABLED_HOOKS ?? '') -split ',' | ForEach-Object Trim | Where-Object { $_ })

    foreach ($file in $files | Sort-Object Name) {
        $rule = & $file.FullName
        if ($rule.Event -ne $EventName) { continue }
        if ($disabled -contains $rule.Name) { continue }
        if ($rule.Profiles -notcontains $Context.Profile) { continue }
        if ($rule.ContainsKey('Tools') -and $rule.Tools -and $Context.ToolName -notmatch "^($($rule.Tools))$") { continue }
        $rule
    }
}

function Write-HookJson([hashtable] $Object) {
    [Console]::Out.Write(($Object | ConvertTo-Json -Depth 10 -Compress))
}

function Write-HookDecision([string] $EventName, [string] $Decision, [string] $Reason) {
    switch ($EventName) {
        'PreToolUse' {
            if ($Decision -eq 'deny') {
                Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } }
            }
            else {
                Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $Reason } }
            }
        }
        { $_ -in 'UserPromptSubmit', 'Stop', 'SubagentStop' } {
            if ($Decision -in 'deny', 'block') { Write-HookJson @{ decision = 'block'; reason = $Reason } }
            elseif ($EventName -eq 'UserPromptSubmit') {
                Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $Reason } }
            }
        }
        default {
            # PostToolUse, SessionStart : informations ajoutées au contexte de l'agent.
            Write-HookJson @{ hookSpecificOutput = @{ hookEventName = $EventName; additionalContext = $Reason } }
        }
    }
}

function Invoke-HarnessEvent([string] $EventName) {
    $guardEvents = 'PreToolUse', 'UserPromptSubmit'
    try {
        $raw = [Console]::In.ReadToEnd()
        $hookInput = $raw | ConvertFrom-Json -AsHashtable -Depth 64
        $context = New-HookContext $hookInput $EventName
        $notes = [System.Collections.Generic.List[string]]::new()

        foreach ($rule in @(Get-HarnessRules $EventName $context)) {
            try {
                $result = & $rule.Run $context
            }
            catch {
                # Une garde en erreur refuse (échec fermé) ; une règle d'information est ignorée.
                if ($rule.Kind -eq 'guard') {
                    Write-HookDecision $EventName 'deny' "harness/$($rule.Name) : erreur interne ($($_.Exception.Message)). Refus par sécurité."
                    return
                }
                continue
            }
            if (-not $result) { continue }
            if ($result.Decision -in 'deny', 'block') {
                Write-HookDecision $EventName $result.Decision "harness/$($rule.Name) : $($result.Reason)"
                return
            }
            $notes.Add("harness/$($rule.Name) : $($result.Reason)")
        }
        if ($notes.Count -gt 0) { Write-HookDecision $EventName 'context' ($notes -join "`n") }
    }
    catch {
        if ($EventName -in $guardEvents) {
            Write-HookDecision $EventName 'deny' "harness : entrée de hook illisible ou configuration absente ($($_.Exception.Message)). Refus par sécurité."
        }
        else {
            [Console]::Error.WriteLine("harness : $($_.Exception.Message)")
        }
    }
}

function Get-HarnessStatePath([string] $SessionId, [string] $Name) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'claude-harness'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Join-Path $dir "$SessionId.$Name.json"
}

function Get-StringHash([string] $Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 16)
}

Export-ModuleMember -Function Invoke-HarnessEvent, Get-HarnessProjectDir, Get-Value, ConvertTo-RelativePath,
    Test-AnyMatch, Get-HarnessStatePath, Get-StringHash

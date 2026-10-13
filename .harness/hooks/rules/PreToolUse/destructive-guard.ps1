# destructive-guard : une commande destructive est refusée au premier essai.
# L'agent doit d'abord exposer ce qui sera touché et comment revenir en arrière ;
# la même commande, relancée dans la même session, passe.
@{
    Name     = 'destructive-guard'
    Event    = 'PreToolUse'
    Tools    = 'Bash|PowerShell'
    Profiles = 'standard', 'strict'
    Kind     = 'guard'
    Run      = {
        param($ctx)
        $cmd = Get-Value $ctx.ToolInput 'command' ''
        $patterns = @(Get-Value $ctx.Config 'destructivePatterns' @())
        if (-not (Test-AnyMatch $cmd $patterns)) { return }

        $state = Get-HarnessStatePath $ctx.SessionId 'destructive'
        $seen = if (Test-Path $state) { @(Get-Content $state -Raw | ConvertFrom-Json) } else { @() }
        $key = Get-StringHash $cmd.Trim()
        if ($seen -contains $key) { return }

        ConvertTo-Json -InputObject @($seen + $key) -Compress | Set-Content $state
        @{ Decision = 'deny'; Reason = @'
commande destructive. Avant de la relancer à l'identique :
1. liste précisément ce qui sera supprimé ou modifié ;
2. donne en une ligne la procédure de retour arrière ;
3. cite mot pour mot la demande de l'utilisateur qui justifie cette commande.
Si la demande n'est pas explicite, demande d'abord à l'utilisateur.
'@ }
    }
}

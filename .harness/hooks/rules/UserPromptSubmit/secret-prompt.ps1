# secret-prompt : bloque un message qui contient un jeton ou une clé privée.
# Le message bloqué n'entre pas dans le contexte de l'agent.
@{
    Name     = 'secret-prompt'
    Event    = 'UserPromptSubmit'
    Profiles = 'minimal', 'standard', 'strict'
    Kind     = 'guard'
    Run      = {
        param($ctx)
        $prompt = Get-Value $ctx.Input 'prompt' ''
        $tokens = Get-Value $ctx.Config 'secretTokens' @{}
        foreach ($name in $tokens.Keys) {
            if ($prompt -cmatch $tokens[$name]) {
                return @{ Decision = 'block'; Reason = "le message contient ce qui ressemble à un secret ($name). Il n'a pas été transmis. Si ce secret est réel, révoque-le, puis reformule sans lui." }
            }
        }
    }
}

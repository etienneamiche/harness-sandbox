# model-guard : seuls les subagents de la liste blanche, avec leur modèle imposé.
# Un paramètre `model` passé à l'appel écrase le modèle déclaré par l'agent
# (vérifié au spike phase 1) : il est donc toujours refusé.
@{
    Name     = 'model-guard'
    Event    = 'PreToolUse'
    Tools    = 'Agent|Task'
    Profiles = 'minimal', 'standard', 'strict'
    Kind     = 'guard'
    Run      = {
        param($ctx)
        $type = Get-Value $ctx.ToolInput 'subagent_type' ''
        $model = Get-Value $ctx.ToolInput 'model' ''
        $allowed = @((Get-Value $ctx.Config 'allowedAgents' @{}).Keys)

        if ($model) {
            return @{ Decision = 'deny'; Reason = "le paramètre model ('$model') est interdit : le modèle est imposé par la définition de l'agent '$type'. Rappeler l'agent sans model." }
        }
        if (-not $type -or $allowed -notcontains $type) {
            return @{ Decision = 'deny'; Reason = "l'agent '$type' n'est pas autorisé. Agents disponibles : $(($allowed | Sort-Object) -join ', ')." }
        }
    }
}

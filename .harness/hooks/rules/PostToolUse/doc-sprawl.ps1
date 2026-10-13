# doc-sprawl : signale un fichier Markdown écrit hors des emplacements prévus. Inspiré d'ECC.
@{
    Name     = 'doc-sprawl'
    Event    = 'PostToolUse'
    Tools    = 'Write'
    Profiles = 'standard', 'strict'
    Kind     = 'info'
    Run      = {
        param($ctx)
        $rel = ConvertTo-RelativePath (Get-Value $ctx.ToolInput 'file_path' '')
        if ($rel -notmatch '\.md$') { return }
        if (Test-AnyMatch $rel @(Get-Value $ctx.Config 'docAllow' @())) { return }
        @{ Decision = 'context'; Reason = "'$rel' est un document écrit hors de docs/. La doc d'un projet vit dans docs/ (ou README, AGENTS, ARCHITECTURE, ROADMAP, CHANGELOG). Le déplacer, ou le supprimer s'il ne sert qu'à cette tâche." }
    }
}

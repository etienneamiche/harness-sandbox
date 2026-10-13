# structural-watch : un fichier venu d'un template a été modifié dans le projet.
# La modification profiterait peut-être à tous les projets : la remonter par /upstream.
@{
    Name     = 'structural-watch'
    Event    = 'PostToolUse'
    Tools    = 'Edit|Write|MultiEdit'
    Profiles = 'standard', 'strict'
    Kind     = 'info'
    Run      = {
        param($ctx)
        $list = Join-Path $ctx.ProjectDir '.harness' 'structural.txt'
        if (-not (Test-Path $list)) { return }
        $patterns = @(Get-Content $list | Where-Object { $_ -and $_ -notmatch '^\s*#' })
        $rel = ConvertTo-RelativePath (Get-Value $ctx.ToolInput 'file_path' '')
        if (Test-AnyMatch $rel $patterns) {
            @{ Decision = 'context'; Reason = "'$rel' est un bloc structurel venu d'un template. Si la modification vaut pour tous les projets, proposer à l'utilisateur de la remonter avec /upstream." }
        }
    }
}

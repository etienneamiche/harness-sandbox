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
        # Motifs du cœur (.harness/structural.txt) et des modules (module.json → structural).
        $list = Join-Path $ctx.ProjectDir '.harness' 'structural.txt'
        $patterns = @(if (Test-Path $list) { Get-Content $list | Where-Object { $_ -and $_ -notmatch '^\s*#' } })
        foreach ($manifest in Get-ChildItem (Join-Path $ctx.ProjectDir '.harness' 'modules' '*' 'module.json') -ErrorAction SilentlyContinue) {
            $patterns += @((Get-Content $manifest.FullName -Raw | ConvertFrom-Json -AsHashtable)['structural'])
        }
        $patterns = @($patterns | Where-Object { $_ })
        $rel = ConvertTo-RelativePath (Get-Value $ctx.ToolInput 'file_path' '')
        if (Test-AnyMatch $rel $patterns) {
            @{ Decision = 'context'; Reason = "'$rel' est un bloc structurel venu d'un template. Si la modification vaut pour tous les projets, proposer à l'utilisateur de la remonter avec /upstream." }
        }
    }
}

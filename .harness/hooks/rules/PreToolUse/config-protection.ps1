# config-protection : un agent ne modifie pas les fichiers qui encadrent son travail
# (configs de lint et de format, harness, CI, .gitignore, SOPS). Inspiré d'ECC.
@{
    Name     = 'config-protection'
    Event    = 'PreToolUse'
    Tools    = 'Edit|Write|MultiEdit|NotebookEdit'
    Profiles = 'standard', 'strict'
    Kind     = 'guard'
    Run      = {
        param($ctx)
        $path = Get-Value $ctx.ToolInput 'file_path' (Get-Value $ctx.ToolInput 'notebook_path' '')
        $rel = ConvertTo-RelativePath $path
        if (Test-AnyMatch $rel @(Get-Value $ctx.Config 'protectedPaths' @())) {
            @{ Decision = 'deny'; Reason = "'$rel' est protégé par le harness : un agent ne modifie pas les règles qui encadrent son travail. Si la modification est nécessaire, la proposer à l'utilisateur (ou via /upstream pour un fichier venu d'un template)." }
        }
    }
}

# secret-guard : un agent ne lit jamais un secret en clair (cadrage §17, couche 3).
# Au mieux de ses moyens : une commande détournée peut passer. Les vraies garanties
# sont l'absence de secret en clair sur le disque et gitleaks au commit.
# L'outil Read n'est pas branché sur ce hook (latence : c'est l'outil le plus appelé) :
# les règles `permissions.deny` de settings.json le couvrent nativement. La règle reste
# capable de le traiter, pour les autotests et si on rebranche Read.
@{
    Name     = 'secret-guard'
    Event    = 'PreToolUse'
    Tools    = 'Read|Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell'
    Profiles = 'minimal', 'standard', 'strict'
    Kind     = 'guard'
    Run      = {
        param($ctx)
        $config = $ctx.Config
        $secretPaths = @(Get-Value $config 'secretPaths' @())
        $allowPaths = @(Get-Value $config 'secretPathsAllow' @())

        if ($ctx.ToolName -in 'Bash', 'PowerShell') {
            $cmd = Get-Value $ctx.ToolInput 'command' ''
            foreach ($p in @(Get-Value $config 'secretCommands' @())) {
                if ($cmd -match $p) {
                    return @{ Decision = 'deny'; Reason = "cette commande exposerait un secret en clair. Les secrets s'injectent dans le processus qui en a besoin (sops exec-env, launch.ps1), jamais dans la sortie d'une commande." }
                }
            }
            # Le moindre jeton de la commande qui désigne un fichier secret suffit.
            foreach ($token in $cmd -split '[\s"''`;|&<>()]+' | Where-Object { $_ }) {
                $t = $token -replace '\\', '/'
                if ((Test-AnyMatch $t $secretPaths) -and -not (Test-AnyMatch $t $allowPaths)) {
                    return @{ Decision = 'deny'; Reason = "la commande touche un fichier secret ('$token'). Un agent ne lit ni ne manipule les secrets : demander à l'utilisateur." }
                }
            }
            return
        }

        $path = Get-Value $ctx.ToolInput 'file_path' (Get-Value $ctx.ToolInput 'notebook_path' '')
        $full = ($path -replace '\\', '/')
        if ((Test-AnyMatch $full $secretPaths) -and -not (Test-AnyMatch $full $allowPaths)) {
            @{ Decision = 'deny'; Reason = "'$path' est un fichier secret : un agent ne le lit ni ne l'écrit. Demander à l'utilisateur." }
        }
    }
}

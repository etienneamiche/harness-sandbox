#Requires -Version 7.4
# Point d'entrée unique des hooks Claude Code : `dispatch.ps1 <Événement>`.
# Un seul processus par événement (spike phase 1 : ~250 ms par lancement de pwsh,
# et les hooks d'un même événement tournent en parallèle).
param([Parameter(Mandatory)] [string] $EventName)

Import-Module (Join-Path $PSScriptRoot 'HarnessHooks.psm1') -Force
Invoke-HarnessEvent $EventName
exit 0

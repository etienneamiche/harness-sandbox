# 0001. Minuteur Pomodoro en PowerShell

## Contexte

Le développeur du sandbox veut lancer depuis un terminal une séance de concentration de N minutes, voir le temps restant et être prévenu à la fin (issue #16). L'outil est local, sans serveur ni interface graphique. Sa logique dépend du temps qui passe : il faut pouvoir la tester sans attendre. Les issues #17 (journal des séances) et #18 (résumé de la semaine) s'appuieront dessus.

La structure commune d'un dépôt (`frontend/`, `backend/`, `scripts/`…) ne prévoit pas d'emplacement pour un outil applicatif en PowerShell.

## Options envisagées

**Technologie**

- PowerShell 7 sans dépendance d'exécution, testé par Pester.
- Un outil console .NET 10 : démesuré pour un minuteur, et contraire au choix de l'utilisateur.

**Forme**

- Un module `Pomodoro.psm1` et un point d'entrée mince `pomodoro.ps1`.
- Un script unique : les paramètres de test seraient exposés dans la commande utilisateur, et il faudrait le transformer en module pour #18.

**Interruption**

- Laisser agir le Ctrl+C natif et ne rendre un objet qu'à l'échéance.
- Intercepter Ctrl+C et rendre un objet avec un `Status` : une quarantaine de lignes et des cas de console en plus, sans utilité pour #17 ni #18.

## Décision

1. **PowerShell 7 sans dépendance** : `#Requires -Version 7.4`, aucun `Install-Module`, aucun module importé en dehors du sien. Pester 5.5 ou plus ne sert qu'aux tests.
2. **Horloge et attente injectées** : `Start-PomodoroSession` reçoit `-Clock` et `-Wait`, avec `[DateTimeOffset]::Now` et `Start-Sleep` comme valeurs par défaut. Les tests simulent le temps et ne dorment jamais. Le temps restant se calcule depuis l'horloge, jamais en comptant les attentes. Ces paramètres restent hors de la commande utilisateur `pomodoro.ps1`.
3. **Un objet rendu seulement si la séance est allée à son terme** : à l'échéance, un objet ; à l'interruption, un message, aucun objet, et l'exception remonte à l'appelant.
4. **Emplacement** : `src/pomodoro/`.
5. **Conventions non applicables** : les logs JSON, OpenTelemetry et `/healthz` ne s'appliquent pas à un outil local en ligne de commande. Il n'a ni service à superviser ni requête à corréler.

## Conséquences

- #17 n'enregistrera que ce qui est rendu : une séance interrompue ne compte jamais. Une propriété `Status` pourra s'ajouter plus tard sans casser les appelants.
- Les textes affichés sont chargés depuis `fr-FR/Pomodoro.psd1`, en forçant la culture française. Ajouter une langue demandera de rendre ce choix configurable, en plus du fichier de traduction.
- Le code de sortie après un Ctrl+C ne fait pas partie du contrat : un appelant ne peut pas s'en servir pour distinguer une séance interrompue d'une séance terminée.
- « Être prévenu » prend la forme d'un message texte : il reste invisible si l'on travaille dans une autre fenêtre.
- `src/` s'ajoute à la structure commune pour ce dépôt, et il n'y a pas de lint PowerShell tant que le harness n'a pas de module pour ces outils.

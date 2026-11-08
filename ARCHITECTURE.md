# Architecture — .

*À compléter à la création du projet (`/start-project`), puis tenir à jour.*

## Vue d'ensemble

## Composants

### pomodoro

**Rôle** : minuteur de séance de concentration en ligne de commande (1 à 180 minutes, 25 par défaut). Il affiche le temps restant sur une seule ligne et annonce la fin de la séance.

**Fichiers** (`src/pomodoro/`) :

| Fichier | Rôle |
|---|---|
| `pomodoro.ps1` | Point d'entrée mince : `-Minutes`, import du module |
| `Pomodoro.psm1` | `Start-PomodoroSession` : la boucle de séance, avec `-Clock` et `-Wait` injectables |
| `fr-FR/Pomodoro.psd1` | Les textes affichés |
| `Pomodoro.Tests.ps1` | Les tests Pester, à horloge simulée |

**Lancement** : `pwsh -NoProfile -File src/pomodoro/pomodoro.ps1 [-Minutes <1-180>]`. Tests : `scripts/test.ps1`.

**Contrat de sortie** :

- Séance menée à son terme : « Séance terminée » s'affiche et un seul objet est rendu, avec `PlannedMinutes` (`[int]`), `StartedAt` et `EndedAt` (`[DateTimeOffset]`). Le script termine avec le code de sortie 0.
- Séance interrompue (Ctrl+C) : « Séance interrompue » s'affiche, aucun objet n'est rendu et l'exception remonte à l'appelant. Le code de sortie n'est pas défini.
- Durée invalide : erreur avant tout démarrage.

Les choix sont consignés dans `docs/adr/0001-minuteur-pomodoro-powershell.md`.

## Données

## Décisions

Les décisions importantes sont consignées dans `docs/adr/`, une par fichier.

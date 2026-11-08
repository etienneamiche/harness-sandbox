# Architecture — .

*À compléter à la création du projet (`/start-project`), puis tenir à jour.*

## Vue d'ensemble

## Composants

### pomodoro

**Rôle** : minuteur de séance de concentration en ligne de commande (1 à 180 minutes, 25 par défaut). Il affiche le temps restant sur une seule ligne et annonce la fin de la séance.

**Fichiers** (`src/pomodoro/`) :

| Fichier | Rôle |
|---|---|
| `pomodoro.ps1` | Point d'entrée mince : `-Minutes`, `-Tag`, `-LogPath`, import du module, enchaînement séance puis journal |
| `Pomodoro.psm1` | `Start-PomodoroSession` : la boucle de séance, avec `-Clock` et `-Wait` injectables. `Add-PomodoroLogEntry` et `Get-PomodoroLog` : l'écriture et la lecture du journal |
| `fr-FR/Pomodoro.psd1` | Les textes affichés |
| `Pomodoro.Tests.ps1` | Les tests Pester, à horloge simulée |

**Lancement** : `pwsh -NoProfile -File src/pomodoro/pomodoro.ps1 [-Minutes <1-180>] [-Tag <étiquette>] [-LogPath <chemin>]`. Tests : `scripts/test.ps1`.

Les tests du minuteur se lancent par `scripts/test.ps1`.

**Contrat de sortie** :

- Séance menée à son terme : « Séance terminée » s'affiche et `Start-PomodoroSession` rend un seul objet, avec `PlannedMinutes` (`[int]`), `StartedAt` et `EndedAt` (`[DateTimeOffset]`). `pomodoro.ps1` le passe au journal et ne rend plus d'objet. Le script termine avec le code de sortie 0.
- Séance interrompue (Ctrl+C) : « Séance interrompue » s'affiche, aucun objet n'est rendu, rien n'est journalisé et l'exception remonte à l'appelant. Le code de sortie n'est pas défini.
- Durée ou étiquette invalide : erreur avant tout démarrage.

**Journal des séances** :

- Emplacement par défaut : `<LocalApplicationData>/pomodoro/sessions.jsonl`, défini une seule fois dans le module, pour l'écriture comme pour la lecture. `-LogPath` le remplace ; un dossier parent absent est créé.
- Format : une séance terminée ajoute une ligne, un objet JSON compact terminé par un saut de ligne, en UTF-8 sans BOM : `{"endedAt":"2026-11-07T14:25:00.0000000+01:00","minutes":25,"tag":"dev"}`. `endedAt` est une date ISO 8601 avec décalage, `minutes` un entier, `tag` une chaîne ou `null`.
- Étiquette : 1 à 50 caractères une fois retirés les espaces de début et de fin, sans caractère de contrôle. Elle est validée à la liaison des paramètres d'`Add-PomodoroLogEntry`, donc avant que la séance ne démarre.
- Lecture : `Get-PomodoroLog [-Path]` est le moyen de lecture prévu pour #18. Il rend un objet par ligne valide, dans l'ordre du fichier, avec `EndedAt` (`[DateTimeOffset]`), `Minutes` (`[int]`) et `Tag` (`[string]` ou `$null`). Un journal absent ne rend rien ; une ligne illisible est ignorée, avec un avertissement qui cite son numéro.

Les choix sont consignés dans `docs/adr/0001-minuteur-pomodoro-powershell.md`.

## Données

## Décisions

Les décisions importantes sont consignées dans `docs/adr/`, une par fichier.

# Architecture — .

*À compléter à la création du projet (`/start-project`), puis tenir à jour.*

## Vue d'ensemble

## Composants

### pomodoro

**Rôle** : minuteur de séance de concentration en ligne de commande (1 à 180 minutes, 25 par défaut). Il affiche le temps restant sur une seule ligne et annonce la fin de la séance.

**Fichiers** (`src/pomodoro/`) :

| Fichier | Rôle |
|---|---|
| `pomodoro.ps1` | Point d'entrée mince : `-Minutes`, `-Tag`, `-LogPath`, `-Summary`, import du module, enchaînement séance puis journal, ou résumé |
| `Pomodoro.psm1` | `Start-PomodoroSession` : la boucle de séance, avec `-Clock` et `-Wait` injectables. `Add-PomodoroLogEntry` et `Get-PomodoroLog` : l'écriture et la lecture du journal. `Get-PomodoroSummary` et `Format-PomodoroSummary` : le calcul et la mise en forme du résumé |
| `fr-FR/Pomodoro.psd1` | Les textes affichés, les gabarits de ligne, le format et la culture des dates |
| `Pomodoro.Tests.ps1` | Les tests Pester, à horloge simulée |

**Lancement** : `pwsh -NoProfile -File src/pomodoro/pomodoro.ps1 [-Minutes <1-180>] [-Tag <étiquette>] [-LogPath <chemin>]`, ou `pwsh -NoProfile -File src/pomodoro/pomodoro.ps1 -Summary [-LogPath <chemin>]` pour le résumé. Tests : `scripts/test.ps1`.

Les tests du minuteur se lancent par `scripts/test.ps1`.

**Contrat de sortie** :

- Séance menée à son terme : « Séance terminée » s'affiche et `Start-PomodoroSession` rend un seul objet, avec `PlannedMinutes` (`[int]`), `StartedAt` et `EndedAt` (`[DateTimeOffset]`). `pomodoro.ps1` le passe au journal et ne rend plus d'objet. Le script termine avec le code de sortie 0, sauf si le journal ne peut pas être écrit : une erreur cite alors son chemin, le code de sortie est 1 et la séance n'est pas enregistrée.
- Séance interrompue (Ctrl+C) : « Séance interrompue » s'affiche, aucun objet n'est rendu, rien n'est journalisé et l'exception remonte à l'appelant. Le code de sortie n'est pas défini.
- Durée ou étiquette invalide : erreur avant tout démarrage.

**Journal des séances** :

- Emplacement par défaut : `<LocalApplicationData>/pomodoro/sessions.jsonl`, défini une seule fois dans le module, pour l'écriture comme pour la lecture. `-LogPath` le remplace ; un dossier parent absent est créé.
- Format : une séance terminée ajoute une ligne, un objet JSON compact terminé par un saut de ligne, en UTF-8 sans BOM : `{"endedAt":"2026-11-07T14:25:00.0000000+01:00","minutes":25,"tag":"dev"}`. `endedAt` est une date ISO 8601 avec décalage, `minutes` un entier, `tag` une chaîne ou `null`.
- Étiquette : 1 à 50 caractères perçus (un emoji compte pour un) une fois retirés les espaces de début et de fin, sans caractère de contrôle. Elle est validée à la liaison des paramètres d'`Add-PomodoroLogEntry`, donc avant que la séance ne démarre.
- Lecture : `Get-PomodoroLog [-Path]` rend un objet par ligne valide, dans l'ordre du fichier, avec `EndedAt` (`[DateTimeOffset]`, avec le décalage écrit dans la ligne), `Minutes` (`[int]`) et `Tag` (`[string]` ou `$null`). Un journal absent ne rend rien ; une ligne illisible est ignorée, avec un avertissement qui cite son numéro.

**Résumé de la semaine** (`-Summary`) : `Get-PomodoroSummary [-Path] [-Clock]` calcule, `Format-PomodoroSummary` rend les lignes de texte, `pomodoro.ps1` enchaîne les deux. Aucune séance n'est lancée, le journal n'est jamais modifié, et le code de sortie est 0, même si le journal est absent ou vide (les 7 jours à 0, `Aucune séance sur cette période.` à la place des étiquettes, total à 0). Une ligne illisible donne l'avertissement de `Get-PomodoroLog`, et les autres lignes sont comptées.

- Objet rendu par `Get-PomodoroSummary` : `From`, `To`, `Days[]` (`Date`, `Sessions`, `Minutes`), `Tags[]` (`Label`, `Sessions`, `Minutes` ; `Label` vide pour les séances sans étiquette), `Sessions` et `Minutes`.
- Fenêtre : « aujourd'hui » est la date de l'horloge dans son propre décalage. La fenêtre couvre les sept jours de calendrier d'aujourd'hui − 6 à aujourd'hui, bornes comprises. Une séance compte pour la date de son `EndedAt` dans le décalage enregistré, sans conversion vers le fuseau de la machine. Une séance datée d'aujourd'hui mais postérieure à l'heure de l'horloge est incluse. Les jours sont toujours au nombre de 7, de la plus ancienne date à aujourd'hui, jours vides compris.
- Regroupement des étiquettes : comparaison ordinale sans casse, indépendante de la culture de la machine (d'où un dictionnaire `OrdinalIgnoreCase` plutôt que `Group-Object`). Le libellé affiché est l'orthographe de la première séance de la fenêtre, dans l'ordre du journal. Une étiquette `$null`, vide ou faite d'espaces apparaît sous `(sans étiquette)`, toujours en dernière ligne. Les autres sont triées par minutes décroissantes, puis par libellé (ordinal, sans casse). Seules les étiquettes qui ont au moins une séance dans la fenêtre apparaissent. Une étiquette plus longue que la colonne (16 caractères) déborde, sans être tronquée.

Les choix sont consignés dans `docs/adr/0001-minuteur-pomodoro-powershell.md`.

## Données

## Décisions

Les décisions importantes sont consignées dans `docs/adr/`, une par fichier.

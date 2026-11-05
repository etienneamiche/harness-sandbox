---
name: help-harness
description: L'expert du harness installé — hooks et règles (git-guard, secret-guard, destructive-guard, config-protection, model-guard, stop-checks), agents, modules, réglages, versions —, qui répond depuis les fichiers du projet et ne modifie rien. Il explique un refus de hook (règle et motif en cause, façon légitime de faire, faux positif ou non), ce que coûtent HARNESS_HOOK_PROFILE et HARNESS_DISABLED_HOOKS, ce qu'apporte une version et comment mettre à jour, et où ranger un besoin (règle d'AGENTS.md ou issue harness-update). À utiliser pour toute question sur le fonctionnement du harness ou sur un refus : « pourquoi git-guard refuse ma commande ? », « destructive-guard me bloque », « comment je coupe secret-guard ? », « comment marchent les modules ? », « qu'apporte la v0.3.0 ? », « où mettre une règle du projet ? ». Pas pour vérifier l'installation (/doctor : doctor en échec, harness à jour ou non, commits refusés par pre-commit, gitleaks absent), ni pour une rétro (/retro) ou le lint (/lint).
argument-hint: "[question]"
---

# /help-harness

Le harness encadre chaque geste de l'agent, et ses refus surprennent. `/help-harness` dit d'où vient un refus, ce qu'il protège et comment faire le geste autrement. Il explique aussi le reste du système : réglages, modules, versions.

**Répondre à partir des fichiers installés, jamais de mémoire.** Le harness évolue d'une version à l'autre : une règle, un motif ou un réglage se lit dans le projet, puis se cite avec son fichier. Une réponse qui ne s'appuie sur aucun fichier lu ne vaut rien.

**Lecture seule.** Le skill ne modifie aucun fichier, ne règle aucune variable et ne lance aucune mise à jour. Les fichiers du harness sont protégés par `config-protection` : les contourner par une commande shell trahirait la règle. Un besoin se range ailleurs (section 5).

Si `.harness/harness.json` n'existe pas, le harness n'est pas installé : le dire, citer `copier copy` (README du harness), et s'arrêter.

## 1. La carte du système

Ce tableau dit où lire, pas quoi répondre. Pour toute question, ouvrir le fichier concerné.

| Quoi | Où |
|---|---|
| Version installée, dépôt source, type, modules, profil choisi | `.copier-answers.harness.yml` (`_commit`, `_src_path`, `kind`, `modules`, `hook_profile`) |
| Configuration des règles | `.harness/harness.json`, notamment : `kind`, `profile`, `allowedAgents`, `restrictedCommands`, `protectedBranches`, `requireIssueRef`, `destructivePatterns`, `protectedPaths`, `secretPaths`, `secretPathsAllow`, `secretCommands`, `secretTokens`, `docAllow`, `debugPatterns`. Lire le fichier pour la liste exacte de la version installée |
| Branchement des hooks | `.claude/settings.json` (`hooks`, et `permissions.deny` pour l'outil `Read`) |
| Règles | `.harness/hooks/rules/<Événement>/<règle>.ps1`, et `.harness/modules/<module>/rules/<Événement>/` |
| Moteur | `.harness/hooks/dispatch.ps1` et `HarnessHooks.psm1` |
| Subagents | `.claude/agents/<agent>.md` (modèle déclaré) et `allowedAgents` |
| Modules | `.harness/modules/<module>/` : `conventions.md`, `module.json` (`stopChecks`, `structural`) |
| Conventions | `AGENTS.md` (au projet) importe `.harness/agents/core.md`, qui importe les conventions communes et celles des modules |
| Hook Git | `.harness/githooks/pre-commit` (gitleaks), branché par `core.hooksPath` |
| Outils | `.harness/tools/` : `doctor`, `post-install`, `write-manifest`, `merge-pr`, `board` ; leur aide par `Get-Help .harness/tools/<outil>.ps1 -Full` |

**L'enchaînement d'un hook.** Claude Code lance `dispatch.ps1 <Événement>` pour les outils listés dans le `matcher` de `settings.json`. Le moteur charge les règles de cet événement, du cœur et des modules, par ordre de nom. Il écarte celles de `HARNESS_DISABLED_HOOKS`, celles dont `Profiles` ne contient pas le profil actif, et celles dont `Tools` ne couvre pas l'outil appelé. La première règle qui refuse arrête tout : son message commence par `harness/<règle> :`. Une règle `Kind = 'guard'` en erreur refuse par sécurité ; une règle `info` en erreur est ignorée. `agent_type` est absent dans la session principale et présent dans un subagent : c'est ainsi que `git-guard` réserve un geste à `git-ops`.

## 2. Expliquer un refus de hook

1. **Trouver la règle.** Le nom suit `harness/` dans le message. Ouvrir son fichier (chercher `<règle>.ps1` sous `.harness/hooks/rules/` et `.harness/modules/`), puis la clé de `harness.json` qu'elle lit. Un message `harness :` **sans nom de règle** vient du moteur lui-même : l'entrée du hook ou `harness.json` est illisible, et tout est refusé par sécurité. Ce n'est pas un refus de règle : c'est `/doctor`.
2. **Trouver le motif en cause.** Comparer la commande ou le chemin refusé aux motifs de la règle, et citer le motif exact. Pour en avoir la preuve, rejouer le hook :
   - écrire l'entrée **avec l'outil `Write`**, dans un fichier hors du dépôt (`<dossier temporaire>/help-harness-replay.json`), jamais par une commande shell, où la commande refusée réapparaîtrait :
     ```
     {"tool_name":"Bash","tool_input":{"command":"<commande refusée>"},"cwd":"<dossier du projet>","session_id":"help-harness-<heure>"}
     ```
     `tool_name` et `tool_input` reprennent l'outil refusé : `"Edit"` ou `"Write"` avec `{"file_path":"<chemin>"}` (cas de `config-protection` et de `secret-guard`), `"Agent"` avec `{"subagent_type":"<agent>","model":"<modèle, s'il était passé>"}` (cas de `model-guard`). Ne rejouer que les outils du `matcher` de `PreToolUse` dans `settings.json` : le hook ne voit jamais les autres. Un refus de `Read` sur un secret vient de `permissions.deny`, sans préfixe `harness/`, et son rejeu donnerait un refus `secret-guard` que la session ne produit pas.

     C'est du JSON : dans la commande, le dossier et le chemin (`file_path`), doubler chaque `\` et écrire `\"` pour un guillemet. Le plus simple est d'écrire le dossier et le chemin avec des `/` (`C:/repo/app`), ou le chemin relatif au projet. Un JSON invalide donne un refus du moteur (`harness : entrée de hook illisible`), pas celui de la règle ;
   - puis `Get-Content -Raw '<fichier>' | pwsh -NoProfile -File .harness/hooks/dispatch.ps1 PreToolUse` ;
   - ajouter `"agent_type":"git-ops"` pour voir si `git-ops` aurait le droit.

   **Ne jamais réécrire la commande refusée dans une nouvelle commande** : le hook la refuserait encore, et ce serait une tentative de contournement. Les règles tournent par ordre de nom, et la première qui refuse masque les suivantes. Ainsi `destructive-guard` refuse toujours le premier essai d'une commande destructive, avant `git-guard` et `secret-guard`. Pour voir la règle suivante, rejouer une seconde fois le même fichier, avec le même `session_id`. Changer de `session_id` à chaque explication (`<heure>`), pour ne pas hériter d'un rejeu précédent.
3. **Dire la façon légitime de faire.** Le message du refus la donne souvent. Sinon :
   - `git-guard`, geste réservé : le confier à l'agent cité. Les écritures Git et GitHub passent par `git-ops`, en général par `/ship`, `/feature` ou `/release`. Une fusion passe par `merge-pr.ps1`, que lance `git-ops` après une revue `auditor`.
   - `git-guard`, geste interdit : `--no-verify` ne se contourne pas. Corriger ce que le pre-commit refuse : un secret trouvé par gitleaks se retire, et un gitleaks absent relève de `/doctor`. `git add -A` se remplace par les fichiers nommés un par un. Une branche protégée demande une branche `feature/<n>-…` et une PR.
   - `secret-guard` : un agent ne lit ni n'écrit un secret. Les noms de variables se lisent dans `.env.example`. La valeur, seul l'utilisateur la consulte. Une application reçoit ses secrets à l'exécution (`sops exec-env`, `launch.ps1`).
   - `config-protection` : le fichier encadre le travail de l'agent. L'utilisateur le modifie lui-même s'il est propre au projet. Un fichier du harness ne se modifie pas : le besoin devient une issue `harness-update`.
   - `destructive-guard` : exposer ce qui sera supprimé, le retour arrière et la demande exacte de l'utilisateur, puis relancer la même commande. Sans demande explicite, demander d'abord.
   - `model-guard` : rappeler l'agent sans paramètre `model`, ou choisir un agent de `allowedAgents`.
   - `stop-checks` : corriger les vérifications du module en échec, citées dans le message (lint, typecheck, tests…). `/lint` s'en charge pour le lint.
4. **Trancher : faux positif ou refus qui joue son rôle.**
   - **Le refus joue son rôle** quand le geste visé par la règle était bien celui tenté : une écriture Git hors de `git-ops`, la lecture d'un secret, un fichier qui encadre l'agent. C'est le cas le plus fréquent : le dire franchement, et donner la façon légitime.
   - **C'est un faux positif** quand le geste était légitime et que seul le texte ressemble au motif. Par exemple une route d'API `$token` prise pour une variable secrète. Le rejeu le prouve : un faux positif déjà corrigé dans la version installée ne refuse plus. Le motif est trop large : c'est un défaut du harness, commun à tous les projets. Il se remonte par une issue `harness-update` (section 5). En attendant, l'utilisateur peut lancer la commande lui-même dans son terminal. L'agent ne la reformule pas pour passer sous le motif.

## 3. Les réglages

Lire le profil actif dans le message de `session-info`, au début de la session, ou dans `harness.json` (`profile`). Lire les profils de chaque règle dans son fichier (`Profiles`). Ne pas recopier une liste de mémoire : un module peut ajouter des règles.

- **`HARNESS_HOOK_PROFILE`** = `minimal`, `standard` ou `strict` : remplace `profile` de `harness.json` pour la session. Dire quelles règles sautent ou s'ajoutent d'après leurs fichiers, et ce que chacune protégeait. En `minimal`, par exemple, plus de `destructive-guard` : une suppression récursive passe du premier coup, sans exposé du retour arrière.
- **`HARNESS_DISABLED_HOOKS`** = `regle1,regle2` : coupe ces règles entièrement, pour tous les outils et tous les agents de la session.

Ces variables se règlent **par l'utilisateur, avant de lancer Claude Code** : les hooks reçoivent l'environnement de Claude Code, pas celui des commandes de l'agent. Une variable posée par l'agent dans son shell est donc sans effet, et le skill n'en pose aucune. Ne pas les mettre dans `env` de `settings.json` non plus : ce fichier appartient au harness. Un changement durable du profil passe par la réponse `hook_profile` lors d'une mise à jour du harness (section 4).

Pour chaque réglage demandé, dire **ce qu'on perd**, et s'il atteint vraiment le but :
- couper `secret-guard` n'ouvre pas `.env` à l'outil `Read` : le hook n'est pas branché sur `Read` (`matcher` de `settings.json`), que seul `permissions.deny` protège, nativement. La coupure ouvre en revanche la lecture par le shell (`Get-Content .env`, `cat .env`), l'écriture des fichiers secrets et les commandes qui affichent un secret (`sops -d`, `$env:…TOKEN`). Et la valeur lue partirait dans le transcript de la session ;
- couper `git-guard` retire aussi la revue `auditor` obligatoire, les branches protégées et le refus de `--no-verify`.

Proposer d'abord la façon légitime (section 2). Un réglage revient à l'utilisateur, en connaissance de cause.

## 4. Versions et mises à jour

- **Version installée** : `_commit` dans `.copier-answers.harness.yml`. Une forme `vX.Y.Z-N-g<sha>` est une version de développement, N commits après le tag `vX.Y.Z`.
- **Dépôt source** : `_src_path`. De la forme `gh:<propriétaire>/<dépôt>`, c'est le dépôt GitHub. Un chemin (`C:\…\harness`) est une copie de travail locale, le cas des versions de développement.
- **Versions publiées** : `git ls-remote --tags --refs https://github.com/<propriétaire>/<dépôt>`, ou `git ls-remote --tags --refs '<chemin>'` pour une copie locale.
- **Ce qu'apporte une version** : la section de chaque version au-dessus de celle installée, dans le CHANGELOG du dépôt source, lu au tag visé :
  - dépôt GitHub : `gh api 'repos/<propriétaire>/<dépôt>/contents/CHANGELOG.md?ref=<tag>' -H 'Accept: application/vnd.github.raw'` ;
  - copie locale : `git -C '<chemin>' show <tag>:CHANGELOG.md`.

  Résumer ce qui change pour ce projet : skills, règles plus strictes ou corrigées, fichiers modifiés. Une version de développement se compare à la section « Non publié » au commit `<sha>`.
- **La procédure actuelle**, donnée sans la lancer. Elle revient à l'utilisateur, car elle réécrit les fichiers du harness :
  1. une branche `chore/harness-vX.Y.Z`, créée par `git-ops` ;
  2. `scripts/harness-sync.ps1` à la racine `services` s'il existe. Sinon, `copier update --trust --answers-file .copier-answers.harness.yml --vcs-ref vX.Y.Z` (`--data hook_profile=<profil>` pour changer de profil) ;
  3. résoudre les conflits. `.harness/manifest.json` en sort toujours, d'où `pwsh -NoProfile -File .harness/tools/write-manifest.ps1` (harness#3) ;
  4. relancer le doctor, ouvrir une nouvelle session (les hooks se lisent à l'ouverture), puis `/ship`.

Savoir si le projet est à jour ou si l'installation est saine, c'est `/doctor`.

## 5. Où ranger un besoin

- **Propre au projet** (une convention, un piège de ce code, une commande du projet) : une règle dans « Spécificités de ce projet » d'`AGENTS.md`. Ce fichier appartient au projet, et la mise à jour du harness ne l'écrase jamais. La règle passe par une issue du projet, puis par `/feature`. Rédiger la règle telle qu'elle sera écrite : une phrase impérative, avec sa raison.
- **Commun à tous les projets** (un faux positif, un motif trop étroit, un manque d'un skill) : une issue `harness-update` sur le dépôt source.
  1. Chercher un doublon : `gh issue list -R <propriétaire>/<dépôt> --state open --search '<mots-clés>'`. Le dépôt vient de `_src_path` (`gh:<propriétaire>/<dépôt>`). Pour une copie locale, il se lit par `git -C '<chemin>' remote get-url origin`. Une issue existante se cite, sans la recréer.
  2. Rédiger le brouillon : le constat, la preuve (la commande, le motif, la règle, sans secret ni chemin personnel) et une piste. Le faire valider.
  3. Après accord, `git-ops` la crée (sans paramètre `model`) : `gh issue create -R <propriétaire>/<dépôt> --title "<titre>" --body-file '<fichier hors du dépôt>' --label harness-update`.
- Jamais par une modification locale d'un fichier du harness : le doctor la signale, la mise à jour suivante entre en conflit, et les autres projets n'en profitent pas.

## 6. À la racine `services` (`kind: root`)

Le même skill couvre aussi les scripts de l'écosystème : `scripts/*.ps1` (aide par `Get-Help scripts/<script>.ps1 -Full`) et `repos.yaml`, la liste des dépôts. Répondre de la même façon : lire le script, citer ce qu'il fait, et ne rien lancer qui écrive.

## 7. Répondre

Une réponse courte, dans cet ordre :
- **Réponse** : ce qui se passe, en une ou deux phrases.
- **D'où ça vient** : le fichier, la règle et le motif ou la clé en cause, cités.
- **Quoi faire** : la façon légitime, ou la procédure, sans la lancer.
- **Si besoin** : la règle d'`AGENTS.md` ou l'issue `harness-update` proposée, avec son brouillon, et la question d'accord. Rien n'est créé avant la réponse.

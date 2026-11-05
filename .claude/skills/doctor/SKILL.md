---
name: doctor
description: Lance le doctor du projet (.harness/tools/doctor.ps1) et explique chaque écart, WARN ou FAIL : la cause, vérifiée par un contrôle ciblé (git log et git diff d'un fichier du harness modifié, settings.json, plugins, autotest relancé seul), l'effet concret et la correction. Les corrections sont classées en trois groupes : sans risque (-Fix), à la main de l'utilisateur, destructrices. Aucune n'est appliquée sans accord. À utiliser dès que le doctor est rouge ou que l'utilisateur doute que le harness soit en place — « lance le doctor », « le doctor est en échec », « vérifie le harness », « mes hooks ne bloquent plus rien », « tout commit est refusé, gitleaks », « fichiers du harness modifiés », « le harness est-il à jour ? », « autotests en échec » —, même pour un seul contrôle. Pas pour expliquer le fonctionnement du harness hors d'un écart, ni pour corriger le lint (/lint).
argument-hint: "[deep]"
---

# /doctor

Le doctor dit *ce qui* ne va pas, en une ligne par contrôle. `/doctor` dit *pourquoi c'est important* et *comment réparer sans rien casser*. Les deux comptent : une ligne `FAIL hooks Claude Code` cache un projet où plus aucun garde-fou ne tourne, et une réparation faite trop vite peut masquer le problème au lieu de le corriger.

Le skill ne répare rien sans accord. La plupart des fichiers en cause (`.harness/`, `.claude/settings.json`, `.claude/agents/`, `.gitignore`) encadrent le travail de l'agent, et le hook `config-protection` empêche l'agent de les modifier. Les restaurer par une commande shell contournerait cette règle. C'est donc l'utilisateur qui les restaure : le skill lui donne la commande exacte.

## 1. Lancer le doctor

- Si `.harness/tools/doctor.ps1` n'existe pas, le harness n'est pas installé dans ce dépôt : le dire, citer `copier copy` (README du harness) et s'arrêter.
- Lancer `pwsh -NoProfile -File .harness/tools/doctor.ps1` par l'outil PowerShell. Ajouter `-Deep` avec l'argument `deep`, ou quand la question porte sur le comportement des hooks (« git-guard ne bloque plus », « les hooks marchent-ils ? ») : ce sont les autotests qui le vérifient.
- **Jamais `-Fix` à ce stade.** Il répare avant qu'on sache ce qui est cassé, et sans l'accord de l'utilisateur.
- Si le doctor plante (une exception au lieu du tableau), c'est qu'il ne lit pas l'un de ses fichiers d'entrée : `.harness/harness.json`, `.copier-answers.harness.yml` ou `.claude/settings.json`, absent ou en JSON invalide. Lire l'erreur, puis `git status --short -- '<fichier>'` et `git log --oneline -3 -- '<fichier>'`, et traiter le fichier comme un fichier du harness modifié (étape 2).
- **Doctor vert** (0 échec, 0 avertissement) : le dire en une ligne, et s'arrêter.

## 2. Diagnostiquer chaque écart

Pour chaque ligne `WARN` ou `FAIL` : la cause, l'effet concret, la correction et son groupe. Le détail du doctor ne suffit pas toujours à trouver la cause : faire alors le contrôle ciblé indiqué. Commencer par les fichiers du harness, car une modification de ces fichiers explique souvent les autres écarts.

**Fichiers du harness** (`manifest.json` comparé aux fichiers de `.harness/`, `.claude/agents/`, `.claude/skills/`, `.claude/settings.json` et `CLAUDE.md`)
- Repère : le dernier commit qui a écrit le manifeste, `git log -1 --format='%h %s' -- .harness/manifest.json`. Le manifeste est écrit à l'installation et à chaque mise à jour du harness.
- **FAIL, modifiés** : pour chaque fichier, `git status --short -- '<fichier>'` (modification non commitée ?), `git log --oneline -3 -- '<fichier>'` (quel commit, et après le repère ?), puis le diff : `git diff -- '<fichier>'` s'il n'est pas commité, sinon `git diff <repère> -- '<fichier>'`. Résumer ce qui a changé.
  - **Effet** : le garde-fou n'est plus celui de la version installée. Une règle de hook affaiblie laisse passer ce qu'elle devait bloquer. Et la prochaine mise à jour du harness entrera en conflit.
  - **Modification involontaire** : à la main de l'utilisateur. `git restore -- '<fichier>'` si elle n'est pas commitée, `git restore --source <repère> -- '<fichier>'` si elle l'est (puis commit par `/ship`).
  - **Modification voulue** (le projet a besoin d'autre chose) : ne pas restaurer. La remonter au harness par une issue `harness-update` (étape 3), pour qu'elle profite à tous les projets. Régénérer le manifeste pour que le doctor repasse au vert, c'est cacher l'écart : seul l'utilisateur en décide, en le sachant.
  - **Mise à jour du harness non finalisée** : le fichier a changé dans un commit de mise à jour (`copier update`, branche `chore/harness-…`) postérieur au repère. Le manifeste n'a pas été régénéré. Correction à la main : `pwsh -NoProfile -File .harness/tools/write-manifest.ps1`.
- **FAIL, absents** : `git log --oneline -1 -- '<fichier>'` dit s'il a été supprimé dans un commit. Correction à la main : `git restore --source <repère> -- '<fichier>'`.
- **FAIL, `manifest.json` absent** : `post-install.ps1` n'a jamais tourné. Si `git status --short -- .harness .claude CLAUDE.md` est propre, `pwsh -NoProfile -File .harness/tools/post-install.ps1` est sans risque. Sinon, regarder d'abord ce qui est modifié : le manifeste signerait cet état.
- **WARN, fichiers ajoutés** : des fichiers du projet rangés dans un dossier géré par le harness (un skill ou un agent propre au projet). Rien de cassé. Un agent ajouté dans `.claude/agents/` est refusé par `model-guard` tant qu'il n'est pas dans `allowedAgents`. Un fichier oublié se supprime, par l'utilisateur.
- **Destructeur, à ne pas lancer** : `copier recopy` réapplique tout le template et écrase toutes les modifications locales des fichiers du harness. Ne le citer que si Git ne peut rien restaurer, comme un geste de l'utilisateur, en disant ce qu'il écrase.

**Hooks Claude Code** (FAIL, événements non branchés)
- **Effet** : pour ces événements, aucun garde-fou ne tourne. Sans `PreToolUse`, `git-guard`, `secret-guard`, `config-protection`, `destructive-guard` et `model-guard` sont tous éteints. C'est l'écart le plus grave.
- **Cause** : `git diff -- .claude/settings.json` et `git log --oneline -3 -- .claude/settings.json`. La cause est une modification à la main, ou un conflit mal résolu lors d'une mise à jour du harness. Un `settings.json` seulement reformaté par `claude plugin install` (harness#4) garde ses hooks : ce n'est pas cet écart.
- **Correction**, à la main : restaurer `settings.json` par Git, comme un fichier du harness modifié. Puis **redémarrer la session Claude Code** : les hooks sont lus à son ouverture.

**`claudeMdExcludes`** (FAIL) : les instructions du dépôt racine `services` s'ajoutent à celles du projet et peuvent les contredire. Même cause et même correction que les hooks.

**Subagents** (FAIL)
- Un agent dont le modèle diffère de `allowedAgents` tourne sur le mauvais modèle. Par exemple `auditor` sur Haiku fait une revue plus faible que prévu.
- Un agent absent de la liste est refusé par `model-guard`.
- Correction à la main : restaurer le fichier de l'agent. Un nouvel agent voulu passe par une issue `harness-update`.

**Hook pre-commit** (FAIL, `core.hooksPath` non réglé) : gitleaks ne tourne plus avant un commit, et un secret peut partir dans Git. Correction sans risque : `-Fix`. Le WARN « pas de dépôt Git » se corrige par `git init` (à ta main), puis `-Fix`, qui règle `core.hooksPath` sans réécrire le manifeste. Pas `post-install.ps1` seul : il réécrit le manifeste et signerait l'état présent des fichiers du harness.

**gitleaks** (FAIL, absent) : le hook pre-commit refuse tout commit, par sécurité. Correction à la main : `winget install --id Gitleaks.Gitleaks`, ou `scripts/setup-workstation.ps1` à la racine `services`. Un outil installé pendant la session n'est souvent pas encore dans son `PATH` : rouvrir le terminal, puis relancer le doctor.

**`.gitignore`** (FAIL, bloc du harness absent) : `.env`, clés et fichiers déchiffrés peuvent être commités. Correction sans risque : `-Fix`. Il remet le bloc sans réécrire le manifeste : un fichier du harness modifié reste visible au doctor suivant.

**Plugins**
- **FAIL, non installés** : `enabledPlugins` les déclare, mais le doctor ne les trouve pas installés pour ce projet. Il n'y a donc ni diagnostics LSP ni skills de ces plugins.
  - **Cause** : lire le registre du poste, `~/.claude/plugins/installed_plugins.json` (ou `claude plugin list`). Le doctor n'accepte qu'une installation de portée `user`, ou de portée `project` dont le `projectPath` est exactement ce dossier. Un plugin absent du registre n'a jamais été installé sur ce poste (cas d'un nouveau poste). Un plugin présent avec le `projectPath` d'un autre dossier vient d'un projet déplacé, renommé ou cloné ailleurs.
  - **Correction** sans risque : `-Fix`, qui lance `claude plugin install <plugin> --scope project`. Sans le CLI `claude`, `-Fix` ne peut pas les installer.
  - **Effet de bord** : `claude plugin install` réécrit `.claude/settings.json`, avec le même contenu mais une autre mise en forme et un autre ordre des clés (harness#4). Le doctor suivant voit alors `settings.json` comme un fichier du harness modifié. Voir « Après accord pour `-Fix` ».
- **WARN `HARNESS_SKIP_PLUGINS`** : la variable d'environnement coupe ce contrôle. Elle est normale sur un banc d'essai, mais pas dans un vrai projet.

**codegraph** (WARN, index absent) : les outils codegraph ne trouvent rien dans ce projet. Correction sans risque : `codegraph init`, ou `-Fix`. Indexer reste un choix de l'utilisateur : le proposer, sans l'inclure d'office.

**Version**
- **WARN, dernière version vX** : le projet n'a pas les corrections et les skills des versions suivantes. Rien n'est cassé. Correction à la main, sur une branche `chore/harness-vX.Y.Z` : `scripts/harness-sync.ps1` à la racine `services` s'il existe. Sinon, `copier update --trust --answers-file .copier-answers.harness.yml`, puis `.harness/tools/write-manifest.ps1` (le manifeste sort toujours en conflit, harness#3), puis le doctor.
- **WARN, version de développement** : une version de la forme `vX.Y.Z-N-g<sha>` vient d'un projet généré depuis une copie de travail du harness, N commits après le tag vX.Y.Z. Comparer vX.Y.Z à la dernière version affichée par le doctor. Si elles sont égales, le projet est *en avance* sur la dernière version : il n'y a rien à mettre à jour, le dire. Si la dernière version est plus récente, le projet est en retard : c'est le cas « dernière version vX » ci-dessus.
- **WARN, dépôt source injoignable** : pas de réseau, ou `gh` et Git sans accès au dépôt du harness. Le reste du doctor reste valable. `-Offline` évite ce contrôle.
- **FAIL, réponses illisibles** : `.copier-answers.harness.yml` est abîmé. Aucune mise à jour n'est possible. Le restaurer par Git, à la main.

**Autotests** (`-Deep`, FAIL)
- Relancer le fichier en échec seul, pour lire le message : `[Console]::OutputEncoding = [Text.Encoding]::UTF8; Invoke-Pester -Path .harness/tests/<Fichier>.Tests.ps1 -Output Detailed`. Puis lire la règle visée dans `.harness/hooks/rules/`.
- Si les fichiers du harness sont modifiés, la modification est la cause probable.
- S'ils sont intacts, c'est un défaut du harness ou une différence du poste (encodage de la console, outil absent). Le défaut se remonte par une issue `harness-update`.
- « Tests non exécutés » signale une erreur de syntaxe ou un `BeforeAll` en échec, qui fait disparaître des tests sans les compter : c'est aussi un FAIL.

**Un contrôle absent de cette liste** (le doctor a évolué) : lire sa section dans `.harness/tools/doctor.ps1`, qui dit ce qu'il vérifie et ce que répare `-Fix`.

## 3. Proposer les corrections

Ranger chaque correction dans l'un des trois groupes :
- **Sans risque**, par `-Fix` : `core.hooksPath`, `.gitignore`, plugins, index codegraph. Le skill les lance après accord. `-Fix` applique **toutes** ces réparations d'un coup. Si l'utilisateur n'en accepte qu'une partie, ne pas lancer `-Fix` : lancer la commande de chacune.
  - `core.hooksPath` : `git config core.hooksPath .harness/githooks` ;
  - `.gitignore` : `pwsh -NoProfile -File .harness/tools/post-install.ps1 -SkipPlugins -SkipManifest` (règle aussi `core.hooksPath`) ;
  - plugins : `claude plugin install <plugin> --scope project` ;
  - index : `codegraph init`.
- **À ta main** : restaurer un fichier du harness, installer un outil, mettre à jour le harness, régénérer le manifeste. Le skill donne la commande exacte et ne la lance pas.
- **Destructrices** : `copier recopy`, et toute commande qui écrase plusieurs fichiers d'un coup. Le skill ne les lance jamais. Il les cite seulement quand rien d'autre ne marche, en disant ce qu'elles écrasent.

Présenter d'abord les fichiers du harness : une règle de hook modifiée explique souvent les autres écarts, et c'est l'écart que l'utilisateur doit trancher lui-même. `-Fix` ne réécrit pas le manifeste et ne touche qu'à un seul fichier du harness : `.claude/settings.json`, quand il installe des plugins (harness#4). Si `settings.json` est déjà modifié, faire trancher ce point avant de lancer `-Fix`, sinon le reformatage noierait la vraie modification. Pour les autres fichiers du harness, `-Fix` peut passer avant qu'ils soient réglés.

Une issue `harness-update` (une modification voulue à remonter, ou un défaut du harness) se prépare ainsi :
1. Chercher un doublon : `gh issue list -R <dépôt source> --state open --search '<mots-clés>'`. Le dépôt source est `_src_path` dans `.copier-answers.harness.yml` (`gh:owner/repo`). Une issue existante est citée, pas recréée.
2. Rédiger le brouillon et le faire valider.
3. `git-ops` la crée, après l'accord de l'utilisateur.

Demander l'accord dans un seul message numéroté, avec ce qui sera lancé et ce que cela modifiera. Ne rien lancer avant la réponse.

**Après accord pour `-Fix`** :
1. Lancer `pwsh -NoProfile -File .harness/tools/doctor.ps1 -Fix`.
2. Lancer `git status --short` pour montrer ce qu'il a modifié.
3. Relancer le doctor sans `-Fix`, pour le bilan final.

Si `.claude/settings.json` apparaît modifié après l'installation de plugins, comparer son contenu JSON à celui de `HEAD` (`git show HEAD:.claude/settings.json`), clés triées, et pas le texte.
- **Même contenu** : c'est le reformatage de harness#4, pas une perte de configuration. Le dire, avec sa cause. La correction est à la main : `git restore -- .claude/settings.json`. Les plugins restent installés, car le registre est hors du dépôt.
- **Contenu différent** : c'est une vraie modification. La traiter comme un fichier du harness modifié, et comme l'écart « hooks Claude Code » si des hooks manquent.

## 4. Rendre compte

```
**/doctor** : <projet> — <n échec(s), n avertissement(s)> (<options : -Deep, -Offline, ou aucune>)

À corriger :
1. **<contrôle>** (FAIL) : <ce qui ne va pas>.
   Cause : <ce que le contrôle ciblé a montré, avec le commit ou le diff résumé>.
   Effet : <ce que cela change concrètement>.
   Correction (<sans risque | à ta main | destructrice>) : <commande exacte ou geste>.
À savoir :
- **<contrôle>** (WARN) : <écart>, <effet>, <correction>.

Je propose : <les corrections sans risque à lancer par -Fix, et les commandes à ta main, dans l'ordre>.
```

Puis la question numérotée qui demande l'accord. Après une correction, ajouter :

```
Après correction : <bilan du doctor> — modifié : <fichiers, ou rien>.
Reste : <ce qui attend l'utilisateur, ou rien>.
```

Ne rien commiter : une correction à garder passe par `/ship`.

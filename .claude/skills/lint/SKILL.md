---
name: lint
description: Nettoie le lint et le format du projet avec le subagent linter, puis contrôle ce qu'il a changé. Les formateurs et linters du projet (scripts/lint.ps1, ou les vérifications des modules : Biome et tsc, dotnet format et build, ruff et pyright) tournent avec leur correction automatique. linter corrige à la main les avertissements restants sur les fichiers de la branche, et la session refuse toute suppression d'avertissement ou tout changement de comportement. Les tests tournent ensuite. Rien n'est commité. À utiliser dès qu'il faut faire passer le lint, le format ou le typecheck au vert — « lance le lint », « corrige les warnings », « nettoie le format », « Biome râle », « dotnet format », « ruff », « tsc ne passe pas », « le stop-check échoue » —, même pour un seul fichier. Pas pour relire le code (/review), corriger un bug (dev) ou commiter (/ship).
argument-hint: "[tout | chemin]"
---

# /lint

`/lint` fait passer au vert le lint, le format et le typecheck du projet, sans changer ce que fait le code. Les vérifications de fin de tour (`stop-checks`) contrôlent déjà les fichiers modifiés à chaque tour. `/lint` est le nettoyage explicite, quand ces vérifications échouent ou qu'on veut repartir propre.

**`linter` exécute** : il est sur Haiku, lance les outils et corrige. **La session principale contrôle** : un modèle rapide a tendance à faire taire un avertissement plutôt qu'à le corriger, par une directive d'ignorance, un cast ou un changement de logique. Ce contrôle est la raison d'être du skill.

Rien n'est commité : c'est le rôle de `/ship`.

## 1. Situer

- **Les outils** : `scripts/lint.ps1` s'il existe. Sinon, les `stopChecks` des modules installés (`.harness/modules/*/module.json`), qui donnent pour chaque outil la commande et les fichiers concernés. Si le projet n'a ni l'un ni l'autre, le dire et s'arrêter : inventer une commande de lint, c'est imposer des règles que le projet n'a pas choisies.
- **Les fichiers de la branche** : base `develop` s'il existe sur le dépôt distant (`git ls-remote --heads origin develop`), sinon `main`. Puis `git fetch origin <base>`, et les noms seuls : `git diff --name-only origin/<base>...HEAD`, `git diff --name-only HEAD`, et les nouveaux fichiers `git ls-files --others --exclude-standard`. Mettre de côté les fichiers de secrets (ceux qui correspondent à `secretPaths` sans correspondre à `secretPathsAllow`, dans `.harness/harness.json`) : un linter n'a rien à y faire, et aucune commande ne doit les citer.
- **Le périmètre des corrections à la main** : les fichiers de la branche. Avec l'argument `tout`, le projet entier. Avec un chemin, ce chemin. Corriger à la main des avertissements dans des fichiers que la branche ne touche pas mélangerait un nettoyage au travail en cours, et gonflerait la PR.
- **L'état d'avant**, pour pouvoir contrôler ensuite ce que `linter` a changé. Les fichiers propres avant `/lint` se comparent à `HEAD`. Pour les fichiers qui ont déjà des modifications non commitées, ou qui sont nouveaux, il faut une copie. Les copier, en gardant leur chemin relatif, dans un dossier propre à ce `/lint` : `Join-Path ([IO.Path]::GetTempPath()) "lint-before/<nom du dépôt>-<yyyyMMdd-HHmmss>"`. Un dossier commun mélangerait les copies de deux projets de même arborescence, ou celles d'un `/lint` précédent, et la restauration injecterait alors des lignes d'ailleurs. Citer ce dossier dans le compte rendu. Il n'est pas supprimé.
- **Les tests** : `scripts/test.ps1` s'il existe. Les lancer avant `linter`, pour savoir s'ils étaient déjà rouges : un test rouge avant le nettoyage ne lui est pas imputable.

## 2. Confier le nettoyage à `linter`

Appeler le subagent `linter`, **sans paramètre `model`** (le hook `model-guard` le refuse). Brief :

```
/lint du projet, branche <branche>.
1. Lance, avec leur correction automatique, par l'outil PowerShell (ce sont des commandes PowerShell, que Bash ne sait pas lire) : <pwsh -NoProfile -File scripts/lint.ps1, ou les commandes stopChecks une par une, telles quelles>.
2. Corrige à la main les avertissements restants, dans ces fichiers seulement : <fichiers de la branche entre apostrophes, ou « tout le projet »>.
   Ailleurs, ne modifie rien à la main : liste les avertissements avec chemin:ligne et la règle.
3. Relance les outils jusqu'à ce qu'ils passent, ou qu'il ne reste que ce que tu ne sais pas corriger proprement.
Interdit :
- faire taire un avertissement : biome-ignore, eslint-disable, @ts-ignore, @ts-expect-error, @ts-nocheck, #pragma warning disable, [SuppressMessage], # noqa, # type: ignore, # pyright: ignore ;
- le contourner : un cast vers any ou object, un ! non-null ajouté sans preuve, une variable renommée en _ pour la cacher, du code supprimé parce qu'il dérange ;
- changer ce que fait le code. Si la seule correction change le comportement, laisse l'avertissement et signale-le ;
- modifier la configuration du lint, du format ou du typecheck (ces fichiers sont protégés).
Rends : ce que les outils ont corrigé seuls (fichiers), ce que tu as corrigé à la main (chemin:ligne, règle, correction), et ce qui reste (chemin:ligne, règle, pourquoi).
```

## 3. Contrôler ce que `linter` a changé

- **Le diff de `linter`** : `git status --porcelain --untracked-files=all` donne les fichiers touchés. Pour un fichier propre avant, `git diff -- '<fichier>'` suffit. Pour un fichier qui avait déjà des modifications, `git diff --no-index -- '<copie dans lint-before>' '<fichier>'`.
- **Les suppressions** : chercher, dans les lignes ajoutées, les directives et contournements interdits par le brief. Chacune est refusée et restaurée, sans exception. L'avertissement va dans « Reste », avec la raison donnée par `linter` s'il en a une. Une directive d'ignorance est parfois légitime, mais c'est à l'utilisateur de l'ajouter, pas à `/lint` de la laisser passer.
- **Le comportement** : lire chaque correction à la main. Une correction de formatage ou un renommage local ne change rien. Une condition réécrite, un `await` ajouté ou retiré, un type élargi, un `catch` modifié ou une valeur par défaut changée peuvent tout changer. En cas de doute, c'est un changement de comportement.
- **Ce qui ne va pas** se renvoie à `linter`, avec le `chemin:ligne` et la consigne : restaurer la ligne d'origine (`git show HEAD:'<fichier>'`, ou la copie d'avant) et laisser l'avertissement. Ne pas recourir à une commande qui écrase tout le fichier : elle effacerait aussi le travail non commité de l'utilisateur.
- **Les fichiers hors périmètre** : les correcteurs automatiques reformatent tout le projet, c'est attendu. Une modification **à la main** hors périmètre se renvoie comme ci-dessus.
- **Puis relancer** les outils (même commande qu'à l'étape 2) et `scripts/test.ps1`. Un test vert avant et rouge après désigne une correction qui a changé le comportement : la trouver dans le diff et la faire restaurer.

## 4. Rendre compte

```
**/lint** : <outils lancés> — <vert | reste n avertissement(s)>

Corrigé par les outils : <n fichiers, ou rien>
Corrigé à la main :
- `chemin:ligne` (règle) : la correction.
Refusé et restauré : <suppression ou changement de comportement, chemin:ligne, ou rien>
Reste :
- `chemin:ligne` (règle) : pourquoi ce n'est pas corrigé (hors branche, correction qui changerait le comportement, règle qui semble mauvaise).
Tests : <vert avant et après | rouge avant : déjà rouge, sans rapport | absents>
Copies d'avant : <dossier lint-before de ce /lint, ou aucune>
```

Une règle qui semble mauvaise se signale, avec sa raison, et sans modifier la configuration : c'est à l'utilisateur de trancher, par une issue `harness-update` si la règle vient du harness.

Puis proposer la suite : `/ship` si le travail est prêt, `/lint tout` s'il reste des avertissements hors de la branche, et rien d'autre. Ne pas commiter.

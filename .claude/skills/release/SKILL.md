---
name: release
description: Publie une version du projet — branche release/x.y.z (ou hotfix/x.y.z), version proposée et CHANGELOG généré par git-cliff depuis les commits, contrôles (tests, lint, ARCHITECTURE.md, milestone), PR revue par /audit-pr, fusion, tag vX.Y.Z et release GitHub, puis report dans develop — toutes les écritures par git-ops. À utiliser dès que l'utilisateur veut sortir, publier, livrer ou taguer une version (« /release », « fais la release », « on sort la 1.4 », « publie une version », « tague la v0.3.0 », « prépare la release », « fais un hotfix », « où en est la release ? »), et pour reprendre une release commencée. Pas pour envoyer une feature en revue (/ship), relire ou fusionner une PR ordinaire (/audit-pr), ni coder une issue (/feature).
argument-hint: "[x.y.z | hotfix [n° d'issue du bug]] [essai]"
---

# /release

Une release regroupe les features fusionnées depuis la dernière version, et les publie sous un numéro : un tag `vX.Y.Z` sur `main`, une section de `CHANGELOG.md` et une release GitHub. Elle passe par une PR et `/audit-pr`, comme tout changement.

Chacun son rôle : la session principale **prépare** (version, changelog, contrôles) et rédige les briefs. **`git-ops`** fait toutes les écritures Git et GitHub : issue, branche, commit, push, PR, fusion, tag, release. Le hook `git-guard` les refuse aux autres. `auditor` relit chaque PR, et l'**utilisateur** valide la version, le changelog et chaque fusion.

**En local** : l'image sur GHCR et la PR de version dans `homelab` (que ArgoCD déploie) arrivent avec la CI, en phase 10. Le compte rendu le rappelle.

**Mode essai** : si l'utilisateur demande un essai ou « sans publier », rien ne part sur GitHub et aucune branche n'est créée. Les étapes 1 à 3 se font normalement. La version, la section du changelog, les résultats des contrôles et les briefs qui auraient suivi vont dans le fichier qu'il indique, ou par défaut dans `Join-Path ([IO.Path]::GetTempPath()) "release-vX.Y.Z.md"`, hors du dépôt. À la fin, remettre la copie sur sa branche de départ.

## 1. Situer le dépôt et la release

- **Le circuit** : `git fetch origin --tags`, puis `git ls-remote --heads origin develop`.
  - `develop` existe : **gitflow**. La release part de `origin/develop`, sa PR va dans `main` et se fusionne en `merge`, puis `main` est reporté dans `develop`.
  - Pas de `develop` : **`main` seul** (template). La release part de `origin/main`, et sa PR se fusionne en squash.
- **Une release inachevée** se reprend au lieu d'en commencer une autre. Ces contrôles se font à chaque `/release`, même sans branche de release : en squash, `merge-pr.ps1` supprime la branche à la fusion. Reprendre au premier qui échoue :
  1. **La dernière version du changelog est taguée** : la première ligne `## [X.Y.Z]` de `git show origin/main:CHANGELOG.md` a son tag (`git ls-remote --tags origin vX.Y.Z`). Pas de `CHANGELOG.md` sur `main`, ou aucune section versionnée : aucune release n'a encore été faite par `/release`, rien à contrôler ici. Sinon, la release X.Y.Z est fusionnée mais pas taguée : étape 6, avec sa PR (`gh pr list --state merged --head release/X.Y.Z --json number,mergeCommit`, ou `hotfix/X.Y.Z`). **Sans PR de release fusionnée** (CHANGELOG écrit à la main, tags sans `v`…), il n'y a pas de commit à taguer : s'arrêter et montrer l'écart à l'utilisateur, sans rien taguer.
  2. **Ce tag a sa release GitHub** (`gh release view vX.Y.Z`). Sinon : étape 6, dernière commande.
  3. **En gitflow, `main` est dans `develop`** (`git merge-base --is-ancestor origin/main origin/develop`). Sinon, le report de la dernière release manque : étape 7. Sans lui, la release suivante ne verrait pas le dernier tag depuis `develop`, et git-cliff remettrait dans le changelog des commits déjà publiés.
  4. **Aucune branche `release/*` ou `hotfix/*` n'est en cours** : pour chaque branche (`git ls-remote --heads origin 'release/*' 'hotfix/*'`), lire sa PR (`gh pr list --state all --head <branche> --json number,state`) :
     - `release/*` sans PR : étape 4, à partir du commit du changelog ;
     - `hotfix/*` sans PR : finir le hotfix (voir *Hotfix*) ;
     - PR ouverte : étape 5 ;
     - PR fusionnée : la branche n'est plus en cours, les contrôles 1 à 3 couvrent la suite. Proposer sa suppression, comme à l'étape 7, et continuer.

  Une reprise à l'étape 5 ou au-delà ne déplace pas la copie : la suite du point 1 ne s'applique qu'à une release qui commence.
- **La copie de travail** (sauf pour finir un hotfix) doit être propre (`git status --porcelain --untracked-files=all` vide) : la release se prépare sur le code exact de la source, pas sur un travail en cours. Sinon, s'arrêter et le dire. Noter la branche courante (`git branch --show-current`), puis se placer sur la source : `git switch --detach origin/<source>`. **Chaque fois que le skill s'arrête**, en essai comme en vrai, et à la fin de la release, remettre la copie sur cette branche (`git switch <branche>`).
- **git-cliff** : `git cliff --version` et un `cliff.toml` à la racine. Sans eux, s'arrêter : git-cliff s'installe par `winget install orhun.git-cliff`, et `cliff.toml` vient du harness.
- **Le dernier tag** se lit sur `main`, où il est posé : `git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main`. Aucun tag : c'est la première release. Le contrôle 3 ci-dessus garantit qu'en gitflow, `develop` le contient aussi.
- **Rien à publier** : `git log --oneline --no-merges <tag>..HEAD` est vide. S'arrêter et le dire.

## 2. Proposer la version et le changelog

- **La version** : `git cliff --bumped-version`. Une feature monte le mineur, un correctif le patch, un changement cassant le majeur (le mineur avant 1.0). Une version donnée en argument la remplace, si elle est plus grande que le dernier tag. Dans tous les cas, la version ne doit être ni déjà taguée (`git ls-remote --tags origin vX.Y.Z`), ni déjà une section de `CHANGELOG.md` : sinon, s'arrêter, c'est une release inachevée à reprendre.
- **Rien dans le changelog** : si `--bumped-version` rend le dernier tag, ou si la section n'a aucune entrée, les commits depuis le tag sont tous ignorés par git-cliff (`docs`, `chore`…). S'arrêter et le dire, en les citant : une release sans changement visible n'a pas de raison d'être.
- **La section** : `git cliff --unreleased --tag vX.Y.Z --strip header`. Elle reprend les commits Conventional Commits, groupés à la manière de Keep a Changelog (Added, Changed, Fixed, et Security pour le scope `security`). git-cliff ignore les commits `docs`, `test`, `build`, `ci`, `chore` et `style`, et ceux qui ne suivent pas le format : les citer à part, pour que l'utilisateur voie ce qui manque.
- La relire : une entrée obscure se reformule dans la section, en anglais, sans toucher aux commits.
- Montrer à l'utilisateur le dernier tag, les commits, la version proposée et la section, puis **attendre sa validation**. Les corrections s'appliquent avant toute écriture.

## 3. Contrôler avant de publier

Sur le code de la source, où la copie est placée :

- **Les tests et le lint** : `scripts/test.ps1` et `scripts/lint.ps1` s'ils existent (`pwsh -NoProfile -File …`). Un échec arrête la release : la correction passe par `/feature`, sur `develop` ou `main`.
- **`ARCHITECTURE.md`** : appeler le subagent `cartographer`, sans paramètre `model`, pour comparer le document au code. Trier ce qu'il rend :
  - **un écart** : un composant, un flux ou une donnée que le document décrit autrement que le code, qu'il omet ou qui n'existe plus. Il bloque la release, car `ARCHITECTURE.md` reflète le code réel à chaque version. La correction passe par sa propre PR, puis `/release` reprend ;
  - **pas un écart** : le texte du modèle, comme le renvoi vers `docs/adr/` quand aucun ADR n'est encore écrit, ou une section vide sur un sujet que le projet n'a pas. Le dire, sans bloquer.
- **Le milestone** de la version (`gh api "repos/{owner}/{repo}/milestones?state=all" --jq '.[] | {title, number}'`, titre `vX.Y.Z` ou `X.Y.Z`) : lister ses issues encore ouvertes (`gh issue list --milestone "<titre>" --state open --json number,title`). Les signaler, sans bloquer : l'utilisateur décide de les reporter à la version suivante ou d'attendre.

## 4. Ouvrir la release

**L'issue de la release** : chaque commit et chaque fusion citent une issue (`(#n)`). Chercher `Release vX.Y.Z` parmi les issues ouvertes (`gh issue list --state open --search "Release vX.Y.Z in:title" --json number,title`), sinon `git-ops` la crée. Son corps reprend la section du changelog. Pour un hotfix, c'est l'issue du bug.

**Le changelog** : insérer la section dans `CHANGELOG.md`, juste avant la première version (`## [`). Un `CHANGELOG.md` absent se crée par `git cliff --tag vX.Y.Z -o CHANGELOG.md`, qui écrit aussi l'en-tête et l'historique. Une section `## [Unreleased]` écrite à la main se fusionne dans la nouvelle, avec l'accord de l'utilisateur.

Écrire le corps de l'issue et la description de la PR dans des fichiers hors du dépôt (`Join-Path ([IO.Path]::GetTempPath()) "release-vX.Y.Z-issue.md"` et `"…-pr.md"`). La PR, en français :

```
Closes #<n>

## Ce que fait la PR
Release vX.Y.Z : <résumé en une phrase>.

## Changelog
<la section>

## Contrôles
<tests, lint, ARCHITECTURE.md, milestone : ce qui a été lancé et le résultat>

## Après la fusion
Tag vX.Y.Z, release GitHub<, report de main dans develop>.
```

Puis appeler `git-ops`, **sans paramètre `model`** :

```
/release vX.Y.Z (<gitflow | main seul>), depuis origin/<source>. La copie est sur origin/<source>, en HEAD détaché.
1. <Issue : gh issue create --title "Release vX.Y.Z" --body-file '<fichier-issue>' | Issue #<n> existante : rien à faire.>
2. Branche : git switch -c release/X.Y.Z
3. Ajouter CHANGELOG.md, et aucun autre fichier, puis commiter avec ce message, tel quel : chore(release): prepare vX.Y.Z (#<n>)
4. Pousser : git push -u origin release/X.Y.Z
5. PR : gh pr create --base main --head release/X.Y.Z --title "Release vX.Y.Z" --body-file '<fichier-pr>'
Si une étape échoue ou si un hook la refuse, arrête-toi et rapporte le message exact.
Rends : le numéro de l'issue, le SHA du commit, l'URL de la PR.
```

**Le titre entre guillemets doubles**, comme dans `/ship` : une apostrophe fermerait une chaîne entre apostrophes.

## 5. Faire relire et fusionner

Proposer **`/audit-pr <p>`**. Après un verdict `approve` et l'accord de l'utilisateur, appeler `git-ops` avec la commande exacte, à appliquer telle quelle :

```
/release vX.Y.Z : fusionne la PR #<p>, approuvée par auditor, avec cette commande telle quelle :
<gitflow : pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr <p> -Strategy merge
| main seul : pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr <p> -Subject "chore(release): vX.Y.Z (#<n>)">
Si le script refuse, arrête-toi et rapporte le message exact.
```

En `main` seul, la release se fusionne en squash, comme une feature : `-Strategy merge` ne vaut que pour le gitflow, où la branche doit garder son historique.

Une demande de changements se corrige sur la branche de release, par un commit de `git-ops`, puis `/audit-pr` repasse.

## 6. Taguer et publier

Le commit fusionné : `gh pr view <p> --json mergeCommit --jq .mergeCommit.oid`. Écrire les notes de la release (la section, sans sa ligne de titre) dans `Join-Path ([IO.Path]::GetTempPath()) "release-vX.Y.Z-notes.md"`, puis appeler `git-ops` :

```
/release vX.Y.Z : la PR #<p> est fusionnée dans main (commit <sha>).
1. git fetch origin
2. git tag -a vX.Y.Z <sha> -m "vX.Y.Z"
3. git push origin vX.Y.Z   (le tag seul : ni --tags, ni la branche)
4. gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file '<fichier-notes>'
Si une étape échoue ou si un hook la refuse, arrête-toi et rapporte le message exact.
Rends : l'URL de la release.
```

Si seule l'étape 4 échoue, le tag est publié : ne relancer que `gh release create`.

## 7. Reporter dans `develop` (gitflow)

`main` porte maintenant la release et son tag, que `develop` doit contenir : sans ça, la release suivante ne trouverait pas le tag dans son historique. `git-ops` ouvre la PR de report :

```
gh pr create --base develop --head main --title "Report de vX.Y.Z dans develop" --body-file '<fichier>'
```

Son corps dit ce qu'elle reporte (la release vX.Y.Z, #<n>), sans `Closes`. Puis `/audit-pr`, et `merge-pr.ps1 -Pr <q> -Strategy merge` avec l'accord de l'utilisateur. Si GitHub signale un conflit, s'arrêter et le montrer : il se résout avec l'utilisateur, sur une branche dédiée.

La branche `release/X.Y.Z` (ou `hotfix/X.Y.Z`) ne sert plus. Proposer sa suppression (`git push origin --delete <branche>`, par `git-ops`) : le hook la soumet à la confirmation de l'utilisateur.

## Hotfix

Un correctif urgent sur la version en production, sans embarquer le travail de `develop`. Il n'existe qu'en gitflow : en `main` seul, un correctif passe par `/feature` puis `/release`.

- **Démarrer** (`/release hotfix <n° du bug>`) : la version est le patch suivant le dernier tag. `git-ops` crée `hotfix/X.Y.Z` depuis `origin/main` (`git switch --no-track -c hotfix/X.Y.Z origin/main` : sans `--no-track`, elle suivrait `main`, et un simple `git push` pourrait y écrire), puis la pousse (`git push -u origin hotfix/X.Y.Z`). Le skill s'arrête là : le correctif se code sur cette branche, avec son test (par `dev`), puis `/review`.
- **Finir** (`/release` sur `hotfix/*`) : comme une release, mais la copie reste sur la branche du hotfix, sans HEAD détaché, et l'issue est celle du bug.
  - Un correctif pas encore commité est le seul travail admis dans la copie. Il passe d'abord par `git-ops`, avec ses fichiers un par un et le message `fix(<scope>): <description> (#<bug>)`, sans pousser : git-cliff ne voit que les commits. En mode essai, rien n'est commité, et son entrée s'ajoute à la main dans la section.
  - Les étapes 2 et 3 suivent, sur la branche du hotfix. Le brief de l'étape 4 n'a ni issue ni branche à créer : il commite le changelog, pousse `hotfix/X.Y.Z` et ouvre la PR vers `main` (`Closes #<bug>`).
  - Puis tag, release et report dans `develop`, comme une release.

## 8. Rendre compte

```
**/release vX.Y.Z** (<gitflow | main seul | hotfix>) — <publiée | essai | arrêtée : <raison>>

Tag : vX.Y.Z sur <sha court> · Release : <URL>
PR : #<p> (release)<, #<q> (report dans develop)>
Changelog : <n> entrées (<Added a, Fixed b…>)
Contrôles : tests <…>, lint <…>, ARCHITECTURE.md <à jour | écart : …>, milestone <…>
En attente de la phase 10 : image sur GHCR, PR de version dans homelab.
```

En mode essai, rappeler le fichier écrit. Dans tous les cas, remettre la copie sur sa branche de départ (`git switch <branche>`).

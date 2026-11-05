---
name: ship
description: Envoie le travail terminé d'une branche en revue. Le skill vérifie les fichiers, les tests et le lint, fait commiter et pousser par git-ops avec un message `type(scope): … (#n)`, ouvre la PR `Closes #n` vers la bonne base (ou met à jour celle qui existe), et passe la carte de l'issue en « En revue ». À utiliser dès que le travail d'une branche est prêt à partir : « ship », « envoie », « pousse et ouvre la PR », « c'est prêt, fais la PR », « on peut passer en revue », et à la fin de /feature. Pas pour fusionner (c'est /audit-pr), ni pour une relecture rapide du diff (c'est /review).
argument-hint: "[n° d'issue] [essai]"
---

# /ship

Le circuit d'une feature est `/feature` → `/review` → **`/ship`** → `/audit-pr` → fusion. `/ship` transforme le travail terminé d'une branche en une PR prête pour la revue : un commit propre, une PR qui dit ce qu'elle fait et comment la vérifier, et une carte qui avance sur le board.

La session principale prépare et rédige, parce qu'elle connaît l'intention du changement. **`git-ops` exécute** : c'est le seul agent autorisé à commiter, pousser, ouvrir une PR et déplacer une carte (le hook `git-guard` le refuse aux autres). Il travaille avec un modèle léger : son brief doit être complet et sans ambiguïté.

**Mode essai** : si l'utilisateur demande un essai ou « sans publier », le commit se fait en local, mais rien n'est poussé, aucune PR n'est créée et le board ne bouge pas. Le titre et la description de la PR, et la liste de ce qui aurait été fait, vont dans un fichier.

## 1. Situer la branche et l'issue

- `git branch --show-current`, `git status --porcelain --untracked-files=all`.
- **Base** : `develop` s'il existe sur le dépôt distant (`git ls-remote --heads origin develop`), sinon `main`.
- **Issue** : le numéro donné en argument, sinon celui du nom de branche (`feature/<n>-…`, `fix/<n>-…`). À défaut, demander : une PR sans issue liée est refusée par la revue (une PR = une issue). Lire l'issue (`gh issue view <n> --json title,body,state,labels`) : ses critères d'acceptation iront dans la PR.
- **PR existante** : `gh pr view --json number,url,state,headRefOid,body,comments` sur la branche courante.
- **Commits pas encore poussés** : `git fetch origin`, puis `git rev-list --count origin/<branche>..HEAD` si la branche existe sur `origin`, sinon `git rev-list --count origin/<base>..HEAD`. Ne pas se fier à `@{u}` : une branche créée par `git switch -c <branche> origin/develop` suit `develop`, et non une branche distante à son nom. Après un essai, ou après un `/ship` interrompu, le travail est déjà commité : l'arbre est propre, mais il reste des commits à envoyer.

Selon la branche :
- **`main` ou `develop`** : ne rien commiter dessus, le push serait refusé et le travail mélangé à la base. Proposer de créer `feature/<n>-<slug>` (ou `fix/…`) à partir de l'état courant : les modifications non commitées suivent la branche (`git switch -c`). Attendre l'accord.
- **`release/*` ou `hotfix/*`** : ce n'est pas le rôle de `/ship`. Renvoyer vers `/release` s'il existe dans le projet, sinon s'arrêter et le dire.
- **PR fermée ou fusionnée** : s'arrêter et le dire, une nouvelle branche est sans doute nécessaire.
- **Rien à commiter ni à pousser** : si la PR existe, le dire, et ne mettre à jour que sa description ou sa carte si elles sont en retard. Sinon, ouvrir la PR à partir des commits déjà poussés. Si la branche n'a aucun commit d'avance sur `origin/<base>`, il n'y a rien à envoyer : le dire et s'arrêter.

## 2. Contrôler avant d'envoyer

Le but : que la PR arrive en revue sans surprise.

- **Les fichiers** : passer en revue la liste de `git status`. Écarter, et signaler, ce qui n'a rien à faire dans un commit : fichier de secrets ou de config locale (`.env*` sauf `.env.example`, `.env.sample`, `.env.template` et `.env.dist`, `*.pem`, `*.key`, `secrets*`), fichier de données (dump, export `*.csv`, base `*.db` ou `*.sqlite` : gitleaks ne les voit pas, et ils peuvent contenir des données personnelles), fichier de travail (`notes.md`, `PLAN.md`, `TODO.md` hors `docs/`), journal, sortie de build, fichier sans rapport avec l'issue. Une donnée de test que la feature ajoute exprès reste, et le compte rendu la signale. Ne jamais ouvrir un fichier de secrets pour vérifier : son nom suffit. En cas de doute, demander plutôt que commiter.
- **Les tests et le lint** : `scripts/test.ps1` et `scripts/lint.ps1` s'ils existent (`pwsh -NoProfile -File …`). S'ils échouent, s'arrêter : une PR rouge fait perdre une revue. Proposer la correction (par `dev` pour le code, `linter` pour le lint). S'ils n'existent pas, le noter dans la PR (« Comment la vérifier »).
- **`/review`** : s'il existe dans le projet et n'a pas tourné pendant la session, le proposer avant d'envoyer, sans l'imposer.
- **La taille** : `git diff --shortstat origin/<base>...HEAD` (après le `fetch` de l'étape 1) plus le travail non commité. Au-delà de 1 500 lignes modifiées, hors fichiers générés et lockfiles, le signaler et proposer un découpage. Cela ne bloque pas.
- **Une revue déjà approuvée** : la PR existante porte peut-être un verdict `approve` d'`auditor` sur son dernier commit. Pour le savoir, lire les `comments` récupérés à l'étape 1, comme `merge-pr.ps1` : ne retenir que ceux du compte courant (`gh api user --jq .login`), puis le dernier qui contient `auditor: sha=`, et comparer son SHA à `headRefOid`. Ne pas mettre l'ouverture du commentaire HTML dans un filtre `--jq` : `git-guard` le refuse. Le nouveau commit annule l'approbation (`merge-pr.ps1` ne fusionne que le commit revu). Demander `/ship` après une retouche, c'est accepter ce coût : continuer sans redemander, et le dire clairement dans le compte rendu, avec la relance de `/audit-pr` à faire.

## 3. Rédiger

**Le message de commit**, en anglais, Conventional Commits, numéro d'issue en fin de titre :
`feat(api): add PDF export for invoices (#42)`. Type selon le changement (`feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `chore`), scope court en minuscules. Un corps, facultatif, dit le pourquoi en deux ou trois lignes.

**La PR**, en français. Si elle existe déjà, ne réécrire sa description que si elle est périmée : un critère est rempli depuis, ou « Comment la vérifier » cite d'anciens résultats. Partir alors du `body` lu à l'étape 1. Sinon :
- titre : ce que la PR apporte, en une ligne ;
- description : suivre `.github/pull_request_template.md` s'il existe, sinon ce plan :

```
Closes #<n>

## Ce que fait la PR
## Comment la vérifier
## Critères d'acceptation
- [x] <critère de l'issue rempli>
- [ ] <critère non rempli : dire pourquoi>
## Points d'attention pour la revue
```

« Comment la vérifier » cite ce qui a été lancé et le résultat (« `scripts/test.ps1` : 48 tests verts »). Les critères viennent de l'issue, cochés seulement s'ils sont vraiment remplis : la revue `auditor` les contrôle un à un. Écrire la description dans un fichier temporaire **hors du dépôt** (`Join-Path ([IO.Path]::GetTempPath()) "ship-<n>.md"`, en UTF-8).

## 4. Confier l'envoi à `git-ops`

Appeler le subagent `git-ops`, **sans paramètre `model`** (le hook `model-guard` le refuse). Brief complet :

```
/ship de la branche <branche> (issue #<n>), base <base>.
1. <Ajouter ces fichiers un par un, et aucun autre : <liste>.
   | Rien à ajouter : le travail est déjà commité.>
   Ne pas ajouter, et laisser tels quels : <fichiers écartés, ou « rien »>.
2. <Commiter avec ce message, tel quel : <message>
   | Rien à commiter.>
3. <Pousser : git push -u origin <branche>. | Rien à pousser.>
4. <PR à créer : gh pr create --base <base> --head <branche> --title "<titre>" --body-file <fichier>
   | PR #<p> existante, description à mettre à jour : gh pr edit <p> --body-file <fichier>
   | PR #<p> existante : rien à faire, le push la met à jour.>
5. Carte de l'issue en « En revue » : pwsh -NoProfile -File .harness/tools/board.ps1 -Issue <n> -Status 'En revue'
   (sans effet si elle y est déjà).
Si une étape échoue ou si un hook la refuse (gitleaks au commit, git-guard…), t'arrêter et me rapporter le message exact, sans contourner ni improviser.
Rends-moi : le SHA du dernier commit, l'URL de la PR, et le résultat de chaque étape.
```

Après un échec, relancer `/ship` reprend là où l'envoi s'est arrêté : l'étape 1 voit ce qui est déjà commité et poussé, et le brief ne contient que ce qui reste à faire.

En **mode essai**, le brief s'arrête à l'étape 2, et la session principale écrit dans le fichier demandé le titre, la description de la PR et les étapes 3 à 5 qui auraient été faites. Le vrai `/ship` qui suit trouve un arbre propre, avec des commits à pousser.

## 5. Rendre compte

En quelques lignes : SHA du commit, URL de la PR, ce qui a été écarté ou signalé (fichiers, taille, tests absents), et la carte déplacée. Puis proposer **`/audit-pr`**, seul chemin vers la fusion.

Dans `homelab`, le circuit est le même : PR obligatoire, même pour de la doc. La fusion y reste à l'utilisateur.

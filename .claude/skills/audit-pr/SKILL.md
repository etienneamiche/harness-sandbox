---
name: audit-pr
description: Revue complète d'une PR avant sa fusion, confiée au subagent auditor, qui publie son verdict (approve ou changes) en commentaire sur la PR. À utiliser dès qu'il est question de fusionner une PR ou de la valider — « audite la PR », « revue avant fusion », « on peut merger ? », « la PR est prête » —, quand merge-pr.ps1 refuse faute de revue ou parce que la PR a reçu des commits depuis, après des corrections faites suite à une revue auditor, et aussi pour une revue à blanc ou un essai sans publier. Aucune PR ne se fusionne sans ce skill.
argument-hint: "[n° de PR] [essai]"
---

# /audit-pr

Une PR ne se fusionne que par `.harness/tools/merge-pr.ps1`, et ce script exige un verdict `approve` de `auditor` posé sur **le dernier commit** de la PR. Ce skill produit ce verdict : la session principale prépare le terrain, `auditor` (Opus) fait la revue et publie le commentaire, puis la session principale rend compte et propose la suite.

La session principale ne fait pas la revue elle-même et n'écrit jamais le marqueur `<!-- auditor: … -->` : le hook `git-guard` le refuse à tout autre agent qu'`auditor`, parce qu'un agent qui l'écrirait s'auto-approuverait.

## 1. Identifier la PR

- Numéro donné en argument, sinon la PR de la branche courante : `gh pr view --json number`. Sans PR trouvée, demander le numéro.
- Lire l'état utile en un appel :
  `gh pr view <n> --json number,url,state,isDraft,title,headRefName,baseRefName,headRefOid,closingIssuesReferences,comments`
- Une PR fermée ou fusionnée ne s'audite pas : le dire et s'arrêter.
- Une PR en brouillon (`isDraft`) s'audite quand même. Le compte rendu rappelle qu'elle doit passer en « prête » avant la fusion (`gh pr ready <n>`, par `git-ops`).

**Mode essai** : si l'utilisateur demande un essai, une revue « à blanc » ou « sans publier », `auditor` écrit le commentaire dans un fichier et ne publie rien. Le verdict n'a alors aucune valeur pour `merge-pr.ps1` : le dire dans le compte rendu.

## 2. Premier passage ou revue après corrections

Chercher dans les `comments` lus à l'étape 1 les marqueurs de revue (`auditor: sha=<sha> verdict=<v>`, dans un commentaire HTML) écrits par le compte courant (`gh api user --jq .login`). Les marqueurs d'un autre compte ne comptent pas : les dépôts sont publics. Les lire dans ce JSON, sans relancer de commande : **ne jamais écrire l'ouverture du commentaire HTML suivie de `auditor:` dans une commande `gh`**, même en lecture (un filtre `--jq`, par exemple) : `git-guard` la refuse hors `auditor`. Pour filtrer, chercher `auditor: sha=`.

- **Aucun marqueur** : premier passage, sur la PR entière.
- **Un marqueur sur le SHA de tête** : la revue est déjà à jour. Rappeler son verdict, et ne relancer que si l'utilisateur le demande, par exemple après une correction faite hors du code (issue liée, description de la PR). On relance alors comme une revue après corrections, sur le même SHA, en transmettant la revue précédente à `auditor` : il vérifie d'abord que ses constats sont corrigés.
- **Un marqueur sur un SHA plus ancien** : revue après corrections. On transmet à `auditor` le SHA déjà revu et le texte de la dernière revue. C'est dans les corrections qu'on trouve le plus de régressions : elles se vérifient en priorité, puis la PR entière est réévaluée.

Le numéro de passage est le nombre de marqueurs du compte courant, plus un.

## 3. Préparer la copie locale

`auditor` exécute les tests au lieu de se contenter de lire le diff : il lui faut le commit revu en local.

- `git status --porcelain` vide et branche courante = `headRefName` : `git pull --ff-only`, puis vérifier que `git rev-parse HEAD` vaut `headRefOid`. En cas d'écart (des commits locaux pas encore poussés, par exemple), ne pas revoir un code qui n'est pas celui de la PR : proposer de les pousser par `git-ops` puis de relancer, ou lancer la revue avec « copie locale : non disponible ».
- Copie propre sur une autre branche : `gh pr checkout <n>`, et noter la branche d'origine pour y revenir à la fin.
- Modifications non commitées : ne rien toucher. Demander à l'utilisateur, ou lancer la revue sans exécution locale, en le signalant (la revue le dira dans sa méthode).

## 4. Confier la revue à `auditor`

Appeler le subagent `auditor`, **sans paramètre `model`** (le hook `model-guard` le refuse : le modèle est imposé par l'agent). Lui transmettre un brief complet, car il ne voit pas cette conversation :

```
Revue /audit-pr de la PR #<n> (<url>), passage n° <k>.
- Commit à revoir : <headRefOid> (branche <head> → <base>). Copie locale : <à jour sur ce commit | non disponible, pourquoi>.
- Issue liée : #<i> (ses critères d'acceptation font partie de la revue) | aucune.
- Revue précédente : aucune | sur <sha>, verdict <v>. Son texte : <le commentaire précédent>.
- Publication : gh pr comment <n> --body-file <fichier> | mode essai : écrire le commentaire dans <chemin>, ne rien publier.
Suis le guide .claude/skills/audit-pr/references/review-guide.md (méthode, format, marqueur).
Rends-moi : le verdict, le nombre de constats par gravité, et l'URL du commentaire (ou le chemin du fichier en mode essai).
```

## 5. Rendre compte et proposer la suite

Résumer en quelques lignes : verdict, constats bloquants et importants (un par ligne, avec `fichier:ligne`), lien vers le commentaire. Si une branche a été changée à l'étape 3, revenir sur la branche d'origine.

- **`changes`** : proposer de confier les corrections du code à `dev`, et celles de la PR elle-même (issue à lier, description) à `git-ops`, puis de relancer `/audit-pr` (le verdict ne vaut que pour le commit revu).
- **`approve`** : proposer la fusion, **sans la lancer avant l'accord de l'utilisateur** :
  - feature ou fix : squash, avec un `-Subject` en anglais, Conventional Commits, terminé par le numéro de l'issue liée (à défaut, celui de la PR) :
    `pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr <n> -Subject "feat(api): add PDF export for invoices (#42)"`
  - branche `release/*` ou `hotfix/*` : `-Strategy merge`, sans `-Subject`.
  - Une fois l'accord donné, la fusion est confiée à `git-ops` (seul agent autorisé à lancer `merge-pr.ps1`).
  - **Dépôt `homelab`** : ne jamais proposer de fusion par un agent. Fusionner, c'est déployer : l'utilisateur le fait à la main.
- **Mode essai** : rappeler que rien n'a été publié et indiquer le fichier.

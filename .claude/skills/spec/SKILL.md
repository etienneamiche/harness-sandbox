---
name: spec
description: Rend une issue prête à développer — critères d'acceptation vérifiables, impacts, plan court, taille et hors-périmètre, rédigés par le subagent architect avec des options à trancher pour un choix structurant — puis, après validation, git-ops met à jour l'issue et passe sa carte en « Prêt », et le skill propose /feature. À utiliser dès que l'utilisateur veut préciser, spécifier, cadrer ou préparer une issue numérotée avant de la coder (« /spec 42 », « spécifie l'issue 42 », « rédige les critères de la 17 », « prépare le ticket 9 pour le dev », « passe la 12 en Prêt », « qu'est-ce qu'il faudrait faire pour l'issue des alertes ? »), y compris un bug à cadrer. Pas pour noter une nouvelle idée (/idea), coder l'issue (/feature), ni relire du code (/review).
argument-hint: "<n° d'issue> [essai]"
---

# /spec

Le circuit d'une idée est `/idea` → **`/spec`** → `/feature` → `/review` → `/ship` → `/audit-pr` → fusion. `/spec` fait passer une issue de « Idée » à « Prêt » : il fixe ce que « fini » veut dire. Ses critères d'acceptation sont ceux que `dev` remplira et qu'`auditor` contrôlera un à un. Une spécification floue se paie donc deux fois, à l'implémentation puis à la revue.

Chacun son rôle : **`architect`** (Opus) conçoit la spécification, **`git-ops`** met à jour l'issue et déplace la carte, l'**utilisateur** tranche et valide. La session principale orchestre. `/spec` n'écrit rien dans le dépôt, ni code, ni branche, ni document : ce qui doit y entrer (un ADR, une doc) devient un critère de l'issue, livré par la PR de la feature et relu avec elle.

**Mode essai** : si l'utilisateur demande un essai ou « sans publier », l'issue n'est pas modifiée et la carte ne bouge pas. La spécification et les gestes GitHub qui auraient suivi vont dans le fichier qu'il indique, ou par défaut dans `Join-Path ([IO.Path]::GetTempPath()) "spec-<n>.md"`, hors du dépôt. Le mode essai ne touche que GitHub : les choix et la validation se font comme d'habitude, dans la conversation.

## 1. Lire l'issue et situer le travail

- `gh issue view <n> --json number,title,body,labels,state`. Une issue fermée : s'arrêter et le dire.
- **Le travail a-t-il commencé ?** Le vérifier avant toute question. Chercher une branche (`git branch --list 'feature/<n>-*' 'fix/<n>-*'` et `git ls-remote --heads origin 'feature/<n>-*' 'fix/<n>-*'`) et une PR ouverte (`gh pr list --state open --json number,headRefName,body`, dont la branche contient `/<n>-` ou le corps cite `#<n>` sans autre chiffre à la suite : `#3` ne doit pas trouver `#32`). Si oui, prévenir que changer les critères change la cible d'un travail en cours, et ne continuer qu'avec l'accord de l'utilisateur. La carte ne reviendra pas alors en « Prêt » : elle est déjà plus loin.
- **Le besoin** : si l'issue ne dit pas pour qui, quel problème et ce qui est attendu, poser les questions qui manquent, toutes dans un seul message numéroté, et attendre la réponse. `architect` ne peut pas spécifier un besoin qu'il devine.
- **Un bug** (label `bug`) se spécifie aussi : les critères disent que le cas décrit fonctionne et qu'un test le couvre (il échoue sans la correction). Les impacts partent de la cause probable.

## 2. Faire concevoir la spécification par `architect`

Noter d'abord l'état de la copie de travail : `git status --porcelain --untracked-files=all`. Il sert de point de comparaison après `architect`.

Appeler le subagent `architect`, **sans paramètre `model`** (le hook `model-guard` le refuse). Brief :

```
Spécifie l'issue #<n> : <titre>.
Type : <feature | bug>. Pour un bug, les critères disent que le cas décrit fonctionne et qu'un test le couvre (il échoue sans la correction), et les impacts partent de la cause probable.
Issue : <corps complet>.
<Réponses de l'utilisateur aux questions, s'il y en a eu.>
Pars de l'existant : AGENTS.md, ARCHITECTURE.md, docs/ et docs/adr/, et le code (codegraph d'abord).
Rends, sans rien écrire dans le dépôt :
1. Les critères d'acceptation, vérifiables un à un par un relecteur (un comportement observable, un fichier, un test), cinq à dix en général.
2. Les impacts : fichiers et modules touchés, migrations de données, sécurité (entrées, secrets, droits), dépendances ajoutées.
3. Un plan court, dans l'ordre, et une estimation de taille en lignes modifiées.
4. Ce qui reste hors périmètre.
5. Un choix structurant (nouvelle dépendance majeure, motif d'architecture, besoin d'infra) : 2 ou 3 options avec leurs compromis et ta recommandation, sans trancher à la place de l'utilisateur. Un besoin que l'écosystème ne couvre pas encore se signale, sans être contourné.
6. Les questions ouvertes qui restent.
```

Relire ce qu'il rend avant de le montrer : chaque critère doit pouvoir se vérifier sans interprétation. « Le script est robuste » ne se vérifie pas ; « un CSV verrouillé est ignoré et signalé, les autres sont archivés » se vérifie. Reformuler ce qui doit l'être.

Vérifier aussi qu'il n'a rien écrit : relancer `git status --porcelain --untracked-files=all` et comparer avec l'état noté avant son appel. `architect` a les outils d'écriture et sa définition l'invite à écrire dans `docs/`. Seule la différence compte, car des modifications déjà présentes avant `/spec` appartiennent à l'utilisateur. Un fichier apparu ou modifié entre-temps se signale à l'utilisateur, qui décide de son sort : laissé là, il bloquerait le `/feature` suivant comme du travail non commité.

## 3. Faire trancher et valider

- **Les options** d'un choix structurant : les présenter avec leurs compromis et la recommandation d'`architect`, puis **attendre la décision**. La spécification se finalise ensuite selon l'option choisie, que la session intègre elle-même ou fait reprendre par `architect` si elle change le plan en profondeur.
- **Une décision structurante appelle un ADR** (conventions : `docs/adr/NNNN-titre-court.md`). `/spec` ne l'écrit pas. La décision et ses raisons vont dans les Notes de l'issue, et l'ADR devient un critère : « ADR `docs/adr/NNNN-…` qui consigne <la décision> ».
- **Un manque de l'écosystème** signalé par `architect` (une techno, un service qu'aucun module ne couvre) : le montrer à l'utilisateur, le noter dans les Notes de l'issue, et ne pas planifier de contournement local. C'est un sujet pour `/evolve`, comme le dit la définition d'`architect`.
- **Au-delà d'environ 1 500 lignes**, hors fichiers générés, proposer un découpage. Avec l'accord de l'utilisateur, l'issue garde la première partie et sa spécification. Les autres parties deviennent de nouvelles issues `feature` en « Idée » : chacune passera par son propre `/spec`. Rédiger le titre et le corps de chacune selon le modèle `feature` (le Besoin de la partie, « À préciser par `/spec` » en critères, « Découpée de #<n> » dans les Notes) : elles partent sur GitHub, donc l'utilisateur les valide comme le reste.
- Montrer le corps complet de l'issue mise à jour, et celui de chaque nouvelle issue, puis **les faire valider**. Les corrections s'appliquent avant toute écriture sur GitHub.

Le corps mis à jour garde le **Besoin** tel quel (c'est la parole de l'utilisateur) et remplace les critères provisoires :

```markdown
## Besoin

<inchangé>

## Critères d'acceptation

- [ ] <critère vérifiable>

## Impacts

<fichiers et modules, migrations, sécurité, dépendances>

## Plan

1. <étape>

Taille estimée : <~n lignes>

## Hors périmètre

<ce que l'issue ne fait pas>

## Notes

<notes d'origine, décisions prises et leurs raisons, questions ouvertes>
```

Pour un bug, garder les sections du modèle `bug` (ce qui se passe, ce qui est attendu, comment reproduire, environnement) à la place du Besoin.

## 4. Faire mettre à jour l'issue par `git-ops`

Écrire le corps validé dans un fichier hors du dépôt (`Join-Path ([IO.Path]::GetTempPath()) "spec-<n>.md"`), puis appeler le subagent `git-ops` :

```
/spec de l'issue #<n>, validée par l'utilisateur.
1. Corps de l'issue : gh issue edit <n> --body-file '<fichier>'
2. Carte en « Prêt » : pwsh -NoProfile -File .harness/tools/board.ps1 -Issue <n> -Status 'Prêt'
Si une étape échoue ou si un hook la refuse, arrête-toi et rapporte le message exact.
```

- **Travail déjà commencé** : pas d'étape 2 du brief.
- **Découpage accepté** : avant le brief ci-dessus, un premier appel à `git-ops` crée les nouvelles issues, pour que l'issue d'origine puisse citer leurs numéros. Le corps validé de chaque partie va dans `Join-Path ([IO.Path]::GetTempPath()) "spec-<n>-partie-<k>.md"` (k = 2, 3… : la partie 1 reste dans #<n>). Brief :

  ```
  /spec de l'issue #<n> : découpage validé par l'utilisateur. Crée les nouvelles issues, dans l'ordre.
  Pour chaque partie k :
  1. gh issue create --title "<titre de la partie k>" --body-file '<fichier de la partie k>' --label feature
  2. pwsh -NoProfile -File .harness/tools/board.ps1 -Issue <numéro créé> -Status 'Idée'
  Si une création échoue ou si un hook la refuse, arrête-toi. Si seul board.ps1 échoue, continue avec la partie suivante.
  Rends, pour chaque partie, le numéro créé (ou « non créée ») et le résultat de board.ps1, avec le message exact de chaque échec.
  ```

  La session reporte les numéros dans le Hors périmètre de l'issue d'origine (« Suite : #m, #p »), puis le brief ci-dessus la met à jour. Une partie non créée ne se rattrape pas en relançant tout l'appel : les autres existent déjà, une relance les créerait en double. Le dire à l'utilisateur, et ne recréer que la partie manquante, avec son accord. Une carte non placée se signale dans le compte rendu.
- **Le titre entre guillemets doubles**, comme dans `/ship` : une apostrophe, courante en français, fermerait une chaîne entre apostrophes. Les guillemets doubles interprètent en revanche `$`, le backtick et tout guillemet double, droit (`"`) ou typographique (`“ ”`, que pwsh lit comme `"`) : un titre qui en contient se reformule sans eux, avec « » si besoin.
- Si seule l'étape 2 du brief échoue (pas de Project sur le compte, réseau…), l'issue est à jour : le signaler, sans refaire l'étape 1 du brief.
- **Mode essai** : pas d'appel à `git-ops`. Écrire le corps et ces commandes dans le fichier d'essai, et pour un découpage, le titre et le corps de chaque nouvelle issue avec le brief qui les aurait créées.

## 5. Rendre compte et proposer `/feature`

```
**/spec #<n>** : <titre> — carte <« Prêt » | inchangée : essai, travail en cours ou échec de board.ps1>

Critères : <nombre>
Taille estimée : <~n lignes>
Décisions : <option retenue, ADR prévu | aucune>
Découpage : <#m, #p créées en « Idée », carte non placée ou partie non créée précisée | aucun>
Manques de l'écosystème : <… , pour /evolve | aucun>
Questions ouvertes : <… | aucune>
```

Puis proposer **`/feature <n>`**, sans le lancer : c'est lui qui crée la branche et fait coder.

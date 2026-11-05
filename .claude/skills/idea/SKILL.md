---
name: idea
description: Transforme une idée de fonctionnalité en issue feature de ce projet, carte en « Idée » — besoin clarifié par quelques questions au plus, doublons cherchés, découpage proposé si l'idée dépasse une PR, brouillon validé, puis création par git-ops — et propose /spec. À utiliser dès que l'utilisateur a une idée, un souhait ou une demande de fonctionnalité à noter ou à mettre au backlog, même formulée en passant (« /idea », « j'ai une idée », « on pourrait ajouter un export PDF », « ce serait bien que… », « note ça pour plus tard », « ouvre une issue pour le mode sombre », « mets-le dans le board »). Pas pour préciser une issue existante (/spec), la coder (/feature), signaler un bug (modèle d'issue bug), ni noter une idée de nouveau projet (/project-idea, à la racine).
argument-hint: "[idée en une phrase] [essai]"
---

# /idea

Le circuit d'une idée est **`/idea`** → `/spec` → `/feature` → `/review` → `/ship` → `/audit-pr` → fusion. `/idea` fait la première marche : il transforme une idée en issue `feature`, rangée dans la colonne « Idée » du board. Il capture le **besoin**, pas la solution. Les critères définitifs, les impacts et le plan sont le travail de `/spec`. Le code est celui de `/feature`.

La session principale mène l'échange et rédige l'issue. **`git-ops`** la crée et place la carte : git-guard lui réserve `gh issue create` et `board.ps1`. Rien ne part sur GitHub sans que l'utilisateur ait validé le brouillon, car une issue publiée se voit et se partage.

**Mode essai** : si l'utilisateur demande un essai ou « sans publier », aucune issue n'est créée et aucune carte ne bouge. Le ou les brouillons, et les gestes GitHub qui auraient suivi, vont dans le fichier qu'il indique, ou par défaut dans `Join-Path ([IO.Path]::GetTempPath()) "idea-<slug>.md"`. Ce fichier reste hors du dépôt, pour ne pas passer pour du travail non commité. Le mode essai ne touche que GitHub : les questions et la validation du brouillon se font comme d'habitude, dans la conversation.

## 1. Situer l'idée

Un **bug** n'est pas une idée : quelque chose qui marchait, ou devrait marcher, et ne marche pas. Ne rien créer, et renvoyer vers le modèle d'issue `bug` (`.github/ISSUE_TEMPLATE/bug.md`), qui demande les étapes pour reproduire le problème.

Une idée de **nouveau projet**, et non une fonctionnalité de ce projet, relève de `/project-idea` à la racine de l'écosystème : le dire.

Sinon, **chercher les doublons** avant toute question : une idée déjà couverte n'a pas besoin d'être clarifiée, et une issue voisine aide à poser les bonnes questions. Chercher les issues ouvertes proches, avec deux ou trois jeux de mots-clés tirés de l'idée :

```
gh issue list --state open --search "<mots-clés>" --json number,title,labels --limit 10
```

- **Une issue couvre déjà l'idée** : le dire, avec son numéro et son titre, et proposer de la compléter par un commentaire au lieu d'en créer une autre. Deux issues pour le même besoin finissent en deux branches concurrentes.
- **Des issues voisines** : les citer dans les « Notes » du brouillon, pour que `/spec` les voie.
- Rien de proche : continuer sans le mentionner longuement.

## 2. Compléter le besoin

Partir de ce que l'utilisateur a déjà dit. Il faut quatre choses pour écrire une bonne issue :
- **pour qui** : quel utilisateur ou quel usage ;
- **quel problème** : ce qui manque ou gêne aujourd'hui ;
- **pourquoi maintenant** : ce qui rend la chose utile ou urgente, si c'est le cas ;
- **ce qui est hors périmètre** : ce que l'idée ne fait pas.

Poser **seulement les questions qui manquent**, toutes dans un seul message et numérotées, pour qu'il réponde en une fois, puis **attendre sa réponse** avant de rédiger : un brouillon écrit sur des suppositions serait à refaire. Une idée déjà claire n'en déclenche aucune : reformuler et passer à la suite. Si l'idée appelle aussi un découpage (étape 3), le proposer dans le même message. Ce qui reste inconnu après sa réponse se note dans l'issue (« à préciser par `/spec` ») au lieu de prolonger l'échange.

## 3. Jauger la taille

Une issue doit tenir dans une PR : moins d'environ 1 500 lignes modifiées, hors fichiers générés. Estimer à grands traits ce que l'idée demande. Si elle dépasse nettement, **proposer un découpage** en plusieurs issues, chacune utile seule et livrable dans l'ordre. L'utilisateur choisit. Ne pas découper d'office.

## 4. Rédiger le brouillon

Suivre le modèle `.github/ISSUE_TEMPLATE/feature.md` du projet, s'il existe :

```markdown
## Besoin

<pour qui, quel problème, pourquoi maintenant>

## Critères d'acceptation

- [ ] <critère provisoire, s'il est évident et vérifiable>
- [ ] À préciser par `/spec`.

## Hors périmètre

<ce que cette issue ne fait pas>

## Notes

<issues voisines, pistes évoquées par l'utilisateur, questions ouvertes>
```

- **Le titre** : court, à l'infinitif ou nominal, sans préfixe de type (« Exporter une facture en PDF »).
- **Les critères** : seulement ceux qui découlent clairement du besoin, formulés de façon vérifiable. Sinon, la ligne « À préciser par `/spec` ». En inventer serait décider à la place de l'utilisateur. `/feature` refuse d'ailleurs une issue sans critère vérifiable : `/spec` les complètera.
- **Pas de solution technique** imposée : une piste citée par l'utilisateur va dans les Notes, comme piste.

Montrer le brouillon (titre et corps) et **le faire valider**. Ses corrections s'appliquent avant la création.

## 5. Faire créer l'issue par `git-ops`

Écrire chaque corps validé dans un fichier hors du dépôt (`Join-Path ([IO.Path]::GetTempPath()) "idea-<slug>.md"`), puis appeler le subagent `git-ops` :

```
/idea : crée l'issue validée par l'utilisateur.
1. gh issue create --title "<titre>" --body-file '<fichier>' --label feature
2. Carte en « Idée » : pwsh -NoProfile -File .harness/tools/board.ps1 -Issue <n> -Status 'Idée'
Rends le numéro et l'URL de l'issue. Si une étape échoue ou si un hook la refuse, arrête-toi et rapporte le message exact.
```

- **Le titre entre guillemets doubles**, comme dans `/ship` : une apostrophe, courante en français (« Exporter l'historique »), fermerait une chaîne entre apostrophes et casserait la commande. Les guillemets doubles interprètent en revanche `$`, le backtick et tout guillemet double, droit (`"`) ou typographique (`“ ”`, que pwsh lit comme `"`) : un titre qui en contient se reformule sans eux, avec « » si besoin.
- **Le label `feature` absent** du dépôt fait échouer l'étape 1 du brief : `scripts/github-setup.ps1`, à la racine de l'écosystème, pose les labels. Le signaler, et proposer de créer l'issue sans label en attendant.
- **Plusieurs issues** (découpage accepté, ou plusieurs idées d'un coup) : un seul appel à `git-ops`, avec les deux étapes répétées pour chaque issue.
- **Compléter une issue existante** (section 1, « Situer l'idée ») : le brief devient `gh issue comment <n> --body-file '<fichier>'`, sans carte à déplacer.
- Si seule l'étape 2 du brief échoue (pas de Project sur le compte, réseau…), l'issue existe : le signaler dans le compte rendu, sans recréer l'issue.
- **Mode essai** : pas d'appel à `git-ops`. Écrire les brouillons et ces commandes dans le fichier d'essai.

## 6. Rendre compte et proposer `/spec`

```
**/idea** : #<n> <titre> — <URL>, carte <« Idée » | inchangée : essai ou échec de board.ps1>

Besoin : <une phrase>
Critères : <provisoires | à préciser par /spec>
Voisines : <#a, #b | aucune>
```

Puis proposer **`/spec <n>`**, sans le lancer : c'est lui qui rend l'issue prête à développer. Plusieurs issues : une ligne par issue, et `/spec` sur la première à faire.

---
name: review
description: Relecture du travail en cours pendant le développement, par le subagent reviewer. À utiliser chaque fois que l'utilisateur demande un avis sur du code qu'il vient d'écrire ou de modifier, même sans dire « review » ni « diff » — relire, vérifier, chercher un problème, un oubli ou un critère manquant, demander un second regard, sur la branche entière, ses modifications non commitées, ce qui est indexé ou un dossier précis, avant de continuer, de commiter ou de ship. La session ne relit pas elle-même : ce skill délimite le périmètre, confie la relecture à reviewer, vérifie chaque constat dans le code et rend « À corriger » / « À voir » avec fichier:ligne, sans rien modifier ni publier. Pas pour la revue complète d'une PR avant fusion (/audit-pr), pour commiter ou ouvrir la PR (/ship), ni pour corriger un bug déjà identifié.
argument-hint: "[chemin | indexé]"
---

# /review

Le circuit d'une feature est `/feature` → **`/review`** (autant de fois que nécessaire) → `/ship` → `/audit-pr` → fusion. `/review` sert pendant le développement : un regard rapide sur le travail en cours, pour corriger tôt ce qui coûterait une revue `auditor` plus tard. Ce n'est pas un passage obligé, et il ne remplace pas `/audit-pr`.

**`reviewer` relit** : il est sur Haiku, rapide et peu coûteux, donc on peut le relancer souvent. En contrepartie, il signale parfois des problèmes qui n'en sont pas. **La session principale trie** : elle vérifie chaque constat dans le code avant de le présenter, parce qu'un faux positif fait perdre plus de temps qu'il n'en fait gagner.

`/review` ne publie rien, ne commite rien et ne modifie aucun fichier. Les corrections viennent ensuite, si l'utilisateur les demande.

## 1. Délimiter ce qui est relu

- **Base** : `develop` s'il existe sur le dépôt distant (`git ls-remote --heads origin develop`), sinon `main`. Puis `git fetch origin <base>`.
- **Par défaut, tout ce que la branche change** :
  - les commits pas encore fusionnés : `git diff origin/<base>...HEAD` ;
  - les modifications non commitées, indexées ou non : `git diff HEAD` ;
  - les nouveaux fichiers non suivis : `git ls-files --others --exclude-standard`. `git diff` ne les montre pas, et c'est souvent là qu'est le code neuf.
- **Restreint**, si l'utilisateur le demande : à un chemin (le pathspec `<chemin>` au lieu de `.`), ou à ce qui est indexé (`git diff --cached` seul).
- Sur `main` ou `develop` sans rien de modifié, il n'y a rien à relire : le dire.
- **Les fichiers relus**, choisis à partir des seuls noms : `git diff --name-only` sur les mêmes périmètres, et la liste des non suivis. Mettre de côté :
  - chaque fichier de secrets : tout chemin qui correspond à un motif de `secretPaths` sans correspondre à `secretPathsAllow`, dans `.harness/harness.json`. Ce sont les listes de `secret-guard`. Ne pas en dresser une autre de mémoire : elles couvrent aussi les fichiers déchiffrés par sops (`*.dec.yaml`, `*.decrypted.*`), les `.pfx`, les clés SSH…
  - chaque lockfile (`pnpm-lock.yaml`, `packages.lock.json`, `package-lock.json`, `*.lock`) ;
  - chaque fichier généré (`src/api/generated/` d'Orval, `*.g.cs`, `*.Designer.cs`). Les hooks `*.queries.ts` des features sont écrits à la main : ils se relisent.

  Les autres forment la liste des fichiers relus, ou des dossiers entiers quand aucun de leurs fichiers n'est mis de côté.
- **Le pathspec**, dans toutes les commandes `git diff`, `--shortstat` compris : cette liste, et rien d'autre, chaque chemin entre apostrophes (`-- 'src/a.ts' 'frontend/src/routes/posts.$postId.tsx'`) : sans apostrophes, bash comme PowerShell développent le `$` d'une route TanStack, et le fichier sort de la relecture sans que rien ne le signale. Si rien n'est mis de côté, `-- '<. ou chemin>'` suffit. Un `git diff` sans pathspec affiche en clair un secret suivi par Git, et noie Haiku sous un lockfile. On ne peut pas non plus exclure un secret par son nom (`":(exclude)<fichier>"`) : `secret-guard` refuse toute commande qui nomme un fichier de secrets, à juste titre. Un fichier de secrets dans le diff est un constat en soi, à signaler par son nom, sans jamais l'ouvrir ni le citer dans une commande.
- **L'issue** : le numéro du nom de branche (`feature/<n>-…`, `fix/<n>-…`). Si elle existe, lire ses critères d'acceptation (`gh issue view <n> --json title,body`) : un critère oublié est un constat utile.
- **La taille** : `git diff --shortstat` sur les deux premières commandes, avec ce pathspec, plus les lignes des fichiers non suivis. En mode « indexé seulement », `git diff --cached --shortstat` suffit. Au-delà d'environ 800 lignes, découper par zone (un dossier ou une couche : API, front, tests…) et lancer 2 ou 3 `reviewer` en parallèle, chacun sur sa zone. Un seul appel sur un très gros diff survole tout.

## 2. Confier la relecture à `reviewer`

Appeler le subagent `reviewer`, **sans paramètre `model`** (le hook `model-guard` le refuse). Il a ses consignes générales. Le brief lui donne le périmètre exact et le contexte qu'il n'a pas :

```
Relis le travail en cours de la branche <branche>, base <base>.
Périmètre, avec ces commandes exactement, sans en élargir le pathspec :
<- commits : git diff origin/<base>...HEAD -- <fichiers ou dossiers relus>
 - non commité : git diff HEAD -- <fichiers ou dossiers relus>
 - nouveaux fichiers, à lire en entier : <liste, ou « aucun »>
| indexé seulement : git diff --cached -- <fichiers ou dossiers relus>>
Mis de côté, à ne pas ouvrir : <fichiers générés, lockfiles, et « <n> fichier(s) de secrets » sans leur nom, ou « rien »>.
<Issue #<n> : <titre>. Critères d'acceptation : <liste>. Signale ceux que le diff ne remplit pas.>
Conventions : AGENTS.md et les fichiers qu'il importe (.harness/agents/, .harness/modules/<module>/).
Pour chaque constat : chemin:ligne, le problème en une phrase, et pourquoi c'en est un (le cas qui casse).
Classe par gravité. Dix constats au plus : garde les plus importants.
Si rien d'important, dis-le en une ligne.
```

## 3. Trier les constats

Pour chaque constat, ouvrir le code à la ligne citée. Lire le code suffit le plus souvent. Un essai rapide se justifie quand le constat en dépend (un cas limite, un comportement du langage) : le faire hors du dépôt, dans un seul dossier d'essai par session, `Join-Path ([IO.Path]::GetTempPath()) 'review-try'`, réutilisé d'un essai à l'autre. Ne pas le supprimer, et le citer dans le compte rendu. Une suppression récursive passe par `destructive-guard` : la contourner par une autre API reviendrait à neutraliser ce garde-fou. Puis :
- **le confirmer** s'il tient : le bug se produit vraiment, la convention existe vraiment, le test manque vraiment ;
- **l'écarter** sinon, par exemple quand le cas est déjà géré plus loin, quand la convention citée n'existe pas, ou quand le test existe dans un autre fichier. Les écarts se disent en une ligne, pour que l'utilisateur sache que la relecture les a vus.

Classer ce qui reste :
- **À corriger** : un bug, une erreur non gérée, une faille, un secret, un critère de l'issue non rempli, un test manquant pour du code qui en demande un ;
- **À voir** : une convention, un nom trompeur, de la duplication, du code mort, une simplification possible, et un bug qui ne se produit que dans une configuration improbable pour ce projet (une culture exotique, un autre système que celui de la cible). « À corriger » doit rester la liste de ce qui casse vraiment.

Si la session voit elle-même un problème sérieux que `reviewer` a manqué, en lisant le code pour trier, l'ajouter et dire qu'il vient d'elle.

## 4. Rendre compte

Dans la conversation, en quelques lignes :

```
**/review** : <branche>, <n> fichiers, <+a/−b> lignes (<périmètre si restreint>)

À corriger
- `chemin:ligne` : le problème, et le cas qui casse.

À voir
- `chemin:ligne` : …

Écartés : <n> constats de reviewer (<raison courte pour chacun>), ou rien.
```

Sans rien à corriger ni à voir, le dire en une ligne.

Puis proposer la suite : corriger les points « À corriger », par `dev` pour le code et les tests ; ou, si le travail est prêt, **`/ship`**. Ne rien corriger sans l'accord de l'utilisateur : il a peut-être une raison qu'on ignore.

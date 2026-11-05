---
name: retro
description: Rétrospective du travail récent — relève dans les transcripts du projet et les revues auditor ce qui a gêné (refus de hooks, commandes qui échouent en boucle, corrections de l'utilisateur, constats qui reviennent d'une PR à l'autre), le trie, puis en fait une règle d'AGENTS.md (par une issue du projet), une issue harness-update ou une issue pour /evolve, après validation, git-ops créant les issues. À utiliser dès que l'utilisateur veut tirer les leçons, faire le point ou le bilan de ce qui a coincé (« /retro », « fais la rétro », « qu'est-ce qui a coincé cette semaine ? », « tire les leçons de la dernière feature », « pourquoi on bute toujours sur les mêmes refus ? », « qu'est-ce qu'il faudrait changer dans le harness ? »). Pas pour relire du code (/review), auditer une PR (/audit-pr), ni noter une idée de fonctionnalité (/idea).
argument-hint: "[nombre de jours] [essai]"
---

# /retro

Ce qui a gêné une fois gênera encore, dans ce projet ou dans tous les autres. `/retro` le transforme en quelque chose qui reste : une règle d'`AGENTS.md`, que les agents liront à chaque session, ou une issue sur le harness, qui corrigera tous les projets à la fois.

Une rétro ne vaut que par ses preuves. Un constat sans trace (« j'ai l'impression que… ») ne devient ni une règle ni une issue : une règle inutile alourdit `AGENTS.md` pour toujours. Chaque constat cite donc ce qui l'établit : un refus de hook compté, une commande qui échoue, une correction de l'utilisateur, un constat d'`auditor` qui revient.

Chacun son rôle : la session principale relève et trie, l'**utilisateur** valide, **`git-ops`** crée les issues. `/retro` ne modifie aucun fichier du dépôt : une règle d'`AGENTS.md` passe par une issue, puis par `/feature`, comme tout changement.

**Mode essai** : si l'utilisateur demande un essai ou « sans publier », rien ne part sur GitHub. Les constats, leur tri et les issues qui auraient été créées vont dans le fichier qu'il indique, ou par défaut dans `Join-Path ([IO.Path]::GetTempPath()) "retro-<date>.md"`, hors du dépôt.

## 1. Relever la matière

```
pwsh -NoProfile -File .claude/skills/retro/scripts/scan-transcripts.ps1 -Days <n>
```

Le script lit, sans rien modifier, les transcripts Claude Code (sous-agents compris) et les PR fusionnées sur la période. Il ne garde que les messages du projet, d'après leur dossier de travail : les sessions ouvertes depuis un dossier parent comptent, celles d'un autre dépôt rangé sous la racine non. Une session reprise n'est comptée qu'une fois. Il rend :
- les **refus de hooks**, groupés par règle et par raison, avec leur nombre de sessions ;
- les **échecs répétés** : la même commande en échec au moins deux fois ;
- les messages de l'utilisateur qui ressemblent à une **correction** (« non, … », « je t'ai dit… ») ;
- les **constats d'`auditor`** (B1, I1, M1…) des PR fusionnées sur la période.

`-Days` vaut 14 par défaut, ou le nombre de jours donné en argument. `-NoPrs` se passe de `gh`. La conversation en cours compte aussi : ce que l'utilisateur vient de dire sur ce qui l'a gêné est une preuve.

**« Aucun message de ce projet sur la période »** veut dire que la rétro n'a rien lu, pas que tout va bien. Le dire tel quel, montrer les dossiers lus, et proposer le bon levier :
- une période plus longue (`-Days`) ;
- le projet a été déplacé ou renommé, ou ses sessions tournaient depuis un autre clone : `-Root <ancien chemin>`, car seuls les messages dont le dossier de travail est sous la racine comptent ;
- des sessions lancées sous WSL : `-Root` (le chemin vu depuis WSL) **et** `-Path` (le dossier de transcripts du `~/.claude` de WSL) ensemble ;
- les transcripts sont rangés ailleurs, par exemple des sessions ouvertes dans un sous-dossier du projet (`~/.claude/projects/<racine>-<sous-dossier>`, non lu par défaut) : `-Path <dossier>`.

Ne jamais présenter ce cas comme une rétro sans accroc.

Le repérage des corrections se fait sur les premiers mots : relire chacune dans son contexte avant d'en tirer quoi que ce soit (`Select-String` sur le transcript, autour de la phrase citée).

## 2. Trier

Pour chaque candidat, se demander d'abord **si c'est un problème**, puis **où il se corrige**.

- **Bruit, écarté en le disant** :
  - un refus de hook qui a joué son rôle : l'agent tentait un geste interdit, puis a fait autrement ;
  - une erreur isolée, vite corrigée ;
  - un échec dû à l'environnement du moment (réseau, limite d'usage) ;
  - un constat d'`auditor` corrigé dans sa PR, qui ne revient nulle part ailleurs.
- **Propre au projet → règle d'`AGENTS.md`**. C'est une convention que l'agent ignorait et que l'utilisateur a dû rappeler (un dossier, un nom, une commande du projet), ou un piège propre à ce code. Vérifier d'abord qu'`AGENTS.md` ne le dit pas déjà : si la règle existe mais n'a pas suffi, la reformuler plutôt qu'en ajouter une autre. Rédiger la règle telle qu'elle sera écrite : une phrase impérative, avec sa raison.
- **Commun à tous les projets → issue `harness-update`** sur le dépôt `harness`. C'est le cas d'un hook qui refuse une commande légitime (un faux positif, qui revient d'une session à l'autre), d'un skill qui oublie une étape, ou d'un même constat d'`auditor` dans plusieurs PR, qui trahit un manque du skill ou des conventions.
- **Manque de l'écosystème → issue pour `/evolve`**, sur le dépôt `services`. C'est le cas d'une techno ou d'un service qu'aucun module ne couvre, et que le travail a dû contourner. Ne pas proposer de contournement local.

**Chercher les doublons avant de proposer quoi que ce soit.** Deux rétros rapprochées lisent les mêmes jours : une règle validée la première fois attend encore dans une issue ouverte, pas encore livrée par `/feature`, donc absente d'`AGENTS.md`. Chercher dans les issues ouvertes du dépôt visé, avec des mots-clés du constat :
- règle d'`AGENTS.md` : `gh issue list --state open --search "AGENTS.md in:title <mots-clés>"` ;
- `harness-update` : `gh issue list -R <propriétaire>/harness --state open --search "<mots-clés>"` ;
- `/evolve` : `gh issue list -R <propriétaire>/services --state open --search "<mots-clés>"`.

Une issue qui existe déjà n'est pas recréée. Si la preuve est nouvelle, elle va en commentaire. Sinon, le constat est écarté en le disant (« déjà ouverte : #n »). Lire les commentaires de l'issue avant d'en ajouter un : une preuve déjà citée ne se répète pas.

Le propriétaire des dépôts se lit par `gh repo view --json owner --jq .owner.login`.

## 3. Faire valider

Un seul message, numéroté, avec pour chaque constat retenu :

```
<n>. <Constat, en une phrase>
   Preuve : <ce qui l'établit : « git-guard a refusé `git merge-base …` 7 fois, dans 3 sessions », extrait cité, PR #…>
   Proposition : <règle d'AGENTS.md | issue harness-update | issue pour /evolve | commentaire sur l'issue #…>
   Texte : <la règle telle qu'elle sera écrite, ou le titre et le résumé de l'issue>
```

Puis les constats écartés, une ligne chacun, avec la raison. L'utilisateur garde, reformule ou écarte chaque constat : **attendre sa réponse** avant toute écriture. Sans aucun constat retenu alors que des transcripts ont été lus, le dire et s'arrêter : une rétro vide est alors un bon signe, pas un échec.

## 4. Faire créer les issues par `git-ops`

Rédiger le corps de chaque issue dans un fichier hors du dépôt (`Join-Path ([IO.Path]::GetTempPath()) "retro-<k>.md"`) :
- **règle d'`AGENTS.md`** : issue du projet, label `feature`, titre « AGENTS.md : <règle en quelques mots> ». Le corps donne la preuve, le texte exact de la règle, et le critère « `AGENTS.md` contient la règle : <texte> » ;
- **`harness-update`** : issue sur `<propriétaire>/harness`, label `harness-update`. Le corps donne le constat, la preuve (sans secret ni chemin personnel), le projet où il est apparu et une piste ;
- **`/evolve`** : issue sur `<propriétaire>/services`, label `feature`, titre « Manque de l'écosystème : <sujet> ».

Puis appeler `git-ops`, **sans paramètre `model`** :

```
/retro du <date>, validée par l'utilisateur. Crée ces issues, dans l'ordre :
1. gh issue create [-R <propriétaire>/<dépôt>] --title "<titre>" --body-file '<fichier>' --label <label>
2. …
<Pour une issue existante : gh issue comment <n> [-R …] --body-file '<fichier>'>
Si une création échoue ou si un hook la refuse, continue avec la suivante, puis rapporte le message exact de chaque échec.
Rends le numéro et l'URL de chaque issue créée.
```

**Le titre entre guillemets doubles**, comme dans `/ship` : une apostrophe fermerait une chaîne entre apostrophes. Un titre qui contient `"`, `$` ou un backtick se reformule sans eux.

Un label absent fait échouer la création : `scripts/github-setup.ps1`, à la racine de `services`, pose les labels communs. En **mode essai**, pas d'appel à `git-ops` : écrire les corps et ces commandes dans le fichier d'essai.

## 5. Rendre compte

```
**/retro** — <n> jours, <s> sessions, <p> PR lues

Retenus : <k> (<a> règle(s) d'AGENTS.md, <h> harness-update, <e> pour /evolve)
Issues : <#…, URL | aucune | essai : <fichier>>
Écartés : <k> (<raisons en quelques mots>)
```

Pour chaque règle d'`AGENTS.md`, proposer **`/feature <n>`** sans le lancer : c'est lui qui crée la branche et livre la règle par une PR.

# Guide de revue `/audit-pr` (pour `auditor`)

Ta revue conditionne la fusion : `merge-pr.ps1` ne fusionne que le commit sur lequel tu as posé `verdict=approve`. Un constat manqué part en production ; un constat gonflé bloque pour rien. Vise juste, et prouve ce que tu avances.

## Méthode

1. **Comprendre l'intention** : `gh pr view <n>` (description), l'issue liée (`gh issue view <i>`) et ses critères d'acceptation, `AGENTS.md`, `ARCHITECTURE.md`, et les conventions des modules (`.harness/agents/`, `.harness/modules/*/conventions.md`).
2. **Lire le diff entier** : `gh pr diff <n>`. Pour une revue après corrections, lire d'abord `git diff <sha revu>..<sha de tête>` : chaque correction peut casser autre chose, c'est là qu'on trouve le plus de régressions. Ensuite seulement, réévaluer la PR entière.
3. **Lire autour du diff** : appelants, tests existants, contrats touchés (codegraph d'abord si `.codegraph/` existe). Un changement juste localement peut casser un appelant.
4. **Exécuter, pas seulement lire**, si la copie locale est sur le commit revu : les tests du projet, le lint, le doctor (`pwsh -NoProfile -File .harness/tools/doctor.ps1`), et tout essai ciblé qui confirme ou infirme un doute (appeler la fonction, rejouer le cas limite, soumettre une commande au vrai hook). Note ce que tu as lancé et le résultat : la section *Méthode* du commentaire le rapporte.
5. **Vérifier chaque axe** :
   - **Correction** : logique, cas limites, erreurs, concurrence, valeurs nulles.
   - **Sécurité** : entrées non validées, autorisations, secrets, injection, dépendances ajoutées (provenance, version).
   - **Migrations** : compatibles avec la version précédente (on ajoute avant de retirer ; jamais de suppression ou de renommage de colonne dans la même release que le code qui cesse de l'utiliser).
   - **Conventions et architecture** : `AGENTS.md`, modules, `ARCHITECTURE.md`.
   - **Tests** : présents, pertinents (ils échoueraient sans le changement), verts.
   - **Issue liée** : chaque critère d'acceptation est rempli, ou le constat dit lequel ne l'est pas. Une PR sans issue liée est un constat **important** (une PR = une issue).
   - **Taille** : au-delà de 1 500 lignes modifiées, hors fichiers générés (manifeste, lockfiles, contenu apporté par `copier update`), un constat **mineur** propose un découpage.

Tu ne modifies pas le code et tu ne fusionnes pas. Si la copie locale n'est pas sur le commit revu, n'exécute rien qui dépende du code : dis-le dans *Méthode*.

## Gravité

- **Bloquant** : la PR casse quelque chose ou ouvre une faille si on la fusionne (bug avéré, perte de données, migration incompatible, secret exposé, test rouge).
- **Important** : à corriger avant fusion, sans être une casse immédiate (cas limite non géré et plausible, critère d'acceptation non rempli, convention structurante violée, test manquant sur la logique ajoutée).
- **Mineur** : améliorable, ne bloque pas (lisibilité, nommage, contournement improbable). Peut aller dans une issue de suivi.

`approve` seulement s'il ne reste **aucun bloquant ni important**. En cas de doute sur une gravité, explique-le plutôt que de gonfler ou d'atténuer.

## Format du commentaire

En français, en Markdown :

```
# Audit PR #<n>, <1er | 2e | 3e…> passage : <sha complet>

## Résumé
<2 à 6 lignes : ce que fait la PR, l'état global, ce qui décide du verdict.
Pour une revue après corrections : ce qui est corrigé, ce qui ne l'est pas, les régressions.>

## Méthode
<Ce qui a été lu et exécuté, avec les résultats (comptes de tests, commandes essayées).
Si rien n'a pu être exécuté : pourquoi.>

## Bloquant
<Aucun. | Une entrée par constat :>
**B1. <titre court>** — `chemin/fichier.ext:42`
<Le problème, le scénario concret qui le déclenche, la correction attendue.>

## Important
<idem, I1, I2…>

## Mineur
<idem, M1, M2…>

## Verdict
**approve** | **changes** : <une ligne de justification>.

<!-- auditor: sha=<sha complet> verdict=approve|changes -->
```

Numérote les constats (B1, I1, M1…) : une revue après corrections s'y réfère (« I2 corrigé, M1 reste »).

## Publication

- Le SHA du marqueur est le **SHA complet** du dernier commit de la PR, relu juste avant de publier : `gh pr view <n> --json headRefOid --jq .headRefOid`. S'il a changé pendant la revue, dis-le : la revue ne porte pas sur le dernier commit, et `merge-pr.ps1` la refusera.
- Le marqueur est la **toute dernière ligne** du commentaire, et il n'apparaît **nulle part ailleurs** : pour parler d'une revue précédente, cite son SHA court et son verdict en clair (« revue `changes` sur `48d6965` »), jamais son marqueur. Un marqueur cité plus haut pourrait être lu comme le verdict.
- Écris le corps dans un fichier temporaire **hors du dépôt** (par exemple `Join-Path ([IO.Path]::GetTempPath()) "audit-pr-<n>.md"`, en UTF-8), puis : `gh pr comment <n> --body-file <fichier>`.
- **Mode essai** : écris le commentaire au chemin indiqué par le brief et ne lance pas `gh pr comment`.
- Rends à la session principale : le verdict, le nombre de constats par gravité, et l'URL du commentaire (ou le chemin du fichier).

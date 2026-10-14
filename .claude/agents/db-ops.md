---
name: db-ops
description: Applique les migrations SQL (DbUp) sur la base locale puis régénère le code EF (dotnet ef dbcontext scaffold). À utiliser après tout ajout ou modification d'un fichier dans backend/db/migrations/.
model: haiku
tools: Bash, PowerShell, Read, Glob, Grep
---

Tu tiens la base locale et le code EF généré à jour avec les migrations SQL.

1. **Vérifie les migrations** : `backend/db/migrations/NNNN.<issue>.<slug>.sql`, numéros sur 4 chiffres, sans doublon. Signale tout écart sans le corriger toi-même.
2. **Applique-les sur la base locale** : `scripts/db.ps1 migrate` (lance l'exécutable DbUp contre le Postgres local). Jamais sur une autre base.
3. **Régénère le code EF** : `scripts/db.ps1 scaffold`, qui lance `dotnet ef dbcontext scaffold` (outil local du dépôt) dans `MyApp.Dal/Generated/`, en écrasant l'existant.
4. **Compile** (`dotnet build backend`) et rends : les migrations appliquées, les fichiers générés modifiés, les erreurs de compilation éventuelles (une colonne renommée casse le code qui l'utilisait : c'est attendu, signale-le à la session principale).

Tu ne modifies **jamais** un fichier SQL de migration ni un fichier de `Generated/` à la main. Tu ne te connectes jamais à une base de production. La chaîne de connexion locale vient de `scripts/db.ps1` : ne l'affiche pas.

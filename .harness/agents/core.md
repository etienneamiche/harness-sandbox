# Conventions communes (harness)

Ce fichier est géré par le harness : il est remplacé à chaque mise à jour. Les spécificités du projet vont dans `AGENTS.md`.

## Délégation et modèles

La session principale (Opus) orchestre. Elle confie le travail aux subagents, chacun avec son modèle imposé :

| Besoin | Subagent | Modèle |
|---|---|---|
| Explorer le code, trouver où se trouve quelque chose | `explorer` | Haiku |
| Écrire ou modifier du code et ses tests | `dev` | Opus |
| Nettoyer le lint et le format | `linter` | Haiku |
| Relire un diff pendant le développement | `reviewer` | Haiku |
| Écrire un message de commit, commiter, pousser, ouvrir une PR, gérer issues et labels | `git-ops` | Haiku |
| Résumer l'architecture existante | `cartographer` | Haiku |
| Appliquer les migrations SQL en local et régénérer le code EF | `db-ops` | Haiku |
| Concevoir : spécification, architecture, roadmap | `architect` | Opus |
| Revue complète avant fusion, audit | `auditor` | Opus |

- **Ne jamais passer de paramètre `model`** à un subagent : il écraserait le modèle imposé. Le hook `model-guard` le refuse.
- Les agents génériques (`general-purpose`, `Explore`…) ne sont pas autorisés : utiliser ceux du tableau.

## Lire le code

- **codegraph d'abord.** Si `.codegraph/` existe, `codegraph_explore` répond en un appel là où plusieurs recherches seraient nécessaires. `Grep` et `Read` ensuite, pour compléter.
- Pour une exploration large, déléguer à `explorer` et ne garder que sa conclusion.

## Git

- **Branches simples uniquement** : pas de worktree, pas de rebase interactif, pas de push forcé.
- **Toute opération Git qui écrit** (commit, push, merge, tag) et **toute écriture sur GitHub** (PR, issues, releases) passent par `git-ops`. Le hook `git-guard` refuse ces commandes ailleurs.
- **Messages de commit** : en anglais, Conventional Commits, numéro d'issue en fin de titre. Exemple : `feat(api): add PDF export for invoices (#42)`.
- **Ajouter les fichiers un par un**, après vérification : `git add -A`, `git add .` et `git commit -a` sont refusés.
- **Jamais `--no-verify`** : le hook `pre-commit` (gitleaks) protège contre les fuites de secrets.

## Revue

- Pendant le développement : `reviewer` relit le diff, autant de fois que nécessaire.
- **Avant toute fusion : `/audit-pr`**, une revue complète de la PR par `auditor`. La fusion passe par `.harness/tools/merge-pr.ps1` (via `git-ops`), qui refuse sans verdict `approve` sur le dernier commit de la PR, et ne fusionne que ce commit-là.

## Secrets

- **Un agent ne lit, n'écrit et n'affiche jamais un secret en clair** : `.env`, clés, `secrets.json`, `sops -d`, variables d'environnement sensibles. Le hook `secret-guard` refuse ces accès.
- Les secrets de dev sont chiffrés par SOPS et injectés dans le processus qui en a besoin (`scripts/launch.ps1`).
- Si une tâche semble exiger un secret, s'arrêter et demander à l'utilisateur.

## Documentation

- La doc du projet vit dans `docs/`, plus `README.md`, `AGENTS.md`, `ARCHITECTURE.md`, `ROADMAP.md` et `CHANGELOG.md` à la racine.
- Ne pas créer de fichier Markdown de travail ailleurs (`notes.md`, `PLAN.md`…).

## Le harness lui-même

- Les fichiers du harness (`.harness/`, `.claude/settings.json`, `.claude/agents/`, `.claude/skills/`, `CLAUDE.md`), les configs de lint et de format, la CI, `.gitignore` et `.sops.yaml` sont **protégés** : un agent ne modifie pas les règles qui encadrent son travail.
- **Un refus de hook n'est pas un obstacle à contourner.** Lire la raison, adapter l'approche, ou demander à l'utilisateur. Ne jamais tenter la même action par un autre chemin.
- Un fichier venu d'un template, modifié dans le projet, peut profiter à tous les projets : le proposer à l'utilisateur via `/upstream`.

@conventions.md
@../modules/react/conventions.md
@../modules/dotnet/conventions.md
@../modules/game/conventions.md

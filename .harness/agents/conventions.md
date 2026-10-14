# Conventions communes de code

Valables pour tous les projets, quelle que soit la techno. Les conventions propres à chaque stack sont dans les modules (`.harness/modules/<stack>/conventions.md`). Ce fichier est géré par le harness.

## Langue

| Quoi | Langue |
|---|---|
| Code : identifiants, commentaires, messages de log | Anglais |
| Git : messages de commit, noms de branches, CHANGELOG (généré depuis les commits) | Anglais |
| Docs : README, `AGENTS.md`, `ARCHITECTURE.md`, ADR, `docs/` | Français |
| Suivi : issues, PR, commentaires de revue | Français |
| Interfaces utilisateur | Français, via l'i18n (voir ci-dessous) |

## Interfaces : i18n dès le départ

- Aucun texte affiché en dur : tout passe par les fichiers de traduction (react-i18next côté front, ressources côté back).
- Une seule langue au départ, le français. Ajouter une langue ne doit demander que des fichiers de traduction.

## Structure d'un dépôt

```
frontend/      le front (s'il existe)
backend/       le back (s'il existe)
deploy/        Chart.yaml + values.yaml
docs/          la doc du projet
docs/adr/      les décisions d'architecture
scripts/       launch.ps1, test.ps1, lint.ps1, build.ps1, et db.ps1 si l'app a une base
```

- Les tests suivent l'usage de leur stack : voir les conventions du module.
- Dossiers et fichiers hors code : `kebab-case`. Dans le code : la convention du langage.

## Branches, PR et commits

- **Branches** : `feature/<n>-<slug>`, `fix/<n>-<slug>`, `release/x.y.z`, `hotfix/x.y.z`, où `<n>` est le numéro d'issue.
- **Une PR = une issue**, cible : moins de 400 lignes modifiées (hors fichiers générés et lockfiles). Au-delà, l'issue est probablement à découper : le signaler.
- **Fusion en squash** : un commit par feature dans la branche cible. Son message est **en anglais, en Conventional Commits**, et toujours **donné explicitement à la fusion** : sans ça, GitHub reprendrait le titre de la PR, qui est en français.
- **Toute fusion passe par `.harness/tools/merge-pr.ps1`** (réservé à `git-ops`) : `-Pr 42 -Subject "feat(api): add PDF export for invoices (#42)"`, ou `-Strategy merge` pour une branche `release/*` ou `hotfix/*`. Le script vérifie la revue `auditor` et ne fusionne que le commit revu. `gh pr merge` direct est refusé par `git-guard`.
- **Commits** : Conventional Commits, en anglais, numéro d'issue en fin de titre.
  - Types : `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, `revert`.
  - Scope : la brique concernée (`web`, `api`, `db`, `deploy`, `harness`…).
  - Rupture de compatibilité : `!` après le scope.
  - Exemples : `feat(api): add PDF export for invoices (#42)`, `fix(web)!: drop legacy login route (#57)`.

## Documentation

- **Une décision structurante = un ADR** dans `docs/adr/NNNN-titre-court.md` : bibliothèque majeure, motif d'architecture, besoin d'infra, renoncement important.
  - Format court : **Contexte**, **Options envisagées**, **Décision**, **Conséquences**.
  - Un ADR ne se modifie pas : une décision qui change donne un nouvel ADR, qui remplace l'ancien.
- **`ARCHITECTURE.md` reflète le code réel.** À chaque release, `cartographer` compare les deux et signale les écarts, à corriger avant de taguer.

## Tests

- **Tout code métier nouveau arrive avec ses tests**, dans la même PR. `auditor` le vérifie avant fusion.
- **Unitaires** pour la logique métier.
- **Intégration**, pour une app qui a une base Postgres : contre le **Postgres local** (Docker), recréé et migré à chaque lancement de `scripts/test.ps1`, jamais une base simulée. Les modules Python (SQLite) et les fronts sans backend n'en ont pas.
- **Composants** : leur comportement, vu par l'utilisateur (rôles, textes, interactions), jamais leur structure interne ni des instantanés.
- **E2E (Playwright)** limités aux **parcours critiques**, 1 à 5 par app, avec un contrôle d'accessibilité **axe**.
- **Couverture** : mesurée et affichée, **sans seuil bloquant**. Un test qui n'existe que pour le chiffre est pire que pas de test.

## Logs et observabilité

- Logs **structurés (JSON) sur la sortie standard**, niveaux standards (`Debug`, `Information`, `Warning`, `Error`, `Critical`).
- Un **identifiant de corrélation** suit chaque requête du front au back (en-tête W3C `traceparent`).
- **Jamais de données personnelles ni de secret dans un log**, même en `Debug`.
- **OpenTelemetry dès la création** (traces et métriques), **export désactivé par défaut** : il s'active par variable d'environnement (`OTEL_EXPORTER_OTLP_ENDPOINT`) quand la supervision existe.
- Sondes : `/healthz` (le processus vit) et `/ready` (prêt à servir, dépendances comprises).

## Services tiers

- **Le front n'appelle jamais une API tierce** (GitHub, météo…) : il passe par le backend de l'app. Les clés restent côté serveur, les réponses sont validées, mises en cache et normalisées en un seul endroit.
- Un front sans backend n'appelle donc aucune API tierce. Si le besoin apparaît, l'app reçoit un backend.

## Erreurs

- **API** : les erreurs suivent **Problem Details** (RFC 9457), avec un `type`, un `title`, un `status` et, pour la validation, le détail par champ.
- **Validation à la frontière** : chaque entrée externe est validée à son arrivée. Le code interne fait confiance aux données déjà validées.
- **Pas d'exception pour un cas prévu** (introuvable, refusé, invalide) : un résultat explicite.
- **Front** : une *error boundary* par zone d'écran, des messages compréhensibles par l'utilisateur, jamais une trace technique.
- Les erreurs inattendues remontent au service `feedback` quand il existe.

## Accessibilité

- Cible **WCAG 2.2 niveau AA** pour les applications.
- S'appuyer sur les composants shadcn / Radix, accessibles d'origine, plutôt que de les réécrire.
- Tout est utilisable au clavier, chaque contrôle a un nom accessible, les contrastes viennent des thèmes.
- Contrôles automatiques : les règles d'accessibilité du linter (Biome, groupe `a11y`) à chaque fin de tour d'agent, et **axe** dans les tests Playwright des parcours critiques.
- Jeux : cible assouplie, mais les menus restent navigables au clavier.

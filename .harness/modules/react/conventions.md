# Conventions React

Module `react` du harness. S'ajoute aux conventions communes (`.harness/agents/conventions.md`).

## Socle

- **Node 24 LTS**, version figée dans `frontend/.node-version`. Gestionnaire de paquets : **pnpm**.
- **Vite**, **React 19** avec le **React Compiler** activé : ne pas écrire de `useMemo`, `useCallback` ni `React.memo` par réflexe, le compilateur s'en charge. Seulement si une mesure montre un problème.
- **TypeScript strict**, avec `noUncheckedIndexedAccess`. Pas de `any` : `unknown`, puis validation.
- Alias d'import : `@/` pour `frontend/src/`.

## Options de l'app

Le front est généré selon les options de `template-react`. Ce qui existe dans le code en dépend :

| Option | Valeurs | Conséquence |
|---|---|---|
| `api` | `openapi` · `none` | `openapi` : client généré par Orval + TanStack Query. `none` : ni l'un ni l'autre ; les données locales vont dans un store Zustand persisté (`localStorage`) |
| `auth` | `none` · `forward-auth` · `oidc` | `forward-auth` : Traefik exige une session Authentik avant de servir l'app, **aucun code d'auth dans le front**. `oidc` : `oidc-client-ts` + `react-oidc-context` |
| `google` | oui / non | Avec `oidc` : bouton « Se connecter avec Google », qui passe par Authentik. **Aucune clé Google dans l'app** |
| `realtime` | `none` · `signalr` | Client SignalR typé dans `src/realtime/`. Exige un backend .NET |

**Le front n'appelle jamais une API tierce** : il passe par le backend de l'app.

## Organisation

```
frontend/src/
├── app/                fournisseurs (Query, i18n, auth), routeur, error boundary racine
├── routes/             routes TanStack Router (une route = un fichier)
├── features/<feature>/
│   ├── components/     InvoiceList.tsx, InvoiceForm.tsx…
│   ├── invoices.queries.ts    hooks de données de la feature
│   ├── invoices.schema.ts     schémas zod (formulaires, validations)
│   ├── invoices.store.ts      store Zustand, si la feature en a un
│   └── *.test.ts(x)           tests, à côté du code testé
├── api/generated/      client généré par Orval : ne jamais modifier à la main
├── realtime/           connexion SignalR, contrats générés, store (option realtime)
├── shared/             ui/ (composants propres à l'app), lib/, hooks/
├── i18n/fr/            un fichier JSON par feature
└── config.ts           lecture et validation de /config.js
```

- **Une feature n'importe jamais l'intérieur d'une autre feature.** Ce qui est partagé monte dans `shared/`.
- Les routes restent minces : elles assemblent des composants de features, sans logique métier.

## Nommage

- **Composants : PascalCase**, un composant exporté par fichier, du même nom : `InvoiceList.tsx` → `InvoiceList`.
- **Hooks et utilitaires : camelCase** : `useInvoiceTotals.ts`, `formatAmount.ts`.
- **Fichiers à rôle : `<sujet>.<rôle>.ts`** en minuscules : `invoices.queries.ts`, `invoices.schema.ts`, `invoices.store.ts`, `invoices.types.ts`.
- **Exports nommés uniquement**, jamais d'export par défaut (sauf fichiers de config d'outils qui l'imposent).
- Les composants shadcn (`button.tsx`…) gardent leurs noms d'origine : ils vivent dans `@marblestudio/ui`, pas dans l'app.

## Données serveur (`api: openapi`)

- **Le client est généré** par Orval depuis la spécification OpenAPI du backend, dans `src/api/generated/` : `pnpm api:generate`. On ne le modifie jamais : on régénère, et le compilateur signale ce qui casse.
- **Chaque feature expose ses hooks dans `<feature>.queries.ts`**, en s'appuyant sur le client généré : clés de cache, invalidations après mutation, transformations pour l'affichage. Les composants n'importent pas `api/generated/` directement.
- Pas d'appel `fetch` écrit à la main.

## État

- **Par défaut : l'URL et le cache TanStack Query.** Filtres, onglets, pagination : dans l'URL, via les paramètres typés du routeur.
- **Zustand seulement** pour les données locales sans backend (`api: none`), l'état temps réel (`realtime`), ou après un ADR.
- Pas de contexte React pour de l'état qui change souvent.

## Formulaires

- **react-hook-form + zod**, via le composant `Form` de shadcn. Le schéma vit dans `<feature>.schema.ts`.
- Les erreurs de validation renvoyées par l'API (Problem Details) sont reportées sur les champs concernés.

## Interface

- **shadcn/ui, fourni par `@marblestudio/ui`**, Tailwind v4, icônes **lucide-react**. Un seul thème importé (`tech`, `app` ou `spare`).
- **On ne modifie pas un composant shadcn dans l'app.** S'il faut le changer pour tous, la modification va dans `libs`.
- Classes Tailwind dans le JSX ; pas de CSS à part, sauf exception justifiée.

## i18n

- **react-i18next**, un espace de noms par feature (`src/i18n/fr/invoices.json`), **clés typées** : une clé absente ne compile pas.
- **Aucun texte affiché en dur**, y compris les `aria-label`, les messages d'erreur et les titres de page.

## Configuration

- La configuration vient de **`/config.js`**, lu au démarrage et **validé par zod** dans `src/config.ts`. Une config invalide affiche une erreur claire au lieu d'une app à moitié cassée.
- **Jamais `import.meta.env`** pour une valeur qui change selon l'environnement : la même image doit tourner en local comme en production, seule `/config.js` change.

## Temps réel (`realtime: signalr`)

- La connexion vit dans `src/realtime/` : reconnexion automatique, et un indicateur d'état visible quand la connexion est perdue.
- **Les contrats (méthodes et messages du hub) sont générés depuis le C#** : jamais écrits à la main des deux côtés.
- Les messages reçus alimentent un **store Zustand** ; les composants lisent ce store.

## Utilisateur et impersonation (`auth: oidc`)

- L'utilisateur courant et ses **permissions** viennent du backend (`GET /api/me`), pas d'une lecture du jeton dans le front. L'interface masque ce que l'utilisateur ne peut pas faire ; l'API le refuse de toute façon.
- **« Naviguer en tant que… »** : visible seulement avec la permission `Users.Impersonate`. Le choix d'un utilisateur ajoute l'en-tête `X-Impersonate-User` à chaque appel d'API (dans le client généré, via son intercepteur), et un **bandeau permanent** indique « Vous naviguez en tant que X » avec un bouton pour revenir à soi.

## Erreurs

- Une **error boundary par route** (`errorComponent` de TanStack Router), plus une à la racine.
- Les erreurs de mutation s'affichent en notification (`sonner`), avec un message traduit. Jamais une trace technique à l'écran.

## Tests

- **Vitest** pour la logique : fonctions, schémas zod, hooks.
- **Testing Library + MSW** pour les composants : on teste le comportement vu par l'utilisateur (rôles, textes, clics), avec l'API simulée par MSW. Pas d'instantanés (snapshots), pas de test de la structure interne.
- **Playwright + @axe-core/playwright** pour les parcours critiques (1 à 5 par app), contre l'app lancée par `scripts/launch.ps1`.
- On cible les éléments par leur rôle et leur nom accessible (`getByRole`), pas par des classes CSS ni des `data-testid`, sauf en dernier recours.

## Qualité

- **Biome** pour le lint et le format, avec la configuration du harness (`frontend/biome.json` étend `.harness/modules/react/biome.json`). Plus `tsc --noEmit` pour les types.
- Les deux tournent à chaque fin de tour d'agent (`stop-checks`). Un avertissement se corrige, il ne se désactive pas.

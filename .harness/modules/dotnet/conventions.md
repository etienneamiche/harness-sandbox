# Conventions .NET

Module `dotnet` du harness. S'ajoute aux conventions communes (`.harness/agents/conventions.md`).

## Socle

- **.NET 10 LTS**, version figée dans `backend/global.json`. Solution au format **`.slnx`**.
- `Directory.Build.props` : `Nullable` activé, `TreatWarningsAsErrors`, analyseurs `latest-recommended`, **`EnforceCodeStyleInBuild`** (sans lui, `dotnet build` n'évalue aucune règle de style `IDExxxx`), `GenerateDocumentationFile` avec `NoWarn` `CS1591` (requis par IDE0005, sans imposer de documenter chaque membre public), et la configuration d'analyse du harness (`.harness/modules/dotnet/analyzers.globalconfig`, via `GlobalAnalyzerConfigFiles`). Ce fichier est protégé : un agent ne le modifie pas.
- **Versions des paquets centralisées** dans `Directory.Packages.props`, tenues à jour par Renovate.
- **Bibliothèques interdites** (devenues payantes) : MediatR, AutoMapper, FluentAssertions v8+.

## Architecture : Controller → Service → Dal / Clients

```
backend/
├── MyApp.slnx · global.json · Directory.Build.props · Directory.Packages.props
├── db/migrations/             NNNN.<issue>.<slug>.sql (DbUp)
├── src/
│   ├── MyApp.Api/             Program.cs, Controllers/ (+ un .http par contrôleur), Validators/, Hubs/
│   ├── MyApp.Contracts/       DTO (requêtes, réponses), interfaces des hubs SignalR
│   ├── MyApp.Services/        logique métier : I<Sujet>Service + implémentation
│   ├── MyApp.Dal/             accès aux données : Generated/ (scaffolding), I<Sujet>Dal + implémentation
│   ├── MyApp.Clients/         un dossier par API appelée : <Service>/
│   └── MyApp.Migrations/      exécutable DbUp (embarque db/migrations)
└── tests/
    ├── MyApp.Services.Tests/  tests unitaires
    └── MyApp.Api.Tests/       tests d'intégration + test d'architecture
```

**Les dépendances entre projets sont le garde-fou de l'architecture :**

| Projet | Peut référencer |
|---|---|
| `Api` | `Contracts`, `Services` (et `Dal`, `Clients` **uniquement** pour l'enregistrement DI dans `Program.cs`) |
| `Services` | `Contracts`, `Dal`, `Clients` |
| `Dal`, `Clients` | `Contracts` si besoin, rien d'autre de l'app |
| `Contracts` | rien |

Un **test d'architecture** (NetArchTest, dans `MyApp.Api.Tests`) vérifie qu'aucun contrôleur n'utilise `Dal` ou `Clients` directement.

## Contrôleurs

- `[ApiController]`, routes explicites en minuscules (`[Route("api/invoices")]`).
- **Minces** : la validation est automatique, le contrôleur appelle un service et traduit son résultat en réponse HTTP. Aucune logique métier, aucun accès aux données.
- **Codes de retour** : GET 200/404, POST 201 avec `CreatedAtAction` (en-tête `Location`), PUT/PATCH 200/404, DELETE 204/404, conflit 409. Chaque code possible est déclaré par `[ProducesResponseType]` : il apparaît dans OpenAPI, donc dans le client généré du front.
- **`CancellationToken`** dans chaque action, transmis à tous les appels asynchrones.
- **Un fichier `.http` par contrôleur, à côté de lui** (`Controllers/InvoicesController.http`), avec une requête par action, cas d'erreur compris.

## Services

- Une interface `I<Sujet>Service` et une implémentation `sealed`, enregistrée par l'interface.
- **Un cas prévu n'est pas une exception** (introuvable, interdit, conflit, règle métier) : le service renvoie un résultat explicite (`ServiceResult<T>` de `MarbleStudio.Hosting`), que le contrôleur traduit en Problem Details.
- Les services reçoivent et renvoient des **objets immuables**.

## Immuabilité

- **On ne modifie jamais un objet reçu en paramètre.** On crée une copie modifiée et on la renvoie : `var updated = invoice with { Status = InvoiceStatus.Paid };`.
- DTO, résultats, modèles métier : **`sealed record`**, propriétés `required` + `init`, ou record positionnel.
- Collections exposées : `IReadOnlyList<T>`, `IReadOnlyDictionary<TKey, TValue>`.
- **Seule exception : les entités EF à l'intérieur de `Dal`**, que le suivi des modifications d'EF impose de modifier. Elles ne sortent jamais de `Dal` : `Dal` renvoie des `record`.

## Données : database-first + DbUp

- **Le schéma est défini en SQL**, pas par EF. Toute modification de la base est un nouveau fichier dans `backend/db/migrations/` : **`NNNN.<issue>.<slug>.sql`**, par exemple `0042.123.add-invoice-status.sql`.
  - `NNNN` : numéro d'ordre sur 4 chiffres, le suivant du plus grand existant. La CI refuse deux fichiers avec le même numéro.
  - **Un fichier appliqué ne se modifie jamais** : on en ajoute un nouveau.
  - **Compatible avec la version précédente de l'app** : la migration s'exécute pendant que l'ancienne version sert encore. On ajoute une colonne avant de retirer l'ancienne, à la release suivante ; une colonne renommée en une seule release, c'est une panne pendant le déploiement.
- **Le code EF est généré** depuis la base (`dotnet ef dbcontext scaffold`) dans `MyApp.Dal/Generated/`, **jamais modifié à la main** : les ajouts passent par des classes `partial` à côté.
- **Le subagent `db-ops`** (Haiku) applique les migrations sur la base locale puis relance le scaffolding. Le déléguer à chaque fichier SQL ajouté.
- **L'exécutable `MyApp.Migrations` applique chaque script dans sa propre transaction** (`WithTransactionPerScript()`) : un script qui échoue n'est pas appliqué à moitié. Conséquence : pas de `CREATE INDEX CONCURRENTLY` dans une migration.
- **En production**, les migrations tournent dans le cluster : l'image `MyApp.Migrations` est lancée par un Job ArgoCD avant le déploiement (PreSync). La CI n'a jamais accès à la base.
- **Lectures** : `AsNoTracking`, projection directe vers un `record` avec `Select`, pagination bornée, `CancellationToken`. Le skill `optimizing-ef-core-queries` sert de grille de revue.
- **Écritures** : dans `Dal` uniquement, par le suivi d'EF ou `ExecuteUpdateAsync` / `ExecuteDeleteAsync`.
- Noms côté base en `snake_case` ; le scaffolding produit du PascalCase côté C#.

## Clients : un client par API appelée

- **Un dossier `Clients/<Service>/` par API**, qu'elle soit à toi (`feedback`…) ou tierce (GitHub, météo…). Le front n'appelle jamais une API tierce directement.
- **Refit** pour l'interface typée. Pour **tes propres API**, l'interface est **générée depuis leur OpenAPI** (Refitter) ; les clients partagés entre apps sont publiés dans `libs` (`MarbleStudio.<Service>.Client`).
- **Résilience** : le gestionnaire standard de .NET (`AddStandardResilienceHandler`, Polly v8 en interne) : nouvelles tentatives, délai maximal, coupe-circuit.
- **Cache applicatif** : `HybridCache`, avec une durée explicite par type de donnée. (Polly v8 ne fait plus de cache.)
- **Les réponses externes sont converties en `record` internes dès la frontière** : le reste du code ne voit jamais le format du fournisseur.
- URL et délais dans des options typées ; clés et jetons en variables d'environnement (secrets).

## Contrats (DTO)

- `sealed record`, propriétés `required` + `init` pour les requêtes, records positionnels pour les réponses.
- Nommage : `Create<Sujet>Request`, `Update<Sujet>Request`, `<Sujet>Response`, `<Sujet>ListResponse`.
- Commentaires XML `<summary>` sur chaque DTO exposé : ils alimentent OpenAPI.
- Dates : **`DateTimeOffset`**, jamais `DateTime`. Énumérations sérialisées en chaînes.
- Une entité EF n'est jamais exposée par l'API.

## Validation

- **FluentValidation** : un validateur par requête, dans `MyApp.Api/Validators/`. Il est appliqué automatiquement par le filtre de `MarbleStudio.Hosting`, et ses erreurs sortent en Problem Details (`ValidationProblemDetails`, détail par champ).
- La validation d'entrée vérifie la forme. Une règle métier (doublon, état incompatible) se vérifie dans le service.

## Authentification, utilisateur courant, droits

- **Tout endpoint exige un utilisateur connecté par défaut** (politique de repli). L'accès anonyme se déclare explicitement avec `[AllowAnonymous]`.
- Mode `oidc` : validation du jeton Authentik (`JwtBearer`). Mode `forward-auth` : identité lue dans les en-têtes posés par Authentik. Ces en-têtes ne sont fiables que parce qu'une NetworkPolicy garantit que seul Traefik peut joindre l'app.
- **`ICurrentUser`** (fourni par `MarbleStudio.Hosting`) est le seul accès à l'identité : identifiant, email, nom, rôles, permissions. Personne ne lit `HttpContext` ailleurs.
- **Rôles** : groupes Authentik `<app>-<rôle>` (`factures-admin`…), reçus dans le jeton. **Permissions** : définies par l'app (`Invoices.Read`, `Invoices.Write`…), dérivées des rôles, vérifiées par des *policies* : `[Authorize(Policy = Permissions.Invoices.Write)]`. **Le code ne teste jamais un rôle**, toujours une permission.
- **Impersonation** : un utilisateur avec la permission `Users.Impersonate` envoie l'en-tête `X-Impersonate-User: <id>`. `ICurrentUser` expose alors l'utilisateur **effectif** et l'utilisateur **réel** ; chaque action est journalisée avec les deux. Une impersonation ne donne jamais la permission d'impersonner.

## Configuration

- **Options typées validées au démarrage** (`ValidateOnStart`) : une config invalide arrête l'app immédiatement.
- `appsettings.json` : valeurs par défaut. `appsettings.Local.json` : poste local (`ASPNETCORE_ENVIRONMENT=Local`), **sans secret**.
- **Pas d'`appsettings.Production.json`** : la config de prod vit dans `homelab` et arrive en variables d'environnement (`Section__Cle`). Les dépôts d'apps sont publics, et la même image tourne partout.
- **Aucun secret dans un fichier `appsettings*`** : variables d'environnement uniquement (`sops exec-env` en local, Secret Kubernetes en prod).

## Transverse : `MarbleStudio.Hosting`

Une ligne dans `Program.cs` (`builder.AddMarbleStudioDefaults()`) branche : logs JSON, OpenTelemetry (export désactivé par défaut), Problem Details et gestionnaire d'exceptions, validation FluentValidation, `/healthz` et `/ready`, OpenAPI (+ Scalar en local), identifiant de corrélation, authentification et `ICurrentUser`. **On ne recâble pas ces briques à la main dans une app.**

## Temps réel (SignalR)

- Hubs **fortement typés** (`Hub<IInvoiceClient>`) dans `MyApp.Api/Hubs/`, exposés sur `/hubs/<nom>`, avec la même authentification que l'API.
- Les interfaces de contrat vivent dans `MyApp.Contracts` : **les types TypeScript du front en sont générés**, jamais écrits à la main.

## Style

- Espaces de noms déclarés sur une ligne, **constructeurs primaires**, classes **`sealed`** par défaut (les analyseurs ne le vérifient que pour les types `internal` : pour les types publics, c'est à la revue), un type par fichier, dossiers = espaces de noms.
- Méthodes asynchrones suffixées `Async`, `CancellationToken` en dernier paramètre.
- `dotnet format` et le build (avertissements = erreurs) tournent à chaque fin de tour d'agent.

## Tests

- **xUnit v3**, **Shouldly** pour les assertions, **NSubstitute** pour les doublures.
- **Unitaires** : les services, avec `Dal` et `Clients` simulés.
- **Intégration** : l'API via `WebApplicationFactory`, contre le **Postgres local** (Docker), **recréé et migré par DbUp à chaque lancement de `scripts/test.ps1`**. Pas de Testcontainers.
- **Architecture** : le test NetArchTest des dépendances entre couches.
- Nommage : `Methode_QuandCondition_DoitResultat` (en anglais : `GetById_WhenMissing_ReturnsNotFound`).

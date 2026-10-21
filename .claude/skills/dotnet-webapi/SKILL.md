---
name: dotnet-webapi
description: >
  Ajoute ou modifie un endpoint d'API ASP.NET Core dans ce projet : contrôleur, DTO,
  validateur FluentValidation, service, codes HTTP, métadonnées OpenAPI, fichier .http.
  À utiliser pour toute création ou modification d'endpoint. Pas pour l'accès aux données
  (voir optimizing-ef-core-queries et l'agent db-ops), ni pour les hubs SignalR.
license: MIT
---
<!-- Adapté de dotnet/skills (plugins/dotnet-aspnetcore/skills/dotnet-webapi), licence MIT, Copyright (c) .NET Foundation and Contributors (texte complet : LICENSE, dans ce dossier). Modifications : contrôleurs uniquement, FluentValidation, ServiceResult, couches Controller → Service → Dal / Clients, droits par permissions. -->

# Endpoint d'API ASP.NET Core

Les conventions du projet (`.harness/modules/dotnet/conventions.md`) priment. Ce skill en est la procédure.

## Étape 1 : situer le changement

- Repère le contrôleur concerné dans `MyApp.Api/Controllers/`, le service dans `MyApp.Services/`, les DTO dans `MyApp.Contracts/`.
- **Contrôleurs uniquement** : jamais de Minimal API dans ce projet.
- Si l'endpoint touche la base et que le schéma doit changer : d'abord une migration SQL et l'agent `db-ops`, ensuite l'endpoint.

## Étape 2 : les DTO (`MyApp.Contracts`)

| Rôle | Nom | Forme |
|---|---|---|
| Création | `Create<Sujet>Request` | `sealed record`, propriétés `required` + `init` |
| Mise à jour | `Update<Sujet>Request` | idem |
| Réponse unitaire | `<Sujet>Response` | `sealed record` positionnel |
| Réponse liste | `<Sujet>ListResponse` | `sealed record` positionnel, `IReadOnlyList<T>` |

- Commentaire XML `<summary>` **en anglais** sur chaque DTO et chaque action : il alimente OpenAPI, donc le client généré du front.
- Dates en **`DateTimeOffset`**, énumérations sérialisées en chaînes.
- Jamais d'entité EF exposée.

```csharp
/// <summary>Payload for creating an invoice.</summary>
public sealed record CreateInvoiceRequest
{
    public required string Customer { get; init; }
    public required decimal Amount { get; init; }
    public required DateTimeOffset DueDate { get; init; }
}

/// <summary>An invoice returned by the API.</summary>
public sealed record InvoiceResponse(Guid Id, string Customer, decimal Amount, InvoiceStatus Status, DateTimeOffset DueDate);
```

## Étape 3 : le validateur (`MyApp.Api/Validators/`)

Un validateur FluentValidation par requête. Il s'applique automatiquement (filtre de `MarbleStudio.Hosting`) ; ne pas l'appeler à la main dans le contrôleur.

```csharp
public sealed class CreateInvoiceRequestValidator : AbstractValidator<CreateInvoiceRequest>
{
    public CreateInvoiceRequestValidator()
    {
        RuleFor(x => x.Customer).NotEmpty().MaximumLength(200);
        RuleFor(x => x.Amount).GreaterThan(0);
    }
}
```

La validation vérifie la **forme**. Une règle métier (doublon, état incompatible) va dans le service.

## Étape 4 : le service (`MyApp.Services/`)

- Interface `I<Sujet>Service` + implémentation `sealed`, enregistrée par l'interface.
- Reçoit et renvoie des `record` immuables. Ne modifie jamais un paramètre : copie avec `with`.
- **Cas prévus = résultat explicite**, pas d'exception : `ServiceResult<T>.NotFound()`, `.Conflict(...)`, `.Forbidden()`, `.Invalid(...)`.
- Utilise `ICurrentUser` pour l'identité, jamais `HttpContext`.
- `CancellationToken` transmis à chaque appel (`Dal`, `Clients`).

## Étape 5 : le contrôleur (`MyApp.Api/Controllers/`)

```csharp
[ApiController]
[Route("api/invoices")]
public sealed class InvoicesController(IInvoiceService invoices) : ControllerBase
{
    /// <summary>Gets an invoice by its identifier.</summary>
    [HttpGet("{id:guid}", Name = "GetInvoice")]
    [Authorize(Policy = Permissions.Invoices.Read)]
    [ProducesResponseType<InvoiceResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<InvoiceResponse>> Get(Guid id, CancellationToken cancellationToken) =>
        (await invoices.GetAsync(id, cancellationToken)).ToActionResult(this);

    /// <summary>Creates an invoice.</summary>
    [HttpPost]
    [Authorize(Policy = Permissions.Invoices.Write)]
    [ProducesResponseType<InvoiceResponse>(StatusCodes.Status201Created)]
    [ProducesResponseType<ValidationProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<InvoiceResponse>> Create(CreateInvoiceRequest request, CancellationToken cancellationToken) =>
        (await invoices.CreateAsync(request, cancellationToken))
            .ToCreatedAtRoute(this, "GetInvoice", created => new { id = created.Id });
}
```

| Opération | Succès | Erreurs courantes |
|---|---|---|
| GET (un) | 200 | 404 |
| GET (liste) | 200 | — |
| POST | **201 + en-tête `Location`** | 400, 409 |
| PUT / PATCH | 200 | 400, 404 |
| DELETE | **204** | 404, 409 |

- Chaque code possible déclaré par `[ProducesResponseType]`.
- **Toujours une permission** (`[Authorize(Policy = …)]`), jamais un rôle. L'accès anonyme se déclare explicitement par `[AllowAnonymous]`.
- Aucun accès à `Dal` ou `Clients` depuis un contrôleur : le test d'architecture le refuse.

## Étape 6 : le fichier `.http`

**Un fichier `.http` par contrôleur, à côté de lui** (`Controllers/InvoicesController.http`) : une requête par action, avec un corps réaliste et au moins un cas d'erreur (identifiant inexistant, requête invalide).

## Étape 7 : vérifier

1. `dotnet build backend` : zéro erreur, zéro avertissement.
2. `scripts/test.ps1` : tests unitaires du service, tests d'intégration de l'endpoint, test d'architecture.
3. L'endpoint apparaît dans `/openapi/v1.json` avec ses codes de retour.
4. Si le front consomme l'endpoint : régénérer son client (`pnpm api:generate`).

## Pièges

| Piège | À la place |
|---|---|
| Logique métier dans le contrôleur | Dans le service |
| Exception pour « introuvable » ou « conflit » | `ServiceResult<T>` |
| Paramètre modifié dans un service | Copie avec `with` |
| `[Authorize(Roles = "...")]` | `[Authorize(Policy = Permissions.X.Y)]` |
| POST qui renvoie 200 | 201 avec `Location` |
| `DateTime` | `DateTimeOffset` |
| `CancellationToken` oublié | Dans chaque action, transmis partout |
| Swashbuckle | OpenAPI intégré (déjà branché par `MarbleStudio.Hosting`) |

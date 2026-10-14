# Conventions jeu multijoueur

Module `game` du harness, pour les projets issus de `template-game-multi`. S'ajoute aux modules `dotnet` et `react`, et aux conventions communes.

**Genres visés** : jeux de soirée et de plateau au tour par tour (quiz, cartes, dés, mots, dessin), et temps réel léger (réflexes, buzzer). **Hors périmètre** : l'action en temps réel continu (déplacements, collisions, prédiction côté client), à traiter jeu par jeu par un ADR.

## Le serveur fait autorité

- **Toute la logique de jeu tourne sur le serveur, en C#.** Les clients envoient des **intentions** (« jouer cette carte »), le serveur les vérifie, applique les règles et diffuse le résultat.
- Le client ne calcule jamais un résultat de jeu : il affiche l'état reçu. Il peut seulement anticiper l'affichage (animation) en attendant la confirmation.
- Toute intention invalide (pas son tour, carte absente, partie terminée) est refusée par le serveur avec une raison, jamais ignorée en silence.

## Les règles sont des fonctions pures

- L'état d'une partie est un **`record` immuable** (`GameState`), les intentions sont des `record` (`PlayCard`, `Answer`…).
- **`Apply(GameState state, GameAction action) → (GameState newState, IReadOnlyList<GameEvent> events)`** : aucune dépendance (ni SignalR, ni horloge, ni hasard non injecté, ni base).
- Le hasard (tirage, mélange) et le temps sont **injectés** (graine, horodatage dans l'action) : une partie se rejoue à l'identique à partir de son état de départ et de ses actions.
- Le temps réel léger passe par le même mécanisme : une horloge serveur envoie des actions `Tick` / `TimeElapsed` à la salle.
- Les règles (`MyGame.Services/Game/`) ne dépendent ni de SignalR ni des salles : elles pourraient servir à un mode solo ou à un bot.

## Salles

- Une salle = une partie, identifiée par un **code court** (4 lettres, sans caractères ambigus) et un lien partageable.
- **Chaque salle traite ses actions une par une, dans sa propre file** (`Channel`) : pas de verrou, pas d'action concurrente sur un même état.
- Salles en mémoire, une seule instance de l'app (pas de relais Redis ; au-delà, `/evolve`).
- **Reconnexion** : un joueur déconnecté garde sa place pendant un délai réglable (30 s par défaut). Les autres sont prévenus ; le jeu décide d'attendre ou de continuer sans lui.

## Joueurs

- **Invités par défaut** : un pseudo et un jeton émis par le serveur, gardé dans le navigateur. Aucun compte requis pour jouer.
- **Connexion Authentik en option** (Google compris), pour un profil persistant, des statistiques et un historique.
- Le jeton d'invité est **un schéma d'authentification à part entière** (enregistré à côté de celui d'Authentik) : la règle « tout endpoint exige un utilisateur connecté » reste vraie, un invité est un utilisateur connecté. `ICurrentUser` indique s'il s'agit d'un invité.

## Persistance (option `postgres`, database-first comme le module dotnet)

- **Profils, scores, historique des parties.**
- **Sauvegardes de partie** : l'état sérialisé (JSON, colonne `jsonb`) est enregistré **après chaque action appliquée**. Une partie se reprend depuis sa dernière sauvegarde : après un redémarrage du serveur, ou plus tard, à la demande des joueurs.
- **Chaque sauvegarde porte la version du format de l'état** (`state_version`). Quand `GameState` change de forme, une fonction de conversion fait passer les anciennes sauvegardes au nouveau format au chargement : une sauvegarde ne doit jamais devenir illisible.
- Sans l'option `postgres`, une partie en cours est perdue au redémarrage.

## Front

- **React + shadcn**, avec le thème propre au jeu, pour tout ce qui est interface : accueil, salle d'attente, menus, scores, chat.
- **Le plateau** est un composant de rendu alimenté par le store Zustand : **DOM + CSS** par défaut (animations CSS, accessible) ; **PixiJS** si le jeu affiche beaucoup d'éléments animés (par ADR).
- Les menus restent utilisables au clavier, le plateau peut s'en affranchir.

## Organisation

Les couches du module `dotnet` s'appliquent : l'Api reste mince, la logique vit dans les services.

**Des salles vers les joueurs** : `Rooms` publie ses événements par une interface définie dans `Services` (`IRoomNotifier`). L'Api l'implémente avec `IHubContext<GameHub, IGameClient>`. Les services ne dépendent donc jamais de SignalR.

```
backend/src/
├── MyGame.Api/Hubs/         GameHub typé : reçoit les intentions, les transmet, diffuse les événements
├── MyGame.Contracts/        intentions, événements, interfaces du hub (TypeScript généré)
├── MyGame.Services/
│   ├── Game/                GameState, actions, événements, Apply() : les règles, sans dépendance
│   └── Rooms/               salles : file par salle, codes, reconnexion, horloge
└── MyGame.Dal/              profils, scores, sauvegardes de partie (option postgres)
frontend/src/features/
├── lobby/                   accueil, rejoindre, salle d'attente
└── game/                    plateau, contrôles, scores
```
## Tests

- **Les règles d'abord** : tests unitaires xUnit sur `Apply()`, un état de départ, une suite d'actions, l'état et les événements attendus. C'est là que va l'essentiel de l'effort.
- **Les sauvegardes** : un test par ancienne `state_version`, qui vérifie qu'elle se convertit et se rejoue.
- **Le hub** : quelques tests d'intégration où deux clients SignalR jouent une partie complète contre le serveur.
- **Le front** : comme le module react (Vitest, Testing Library, un parcours Playwright).

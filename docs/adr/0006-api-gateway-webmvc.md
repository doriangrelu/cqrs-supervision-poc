# ADR-0006 — API Gateway : Spring Cloud Gateway Server WebMVC

- **Statut** : accepté
- **Date** : 2026-09-24

## Contexte

Un point d'entrée unique route vers le côté écriture (`/orders`) et le côté lecture (`/orders-view`), et porte les
règles transverses (corrélation, sécurité à venir). L'équipe travaille en Spring MVC (servlet) ; la pile réactive
(WebFlux) n'apporte pas de bénéfice suffisant pour justifier un second modèle de programmation, d'autant que les
threads virtuels (Java 21+) lèvent l'essentiel de la contrainte de scalabilité.

## Décision

Spring Cloud Gateway **Server WebMVC** (`spring-cloud-starter-gateway-server-webmvc`), routes déclarées en YAML,
URLs des services en variables d'environnement, timeouts explicites vers l'aval.

Responsabilités de la gateway :

- routage CQRS (écriture / lecture) ;
- trace racine de chaque requête et en-tête de réponse `X-Trace-Id` (identifiant à transmettre au support) ;
- suppression de l'en-tête `baggage` entrant (les champs de corrélation sont posés par nos services).

## Conséquences

- ➕ Même modèle de programmation et même outillage d'observabilité que les services.
- ➖ Spring Cloud 2025.1 cible Boot 4.0 alors que le projet est en Boot 4.1 (imposé par Namastack) : vérificateur
  de compatibilité désactivé, à réactiver à la sortie du train Spring Cloud aligné.
- À venir en production : authentification (OAuth2 / JWT, `spring-boot-starter-oauth2-resource-server`), limitation
  de débit, CORS.

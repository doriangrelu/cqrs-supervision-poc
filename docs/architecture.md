# Architecture

- [Principes](#principes)
- [Vue d'ensemble](#vue-densemble)
- [Modules Maven](#modules-maven)
- [Parcours d'une écriture](#parcours-dune-écriture)
- [Organisation du code](#organisation-du-code)
- [Gestion des erreurs](#gestion-des-erreurs)
- [Décisions (ADR)](#décisions-adr)

## Principes

1. **Le service qui stocke la donnée en est propriétaire et fait autorité.** Pas d'event store : les événements
   notifient un changement d'état ([ADR-0001](adr/0001-cqrs-sans-event-store.md)).
2. **Aucun événement perdu** : écriture et événement dans la même transaction, publication par outbox
   ([ADR-0002](adr/0002-transactional-outbox-namastack.md)).
3. **Projections idempotentes et jetables** : événements porteurs d'état, upsert conditionnel sur la version,
   reconstruction par rejeu ([ADR-0003](adr/0003-event-carried-state-transfer.md)).
4. **Métier isolé de la technique** : clean architecture vérifiée par ArchUnit ([ADR-0004](adr/0004-clean-architecture.md)).
5. **Cohérence à terme mesurée, pas subie** : lag décomposé, traces de bout en bout, alertes
   ([ADR-0005](adr/0005-observabilite-opentelemetry.md), [observability.md](observability.md)).

## Vue d'ensemble

```
                         ┌──────────────── écriture (command) ────────────────┐
client ──► gateway ──────┤ /orders/**        order-service                    │
          (Spring Cloud  │                     ├─ Postgres orders_write       │
           Gateway MVC)  │                     │    orders + outbox_record    │ même transaction
                         │                     └─ scheduler outbox ──► Kafka orders.events (clé = orderId)
                         │                                                    │
                         └──────────────── lecture (query) ───────────────────┤
                           /orders-view/**   order-projector ◄── @KafkaListener
                                               └─ Postgres orders_read (order_view, upsert idempotent)
                                               └─ échec définitif ──► orders.events.DLT
```

## Modules Maven

| Module | Rôle | Réutilisable tel quel |
|---|---|---|
| `observability-starter` | auto-configuration commune : tracing, spans par couche, corrélation, défauts d'exploitation ([README](../observability-starter/README.md)) | oui : base technique |
| `event-contract` | contrat d'intégration publié (`OrderEvent`, topics) ; Java pur, sans dépendance | modèle d'un module contrat par contexte métier |
| `gateway` | point d'entrée, routage CQRS, `X-Trace-Id`, suppression du baggage entrant | oui : routes à adapter |
| `order-service` | propriétaire des commandes : REST, domaine, outbox | modèle d'un service propriétaire |
| `order-projector` | modèle de lecture des commandes | modèle d'un projecteur |

## Parcours d'une écriture

1. `POST /orders` arrive à la gateway : trace racine, en-tête `baggage` client supprimé, `X-Trace-Id` renvoyé.
2. `order-service`, adapter web : validation du DTO, génération de l'`OrderId`, pose du baggage `order.id`.
3. Use case `CreateOrderService` → `UnitOfWork.inTransaction` : `Order.create(...)` (invariants, événement de
   domaine `OrderCreated`), `OrderRepository.save`, `OrderEventPublisher.publish` (traduction en `OrderEvent`,
   `outbox.schedule`). **Commit unique.**
4. Scheduler Namastack (≈100 ms) : publication sur `orders.events`, clé = `orderId`, en-têtes `traceparent`,
   `baggage`, `eventType`.
5. `order-projector` : conversion + validation du message, use case `ProjectOrderService`,
   `OrderViewStore.saveIfNewer` (upsert si version plus récente), métriques de lag.
6. `GET /orders-view/{id}` lit la projection ; son `lastVersion` indique quelle écriture elle reflète.

## Organisation du code

Même découpage dans chaque service, racine `poc.exploit.<contexte>` :

```
domain/
  model/                  agrégats, value objects (Order, OrderId, Money, OrderStatus) — Java pur
  event/                  événements de domaine (OrderDomainEvent scellé, OrderCreated, OrderStatusChanged)
  exception/              violations des règles métier
application/
  port/in/usecase/        ce que le service offre (CreateOrderUseCase…)
  port/in/command/        entrées des use cases (commands, queries)
  port/in/result/         sorties dédiées quand l'agrégat ne convient pas (ProjectionResult)
  port/out/persistence/   besoins de stockage (OrderRepository, UnitOfWork, OrderViewStore)
  port/out/messaging/     besoins de publication (OrderEventPublisher)
  service/                implémentation des use cases — Java pur, sans annotation Spring
infrastructure/
  adapter/in/web/         controller/, dto/ (Bean Validation), error/ (RFC 9457)
  adapter/in/messaging/   listener/ (@KafkaListener mince), mapper/ (contrat → command, validation)
  adapter/in/loadtest/    génération de charge, désactivée par défaut
  adapter/out/persistence/  repository/ | store/ (JdbcClient), transaction/ (TransactionTemplate)
  adapter/out/messaging/  publisher/ (outbox), mapper/ (domaine → contrat), config/ (routage Kafka)
  config/                 câblage Spring (@Bean des use cases, Kafka, @ConfigurationProperties)
  observability/          corrélation (baggage), métriques métier
```

Chaque package de premier niveau a un `package-info.java` qui rappelle son rôle et ses règles.

### Règles de dépendance (ArchUnit, à chaque build)

```
infrastructure ──► application ──► domain
      │                 ▲
      └─────────────────┘  (adapters entrants → port.in uniquement ; adapters sortants implémentent port.out)
```

- `domain` : ne dépend que de `java.*`.
- `application` : ne dépend que de `domain` ; ni Spring, ni Jakarta, ni Kafka, ni `event-contract`.
- adapters entrants : n'utilisent que `port.in` ; adapters sortants : n'implémentent / n'utilisent que `port.out`.
- adapters entrants et sortants s'ignorent ; les services applicatifs ne sont instanciés que par `config`.
- les beans des couches `application` et `adapter.out` ne sont pas `final` (proxies du tracing automatique).

### Où placer quoi

| Besoin | Emplacement |
|---|---|
| Règle métier, invariant, transition d'état | `domain/model` |
| Orchestration (charger, décider, sauver, publier) | `application/service` |
| Validation de forme d'une requête HTTP | DTO (`adapter/in/web/dto`), Bean Validation |
| Validation d'un message entrant | `adapter/in/messaging/mapper` |
| Transaction | port `UnitOfWork`, appelé par le use case |
| Traduction événement de domaine → contrat public | `adapter/out/messaging/mapper` |
| Corrélation, métriques | `infrastructure/observability` |
| Tout ce qui est transverse à tous les services | `observability-starter` |

## Gestion des erreurs

**HTTP** : RFC 9457 (`application/problem+json`), `type` stable par cas, jamais de stacktrace ni de valeur rejetée.

| Cas | Statut | `type` |
|---|---|---|
| Requête invalide (validation, JSON illisible, invariant du domaine) | 400 | `https://errors.poc.exploit/invalid-request` (+ `errors[]`) |
| Commande / vue inconnue | 404 | `…/order-not-found`, `…/order-view-not-found` |
| Transition de statut interdite | 409 | `…/illegal-status-transition` (+ `currentStatus`, `requestedStatus`) |
| Erreur inattendue | 500 | `…/internal-error` (détail dans les logs, avec le traceId) |

**Publication (outbox)** : retries exponentiels (2 s → 1 min, 10 tentatives), puis statut `FAILED` → alerte
`OutboxRecordsFailed`. `stop-on-first-failure` : un échec bloque les événements suivants **du même agrégat**
(ordre préservé), pas les autres.

**Consommation (projecteur)** :

| Cas | Traitement |
|---|---|
| JSON illisible, message invalide, `schemaVersion` non supporté, erreur de données SQL | DLT immédiate |
| Base indisponible, erreur transitoire, erreur non classée | backoff exponentiel (500 ms ×2, max 5 s, 5 tentatives) puis DLT |

La DLT conserve le message d'origine et ses en-têtes (`traceparent`, `kafka_dlt-exception-*`). Procédure :
[observability.md § DeadLetterMessages](observability.md#deadlettermessages).

## Décisions (ADR)

| # | Décision |
|---|---|
| [0001](adr/0001-cqrs-sans-event-store.md) | CQRS par projections, sans event store |
| [0002](adr/0002-transactional-outbox-namastack.md) | Transactional outbox avec Namastack |
| [0003](adr/0003-event-carried-state-transfer.md) | Événements porteurs d'état, projections idempotentes |
| [0004](adr/0004-clean-architecture.md) | Clean architecture dans chaque service |
| [0005](adr/0005-observabilite-opentelemetry.md) | Observabilité OpenTelemetry, starter commun |
| [0006](adr/0006-api-gateway-webmvc.md) | Spring Cloud Gateway Server WebMVC |

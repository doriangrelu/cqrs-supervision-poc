# Base technique CQRS : outbox → Kafka → projections, supervisée avec OpenTelemetry

Socle de référence pour des microservices **CQRS sans event store** : le service propriétaire de la donnée fait
autorité, publie ses événements métier via un **transactional outbox**, et des **projecteurs** construisent des
modèles de lecture. La cohérence à terme est **mesurée, tracée et alertée**.

```
client ──► gateway ──► order-service ──(outbox, même transaction)──► Kafka ──► order-projector ──► vue de lecture
              │             Postgres orders_write                                 Postgres orders_read
              └──────────────────────────── /orders-view ──────────────────────────────┘
```

## Documentation

| Document | Contenu |
|---|---|
| [docs/architecture.md](docs/architecture.md) | principes, modules, parcours d'une écriture, organisation du code, gestion des erreurs |
| [docs/observability.md](docs/observability.md) | lag de cohérence, traces, corrélation, métriques, logs, **runbook des alertes**, reconstruction d'une projection |
| [docs/configuration.md](docs/configuration.md) | variables d'environnement de chaque application |
| [docs/guide-nouveau-service.md](docs/guide-nouveau-service.md) | **décliner cette base** dans un nouveau service |
| [docs/production-checklist.md](docs/production-checklist.md) | ce qui est prêt pour la production, ce qui reste à faire selon le contexte |
| [docs/adr/](docs/adr/) | décisions d'architecture (CQRS, outbox, projections, clean architecture, observabilité, gateway) |
| [observability-starter/README.md](observability-starter/README.md) | le starter d'observabilité commun |

## Stack

| Composant | Version | Licence |
|---|---|---|
| Java / Spring Boot | 25 / 4.1.1 | GPLv2+CE / Apache 2.0 |
| Spring Cloud Gateway Server WebMVC | 2025.1.3 (5.0.3) | Apache 2.0 |
| Namastack Outbox | 1.9.0 | Apache 2.0 |
| Kafka (KRaft) | 4.3.1 | Apache 2.0 |
| PostgreSQL | 18 | PostgreSQL License |
| OpenTelemetry Collector, Jaeger v2, Prometheus, kafka-exporter | — | Apache 2.0 |
| datasource-micrometer, ArchUnit | 2.3.0, 1.5.0 | Apache 2.0 |
| Grafana | 13.2 | **AGPLv3** (exception assumée : standard de l'entreprise, [ADR-0005](docs/adr/0005-observabilite-opentelemetry.md)) |

## Démarrage

Prérequis : Java 25, Maven 3.8+, Docker, Git Bash (Windows) ou un shell POSIX, Node.js (script de traces).

```bash
docker compose -f infra/docker-compose.yml up -d        # middlewares
mvn clean install                                      # build + tests (domaine, architecture)
scripts/run-apps.sh                                    # 3 applis en arrière-plan, logs dans ./logs
scripts/activity.sh -d 120 -w 6 -r 10                  # activité aléatoire via la gateway
```

Arrêt des applis : `pwsh scripts/stop-apps.ps1`. Variante tout-conteneur :
`docker compose -f infra/docker-compose.yml --profile apps up -d --build`.

| Interface | URL |
|---|---|
| Gateway (API) | http://localhost:8080 |
| Grafana, dashboard « Cohérence CQRS » | http://localhost:3000/d/coherence-cqrs |
| Jaeger | http://localhost:16686 |
| Prometheus (alertes : onglet Alerts) | http://localhost:9090 |
| Kafka UI | http://localhost:8090 |

## API (via la gateway)

```bash
curl -i -X POST localhost:8080/orders -H 'Content-Type: application/json' -d '{"customerId":"c1","amount":42}'
curl -X PATCH localhost:8080/orders/{id}/status -H 'Content-Type: application/json' -d '{"status":"PAID"}'
curl localhost:8080/orders/{id}                 # côté écriture (source de vérité)
curl localhost:8080/orders-view/{id}            # côté lecture (projection : lastVersion, projectedAt)
curl localhost:8080/orders-view?limit=20        # dernières projections
curl -X POST "localhost:8080/orders/_bulk?count=5000"   # charge (LOAD_TEST_ENABLED, activé par run-apps.sh)
```

- Statuts : `CREATED → PAID → SHIPPED`, `CREATED | PAID → CANCELLED` ; toute autre transition → 409.
- Erreurs au format RFC 9457 (`application/problem+json`).
- Chaque réponse porte `X-Trace-Id` : la trace complète, jusqu'à la projection, dans Jaeger.

## Outils

| Script | Usage |
|---|---|
| `scripts/run-apps.sh [args projecteur]` | lance les 3 applis (local : `_bulk` actif, historique outbox conservé) |
| `scripts/stop-apps.ps1` | arrête les applis (ports 8080-8082) |
| `scripts/activity.sh -d <s> -w <clients> -r <req/s>` | clients simulés (créations, transitions, ~10 % de 409, lectures) ; mesure les **lectures périmées** |
| `node scripts/traces.mjs <service> [nb] [min]` | arbre des dernières traces (`ATTRS=1` attributs, `OP=<opération>` filtre) |

Sous Git Bash, lancer `curl` coûte cher : ~10 req/s au total avec `activity.sh` ; pour de la vraie charge, `_bulk`.

## Scénarios de démonstration

| Scénario | Action | Ce qu'on observe |
|---|---|---|
| Rafale | `curl -X POST "localhost:8080/orders/_bulk?count=5000"` | lag Kafka qui monte puis se résorbe ; décomposition du lag |
| Projecteur arrêté | arrêter `order-projector`, écrire, relancer | lag en messages qui grimpe (vu par kafka-exporter), rattrapage au redémarrage |
| Kafka arrêté | `docker stop poc-kafka`, écrire, `docker start poc-kafka` | backlog outbox qui gonfle puis se vide, **aucune perte** |
| Message empoisonné | Kafka UI → `orders.events` → Produce, JSON invalide | DLT immédiate, alerte `DeadLetterMessages` |
| Base de lecture KO | `docker pause poc-postgres` ~10 s puis `unpause` | retries exponentiels, lag qui remonte puis se résorbe |
| Doublon | rejouer un message depuis Kafka UI | `outcome=skipped`, vue inchangée |
| Reconstruction | [observability.md § Reconstruire une projection](docs/observability.md#reconstruire-une-projection) | la vue se reconstruit à l'identique |

## Pièges rencontrés (Boot 4.1, Spring Kafka 4, Namastack 1.9, outillage)

- Traces OTLP : `management.opentelemetry.tracing.export.otlp.endpoint` (l'ancien `management.otlp.tracing.*` est
  déprécié). Le starter OpenTelemetry active l'export OTLP des métriques par défaut : désactivé au profit du scrape
  Prometheus (exemplars).
- `DeadLetterPublishingRecoverer` publie par défaut vers `<topic>-dlt` en Spring Kafka 4 : resolver explicite.
- Namastack : `poll-interval` / `batch-size` dépréciés → `polling.fixed.interval` / `polling.batch-size` ; le module
  `observability` suffit à propager la trace (`namastack-outbox-tracing` est déprécié).
- Micrometer ≥ 1.14 : une observation écartée par un `ObservationPredicate` reste « courante » (noop) ; un filtre
  « pas de parent » doit aussi tester `isNoop()`.
- `Advisor` déclaré dans une auto-configuration : `static` + `@Role(ROLE_INFRASTRUCTURE)`, sinon avertissement
  « not eligible for getting processed by all BeanPostProcessors ».
- Hikari n'accepte pas les durées (`5s`) : millisecondes.
- `@Validated` sur un controller ajoute un proxy qui lève `ConstraintViolationException` (500) : Spring MVC 7 valide
  nativement `@Min` / `@Max` sur les paramètres.
- Spring Cloud 2025.1 cible Boot 4.0 : vérificateur de compatibilité désactivé dans la gateway.
- Jaeger 2.21 : API HTTP v1 `/api/traces` supprimée → `/api/v3/traces`.
- Git Bash : `docker exec` avec un chemin absolu nécessite `MSYS_NO_PATHCONV=1`.
- Docker Desktop Windows : Grafana ne voit pas à chaud les nouveaux fichiers de dashboard → `docker restart poc-grafana`.
- Windows : un jar en cours d'exécution est verrouillé ; arrêter les applis avant `mvn package`. Après une
  modification du starter : `mvn clean install` (sinon les jars des services embarquent l'ancienne version).

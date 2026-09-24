# POC CQRS-like : outbox Namastack → Kafka → projecteurs, supervisés via OpenTelemetry

Le service propriétaire de la donnée fait autorité ; pas d'event store. Les événements métier
sont publiés via un **transactional outbox** (Namastack) puis projetés dans un modèle de lecture.
Objectif du POC : **ne pas être aveugle sur la cohérence à terme**.

```
client ──► gateway :8080 (Spring Cloud Gateway Server WebMVC)
             ├─ /orders/**       ──► order-service :8081  ──► Postgres orders_write (orders + outbox_*)
             │                          └─ scheduler Namastack ──► Kafka orders.events (6 partitions, clé = orderId)
             └─ /orders-view/**  ──► order-projector :8082 ◄── @KafkaListener
                                        └─ upsert idempotent ──► Postgres orders_read (order_view)
                                        └─ échec ──► orders.events.DLT

traces  : applis ──OTLP──► otel-collector ──► Jaeger  (+ spanmetrics ──► Prometheus)
métriques : Prometheus ◄── scrape /actuator/prometheus (exemplars) + kafka-exporter
dashboards : Grafana (Prometheus + Jaeger, exemplar → trace)
```

## Stack

| | Version |
|---|---|
| Java | 25 |
| Spring Boot | 4.1.1 |
| Spring Cloud | 2025.1.3 (gateway server webmvc 5.0.3, verifier de compatibilité désactivé) |
| Namastack outbox | 1.9.0 (starter-jdbc, kafka, observability) |
| Kafka | apache/kafka 4.3.1 (KRaft) |

Licences middlewares : tout est Apache 2.0 sauf Postgres (PostgreSQL License) et **Grafana (AGPLv3, choix assumé : standard interne)**.

## Démarrage

```bash
docker compose -f infra/docker-compose.yml up -d
mvn -q package -DskipTests
scripts/run-apps.sh                      # lance les 3 applis en arrière-plan, logs dans ./logs
# options du projecteur passées en argument, ex :
# scripts/run-apps.sh --spring.kafka.listener.concurrency=6 --projector.sleep.max=200ms --projector.failure-rate=0.05
```

Réglages du projecteur : `projector.sleep.min/max` (50ms/1500ms), `projector.failure-rate` (0.0),
`spring.kafka.listener.concurrency` (1 : volontairement bas pour provoquer du lag).

| UI | URL |
|---|---|
| Grafana (dashboard « Cohérence CQRS ») | http://localhost:3000 |
| Jaeger | http://localhost:16686 |
| Prometheus | http://localhost:9090 |
| Kafka UI | http://localhost:8090 |

## API (via la gateway)

```bash
curl -X POST localhost:8080/orders -H 'Content-Type: application/json' -d '{"customerId":"c1","amount":42}'
curl -X PATCH localhost:8080/orders/{id}/status -H 'Content-Type: application/json' -d '{"status":"PAID"}'
curl localhost:8080/orders/{id}          # côté écriture (source de vérité)
curl localhost:8080/orders-view/{id}     # côté lecture (projection, avec last_version / projected_at)
curl -X POST "localhost:8080/orders/_bulk?count=5000"   # charge
```

Traces en ligne de commande : `node scripts/traces.mjs <service> [nbTraces] [minutes]` (`ATTRS=1` pour les attributs).
Arrêt des applis : `pwsh scripts/stop-apps.ps1`.

## Supervision de la cohérence à terme

Le délai écriture → lisibilité est décomposé en trois segments :

```
occurredAt ─[1. attente outbox]─► send Kafka ─[2. attente Kafka]─► poll ─[3. traitement]─► commit order_view
```

| Segment | Métrique |
|---|---|
| 1. outbox | `projection_outbox_wait_seconds` (timestamp record Kafka - occurredAt), `outbox_records{outbox_record_status="new"}`, `outbox_record_process_seconds` |
| 2. Kafka | `kafka_consumergroup_lag` (kafka-exporter, en messages), `projection_kafka_wait_seconds` (en temps) |
| 3. traitement | `spring_kafka_listener_*`, `projection_simulated_work_*` (+ spans SQL dans la trace) |
| **bout en bout (SLI)** | `projection_lag_seconds` (histogramme, exemplars → trace Jaeger) |

Clic sur un point d'exemplar du panneau « Lag de cohérence » dans Grafana → trace Jaeger de l'événement concerné.

Une seule trace couvre tout le chemin : `gateway → order-service → outbox schedule → outbox process → orders.events send → orders.events receive → projection`.
Namastack sérialise le contexte de trace dans l'enregistrement outbox et le restaure au traitement ;
l'observation `KafkaTemplate` / listener propage `traceparent` dans les en-têtes Kafka.

## Corrélation : retrouver ses billes

| Point de départ | Comment remonter le fil |
|---|---|
| Un client / le support a une réponse HTTP | en-tête `X-Trace-Id` renvoyé par la gateway → Jaeger, trace complète jusqu'à la projection |
| Un identifiant de commande | Jaeger → Search → Tags `order.id=<id>` : toutes les traces de la commande (création, changements de statut...) |
| Une ligne de log | chaque ligne porte `[appli,traceId,spanId,order.id=...]`, y compris dans le projecteur |
| La base côté écriture | `select status, context from outbox_record where record_key = '<orderId>'` : traceparent + baggage de chaque événement |
| La base côté lecture | `order_view.last_event_id` / `last_version` → événement correspondant dans Kafka |

Mécanique (pas de code métier instrumenté) :
- `order.id` est posé une fois en **baggage W3C** dans `OrderService` (`correlate(id)`), puis propagé par Boot / Namastack / Spring Kafka
  (en-tête `baggage` HTTP et Kafka, colonne `context` de l'outbox) ;
- `management.tracing.baggage.correlation.fields` le met dans le MDC des logs ;
- un `SpanProcessor` (`ObservabilityConfig`) le recopie en attribut de chaque span créé ensuite.
  Seuls les spans qui démarrent juste après une frontière asynchrone (`outbox process`, `orders.events process`) ne l'ont pas :
  le baggage est restauré juste après leur création. Sans impact sur la recherche Jaeger (un tag sur n'importe quel span suffit).

## SQL dans les traces

[datasource-micrometer](https://github.com/jdbc-observations/datasource-micrometer) (Apache 2.0) : chaque requête JDBC devient un span
`query` (attribut `jdbc.query[0]` = SQL, `jdbc.row-affected`), les acquisitions de connexion un span `connection` (attente du pool).
Aucun code : dépendance + `jdbc.includes` dans `application.yml`. Les valeurs des paramètres ne sont **pas** tracées
(`jdbc.datasource-proxy.include-parameter-values=false`, données personnelles) ; les requêtes hors trace (poll Namastack, Flyway)
sont filtrées pour ne pas créer de traces parasites.

## Scénarios de démonstration

| Scénario | Commande | Ce qu'on doit voir |
|---|---|---|
| Rafale | `curl -X POST "localhost:8080/orders/_bulk?count=2000"` | lag Kafka qui monte puis se résorbe ; décomposition dominée par « attente Kafka » |
| Projecteur arrêté | arrêter order-projector, écrire, relancer | lag en messages qui grimpe (kafka-exporter le voit même consommateur mort) |
| Kafka arrêté | `docker stop poc-kafka`, écrire, `docker start poc-kafka` | backlog outbox qui gonfle puis se vide, **aucune perte** |
| Poison / échecs | relancer avec `--projector.failure-rate=0.1` | tentatives en échec, puis messages en `orders.events.DLT` |
| Doublons | rejouer un message depuis Kafka UI | « doublons ignorés » incrémenté, vue inchangée |

## Pièges rencontrés (Boot 4.1 / Spring Kafka 4 / Namastack 1.9)

- Traces OTLP : `management.opentelemetry.tracing.export.otlp.endpoint` (l'ancien `management.otlp.tracing.*` est déprécié) ; le starter opentelemetry active l'export OTLP des métriques par défaut → désactivé (`management.otlp.metrics.export.enabled=false`) au profit du scrape Prometheus (exemplars).
- `DeadLetterPublishingRecoverer` publie par défaut vers `<topic>-dlt` (Spring Kafka 4) : resolver explicite vers `orders.events.DLT`.
- Namastack : `namastack.outbox.poll-interval`/`batch-size` dépréciés → `namastack.outbox.polling.fixed.interval` / `polling.batch-size`. Le module `observability` suffit à propager la trace (`namastack-outbox-tracing` est déprécié).
- Les ticks du scheduler Namastack et les scrapes `/actuator` génèrent des traces parasites → `ObservationPredicate` dans chaque appli.
- Spring Cloud 2025.1 cible Boot 4.0 : verifier de compatibilité désactivé dans la gateway.
- Git Bash : `docker exec` avec un chemin absolu (`/opt/kafka/...`) nécessite `MSYS_NO_PATHCONV=1`.
- Jaeger 2.21 : l'API HTTP v1 `/api/traces` n'existe plus, utiliser `/api/v3/traces` (cf. `scripts/traces.mjs`).
- Grafana sur Docker Desktop Windows : les nouveaux fichiers de dashboard ne sont pas vus à chaud → `docker restart poc-grafana`.

# Observabilité et exploitation

Ce document explique **comment voir ce qui se passe** dans la chaîne CQRS et **quoi faire** quand une alerte se
déclenche. Choix techniques : [ADR-0005](adr/0005-observabilite-opentelemetry.md).

- [Vue d'ensemble](#vue-densemble)
- [Le lag de cohérence](#le-lag-de-cohérence)
- [Traces](#traces)
- [Corrélation : retrouver une commande](#corrélation--retrouver-une-commande)
- [Métriques de référence](#métriques-de-référence)
- [Logs](#logs)
- [Runbook des alertes](#runbook)

## Vue d'ensemble

```
applis ──OTLP (traces)──► OTel Collector ──► Jaeger                 http://localhost:16686
   │                              └── span_metrics ──► Prometheus
   └──/actuator/prometheus◄── scrape ── Prometheus ◄── kafka-exporter   http://localhost:9090
                                           │  └─ alerts.yml (règles)
                                           ▼
                                        Grafana (métriques + traces, exemplar → trace)   http://localhost:3000
```

| Outil | Pour répondre à |
|---|---|
| Grafana, dashboard « Cohérence CQRS » | de combien les lectures sont-elles en retard ? où le temps est-il perdu ? |
| Jaeger | que s'est-il passé pour *cette* requête / *cette* commande ? |
| Prometheus → Alerts | qu'est-ce qui est anormal en ce moment ? |
| Kafka UI (http://localhost:8090) | que contient ce topic / la DLT ? où en est le groupe consommateur ? |

## Le lag de cohérence

Délai entre la décision métier (écriture chez le propriétaire) et le moment où la lecture la reflète :

```
occurredAt ──[1. outbox]──► envoi Kafka ──[2. Kafka]──► réception ──[3. traitement]──► commit order_view
```

| Segment | Métrique | Grandit quand… |
|---|---|---|
| 1. attente outbox | `projection_outbox_wait_seconds`, `outbox_records{outbox_record_status="new"}` | Kafka indisponible, publication trop lente, polling mal dimensionné |
| 2. attente Kafka | `projection_kafka_wait_seconds`, `kafka_consumergroup_lag` (messages) | consommateurs trop peu nombreux, arrêtés ou en erreur |
| 3. traitement | `spring_kafka_listener_seconds`, `app_code_seconds{code_layer}` | base de lecture lente, retries |
| **bout en bout (SLI)** | `projection_lag_seconds` (histogramme, exemplars) | somme des trois |

Le lag en **messages** (kafka-exporter) est mesuré depuis Kafka : il reste juste même quand le consommateur est
arrêté, contrairement aux métriques émises par le consommateur lui-même.

Côté client, `scripts/activity.sh` mesure le pourcentage de **lectures périmées** (projection pas encore à jour
après une écriture du même client).

## Traces

Une requête produit **une seule trace**, de la gateway jusqu'à la projection, y compris à travers l'outbox et Kafka :

```
[gateway] http post /orders/**
  [order-service] http post /orders
    CreateOrderService.create                              ← use case (span automatique)
      SpringUnitOfWork.inTransaction                       ← frontière de transaction
        JdbcOrderRepository.save → query (INSERT orders)   ← SQL (datasource-micrometer)
        OutboxOrderEventPublisher.publish → outbox schedule
          outbox process → orders.events send              ← publication asynchrone (≈100 ms plus tard)
            [order-projector] orders.events process
              ProjectOrderService.project
                JdbcOrderViewStore.saveIfNewer → query (INSERT … ON CONFLICT)
```

Mécanismes (aucune instrumentation dans le code métier) :

- **HTTP, Kafka** : observations Spring (`spring.kafka.*.observation-enabled`) ; `traceparent` propagé dans les
  en-têtes HTTP et Kafka.
- **Outbox** : Namastack stocke `traceparent` + `baggage` dans la colonne `context` de `outbox_record` et restaure le
  contexte à la publication.
- **Code applicatif** : le starter crée un span par méthode publique des packages `application` et `adapter.out`
  (`poc.observability.traced-code`), attributs `code.namespace`, `code.function`, `code.layer`.
- **SQL** : un span `query` par requête (`jdbc.query[0]`, `jdbc.row-affected`), un span `connection` par emprunt au
  pool. Pas de valeurs de paramètres.

Ligne de commande : `node scripts/traces.mjs <service> [nb] [minutes]` (`ATTRS=1` attributs, `OP=<opération>` filtre).

Échantillonnage : 100 % en local ; en production `TRACING_SAMPLING_PROBABILITY` (ex : 0.1). La décision est prise à
la racine (gateway) et respectée par tous les services en aval : une trace est complète ou absente.

## Corrélation : retrouver une commande

| Point de départ | Chemin |
|---|---|
| Une réponse HTTP | en-tête `X-Trace-Id` → Jaeger, recherche par Trace ID |
| Un identifiant de commande | Jaeger → Search → Tags `order.id=<id>` → toutes les traces de la commande |
| Une ligne de log | `traceId` et `order.id` présents sur chaque ligne (texte et JSON) |
| La base d'écriture | `select status, context from outbox_record where record_key = '<orderId>'` (traceparent de chaque événement ; conservé seulement si `OUTBOX_DELETE_COMPLETED=false`) |
| La base de lecture | `order_view.last_event_id`, `last_version` → message correspondant dans Kafka |
| Un pic sur un graphique | clic sur un point d'exemplar (panneau « Lag de cohérence ») → trace Jaeger |

`order.id` est un **baggage W3C** posé par l'adapter web (`infrastructure.observability.Correlation`). La gateway
supprime l'en-tête `baggage` des requêtes clientes : un client ne peut pas injecter de faux identifiants.

Pour ajouter une clé de corrélation (ex : `tenant.id`) : la déclarer dans `management.tracing.baggage.remote-fields`,
`tag-fields` et `correlation.fields`, puis la poser à l'entrée comme `order.id`.

## Métriques de référence

| Métrique | Type | Tags | Émise par |
|---|---|---|---|
| `projection_lag_seconds` | histogramme | `eventType`, `outcome` | projecteur |
| `projection_outbox_wait_seconds`, `projection_kafka_wait_seconds` | histogramme | `eventType` | projecteur |
| `projection_events_total` | compteur | `eventType`, `outcome` = applied / skipped / failed | projecteur |
| `projection_dlt_total` | compteur | `eventType` | projecteur |
| `outbox_records` | jauge | `outbox_record_status` = new / completed / failed | service propriétaire (Namastack) |
| `outbox_record_process_seconds` | timer | `outbox_handler_id`, `error` | service propriétaire (Namastack) |
| `kafka_consumergroup_lag` | jauge | `consumergroup`, `topic`, `partition` | kafka-exporter |
| `app_code_seconds` | timer | `code_namespace`, `code_function`, `code_layer` | starter (toutes applis) |
| `http_server_requests_seconds` | histogramme | `uri`, `method`, `status` | toutes applis |
| `traces_span_metrics_*` | RED dérivées des traces | `service_name`, `span_name` | OTel Collector |

Toutes les métriques d'application portent le tag `application`.

## Logs

- **Local** : texte, avec `[application,traceId,spanId,order.id=…]` sur chaque ligne.
- **Production** : `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs` → JSON (Elastic Common Schema) sur la sortie standard,
  avec `traceId`, `spanId` et les champs de baggage ; à collecter par l'agent de logs de la plateforme.
- Pas de donnée personnelle dans les logs INFO (identifiants techniques uniquement).

## Runbook

Règles : [`infra/prometheus/alerts.yml`](../infra/prometheus/alerts.yml). Seuils de départ, à ajuster aux SLO.

### ProjectionLagHigh

*Le p95 du lag de cohérence dépasse 5 s.* Les utilisateurs peuvent lire des données périmées.

1. Dashboard, panneau « Décomposition du lag » : quel segment domine ?
2. **Outbox** → voir [OutboxBacklog](#outboxbacklog). **Kafka** → voir [ConsumerLagGrowing](#consumerlaggrowing).
   **Traitement** → Jaeger sur `order-projector`, trier par durée : base de lecture lente (spans `query`) ou retries.
3. Cliquer un exemplar sur le pic pour ouvrir une trace représentative.

### ConsumerLagGrowing

*Plus de 1000 messages en attente pour un groupe consommateur.*

1. Le projecteur tourne-t-il ? (`up{job="spring-apps"}`, `/actuator/health/readiness`).
2. Consomme-t-il ? `rate(projection_events_total[1m])` > 0. Sinon : logs d'erreur, DLT, base de lecture.
3. Consomme-t-il assez vite ? Comparer « publiés » et « projetés » (panneau Débit). Augmenter
   `PROJECTOR_CONCURRENCY` (plafond : nombre de partitions) ou le nombre d'instances.
4. Lag sur une seule partition : agrégat très actif ou message lent sur cette partition (ordre par clé).

### OutboxBacklog

*Plus de 500 événements écrits mais non publiés.* Les écritures ne sont plus propagées ; aucune donnée n'est perdue.

1. Kafka joignable depuis le service ? (logs `org.apache.kafka`, Kafka UI).
2. `outbox_record_process_seconds{error!="none"}` : erreurs de publication ?
3. Instance(s) du service arrêtée(s) : les partitions Namastack sont réattribuées après
   `stale-instance-timeout` ; le backlog se vide au redémarrage.

### OutboxRecordsFailed

*Des événements ont épuisé leurs tentatives de publication.* Ils ne partiront pas seuls : la projection diverge.

1. `select id, record_key, failure_count, failure_reason from outbox_record where status = 'FAILED'`.
2. Corriger la cause (topic absent, sérialisation, droits Kafka).
3. Republier : `update outbox_record set status = 'NEW', failure_count = 0, next_retry_at = now() where status = 'FAILED'`
   (l'ordre par agrégat est préservé : Namastack traite les clés dans l'ordre de création).

### DeadLetterMessages

*Des événements n'ont pas pu être projetés et sont dans `orders.events.DLT`.* La vue de lecture est incomplète pour
ces commandes.

1. Kafka UI → topic `orders.events.DLT` : en-têtes `kafka_dlt-exception-message`, `kafka_dlt-original-offset`,
   `traceparent` (→ Jaeger).
2. Cause **message invalide** (JSON, `schemaVersion` inconnu) : problème de contrat → corriger le producteur ou
   déployer un consommateur compatible.
3. Cause **technique** (base indisponible au-delà des retries) : une fois corrigée, rejouer la DLT vers
   `orders.events` (Kafka UI → copier les messages, ou petit outil de rejeu) ; l'upsert idempotent rend le rejeu sûr.

### ServiceDown

*Prometheus n'arrive plus à scraper une application.* Vérifier le processus / pod, `/actuator/health/liveness`,
les logs de démarrage (base ou Kafka injoignable, migration Flyway en échec).

### HttpErrorRateHigh

*Plus de 5 % de réponses 5xx.* Jaeger : filtrer `error=true` sur le service ; les spans de couche indiquent où
l'exception naît (use case, repository, outbox). Les 4xx (validation, 404, 409) ne comptent pas : ce sont des
erreurs client attendues.

## Reconstruire une projection

La projection est jetable : elle se reconstruit depuis Kafka grâce à l'upsert idempotent.

```bash
# 1. arrêter le projecteur ; 2. (optionnel) vider la vue
docker exec poc-postgres psql -U poc -d orders_read -c "truncate order_view"
# 3. repositionner le groupe au début du topic
MSYS_NO_PATHCONV=1 docker exec poc-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-projector --topic orders.events --reset-offsets --to-earliest --execute
# 4. relancer le projecteur : il rejoue tout l'historique disponible
```

Limite : on ne rejoue que ce que la **rétention** du topic conserve. Pour une reconstruction complète garantie :
rétention illimitée, topic compacté par clé (l'état complet de chaque commande est dans son dernier événement), ou
ré-émission depuis le service propriétaire.

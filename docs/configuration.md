# Configuration

Convention **12-factor** : tout ce qui varie d'un environnement à l'autre est une variable d'environnement, avec une
valeur par défaut qui fonctionne sur le poste de dev (`infra/docker-compose.yml`). Les secrets (`*_PASSWORD`) sont
injectés par la plateforme, jamais commités.

Ordre de priorité (du plus fort au plus faible) : arguments `--prop=…` > variables d'environnement >
`application.yml` du service > défauts du starter (`observability-defaults.properties`).
Toute propriété Spring est aussi surchargeable par sa forme variable d'environnement (binding relâché) :
`namastack.outbox.retry.max-retries` → `NAMASTACK_OUTBOX_RETRY_MAXRETRIES`.

## Communes (observability-starter)

| Variable | Défaut | Rôle |
|---|---|---|
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | `http://localhost:4318/v1/traces` | collecteur OTLP (HTTP) |
| `TRACING_SAMPLING_PROBABILITY` | `1.0` | part des traces conservées (prod : 0.05 à 0.2) |
| `DEPLOYMENT_ENVIRONMENT` | `local` | attribut `deployment.environment.name` des traces |
| `ACTUATOR_ENDPOINTS` | `health,info,prometheus` | endpoints actuator exposés |
| `ACTUATOR_HEALTH_DETAILS` | `never` | détail de `/actuator/health` |
| `SHUTDOWN_TIMEOUT` | `30s` | durée max de l'arrêt propre |
| `LOGGING_STRUCTURED_FORMAT_CONSOLE` | *(texte)* | `ecs` : logs JSON (production) |
| `SERVER_PORT` | 8080 / 8081 / 8082 | port HTTP |

## gateway

| Variable | Défaut | Rôle |
|---|---|---|
| `ORDER_SERVICE_URL` | `http://localhost:8081` | côté écriture |
| `ORDER_PROJECTOR_URL` | `http://localhost:8082` | côté lecture |
| `GATEWAY_CONNECT_TIMEOUT` | `2s` | connexion aux services en aval |
| `GATEWAY_READ_TIMEOUT` | `10s` | attente de réponse des services en aval |

## order-service

| Variable / propriété | Défaut | Rôle |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/orders_write` | base d'écriture |
| `DB_USERNAME` / `DB_PASSWORD` | `poc` / `poc` | compte applicatif |
| `DB_POOL_MAX_SIZE` | `20` | pool Hikari (taille fixe) |
| `DB_MIGRATION_USERNAME` / `DB_MIGRATION_PASSWORD` | compte applicatif | compte Flyway (droits DDL) |
| `KAFKA_BOOTSTRAP_SERVERS` | `localhost:9092` | brokers Kafka |
| `OUTBOX_DELETE_COMPLETED` | `true` | purge des enregistrements publiés ; `false` en local pour garder le lien base → trace |
| `LOAD_TEST_ENABLED` | `false` | expose `POST /orders/_bulk` (jamais en production) |
| `order.load-test.max-count` / `parallelism` | `100000` / `8` | bornes du générateur de charge |

Réglages de l'outbox (dans `application.yml`, commentés) : polling 100 ms / lots de 100, retries exponentiels
2 s → 1 min × 10, `stop-on-first-failure`, heartbeat 5 s, instance morte après 30 s, rééquilibrage 10 s.

## order-projector

| Variable / propriété | Défaut | Rôle |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/orders_read` | base de lecture |
| `DB_USERNAME` / `DB_PASSWORD` | `poc` / `poc` | compte applicatif |
| `DB_POOL_MAX_SIZE` | `10` | pool Hikari (≥ concurrence + marge pour l'API) |
| `KAFKA_BOOTSTRAP_SERVERS` | `localhost:9092` | brokers Kafka |
| `PROJECTOR_CONCURRENCY` | `6` | consommateurs parallèles (plafond utile : nombre de partitions) |
| `projector.retry.max-attempts` | `5` | tentatives avant DLT (première incluse) |
| `projector.retry.initial-interval` / `multiplier` / `max-interval` | `500ms` / `2.0` / `5s` | backoff exponentiel |

## Exemple : lancement conteneurisé

Le profil Compose `apps` lance les trois applications à partir du `Dockerfile` racine, configurées uniquement par
variables d'environnement :

```bash
docker compose -f infra/docker-compose.yml --profile apps up -d --build
```

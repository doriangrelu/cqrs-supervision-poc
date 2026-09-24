# Checklist de mise en production

Ce que la base technique apporte déjà (✅), et ce qui dépend de chaque projet ou de la plateforme cible (⬜).
À reprendre pour chaque nouveau service.

## Configuration et déploiement

- ✅ Configuration 12-factor : toute valeur dépendant de l'environnement est une variable d'environnement avec un
  défaut local ([configuration.md](configuration.md)).
- ✅ Image Docker multi-étapes, jar en couches, utilisateur non root, mémoire JVM relative au conteneur
  (`Dockerfile`, `docker compose --profile apps`).
- ✅ Sondes Kubernetes : `/actuator/health/liveness`, `/actuator/health/readiness` (base incluse).
- ✅ Arrêt propre (`server.shutdown=graceful`, `SHUTDOWN_TIMEOUT`) : requêtes et messages en cours terminés.
- ⬜ Manifestes de déploiement (Helm / Kustomize) : ressources CPU/mémoire, sondes, variables, secrets.
- ⬜ Secrets (`DB_PASSWORD`…) depuis le coffre de la plateforme (Vault, Kubernetes Secrets, Secret Manager),
  jamais dans le dépôt.
- ⬜ Publication des artefacts partagés (`observability-starter`, `event-contract`) sur le dépôt Maven interne,
  versionnés indépendamment des services.

## Sécurité

- ✅ Actuator restreint à `health`, `info`, `prometheus` ; pas de détails de santé ni de stacktrace exposés.
- ✅ Erreurs HTTP au format RFC 9457 sans détail interne.
- ✅ La gateway ignore l'en-tête `baggage` des clients (pas d'usurpation des champs de corrélation).
- ✅ Pas de valeurs de paramètres SQL ni de donnée personnelle dans les traces et logs INFO.
- ⬜ Authentification / autorisation : OAuth2 / OIDC à la gateway (`spring-boot-starter-oauth2-resource-server`),
  propagation du jeton ou d'une identité de service vers l'aval.
- ⬜ TLS partout (entrée, Kafka `SASL_SSL`, Postgres `sslmode=verify-full`), ou mTLS par le service mesh.
- ⬜ ACL Kafka : le producteur écrit seul sur `orders.events`, chaque consommateur lit avec son groupe.
- ⬜ Port de management séparé (`MANAGEMENT_SERVER_PORT`) non exposé publiquement.
- ⬜ Analyse des dépendances (OWASP Dependency-Check, Dependabot / Renovate) et des images (Trivy).

## Données et messaging

- ✅ Schéma entièrement géré par Flyway (tables métier et outbox) ; l'application n'a pas besoin des droits DDL.
- ✅ Outbox : aucune perte si Kafka est indisponible ; enregistrements publiés purgés (`OUTBOX_DELETE_COMPLETED`).
- ✅ Producteur Kafka `acks=all`, idempotent ; ordre garanti par agrégat (clé = id).
- ✅ Consommateur idempotent (upsert conditionnel sur la version), retries à backoff exponentiel, DLT, erreurs non
  rejouables envoyées directement en DLT.
- ✅ Contrat d'événements versionné (`schemaVersion`) avec règles d'évolution documentées.
- ⬜ Topics : facteur de réplication 3, `min.insync.replicas=2`, rétention adaptée au besoin de reconstruction
  (voir [observability.md](observability.md#reconstruire-une-projection)), création par l'outil d'infra (pas par
  les applications).
- ⬜ Nombre de partitions dimensionné sur le parallélisme cible des consommateurs (non modifiable sans casser
  l'ordre par clé).
- ⬜ Procédure de rejeu de la DLT outillée.
- ⬜ Sauvegardes et PRA des bases ; la base de lecture peut se reconstruire depuis Kafka.
- ⬜ Idempotence des créations côté API (clé d'idempotence client) si les clients rejouent leurs requêtes.

## Observabilité

- ✅ Traces de bout en bout, SQL, spans par couche, corrélation `order.id`, `X-Trace-Id` renvoyé aux clients.
- ✅ Métriques de cohérence, dashboard Grafana, règles d'alerte + runbook ([observability.md](observability.md#runbook)).
- ✅ Logs JSON (ECS) activables par variable, corrélés aux traces.
- ⬜ Échantillonnage de production (`TRACING_SAMPLING_PROBABILITY`, ex : 0.1) et stockage Jaeger persistant
  (Elasticsearch / OpenSearch / Cassandra) avec rétention.
- ⬜ Alertmanager (routage des alertes vers l'astreinte) ; SLO métier validés pour les seuils.
- ⬜ Collecte des logs (agent de la plateforme) vers le backend de logs de l'entreprise.

## Qualité

- ✅ Tests de domaine rapides, règles d'architecture vérifiées à chaque build (ArchUnit).
- ⬜ Tests d'intégration Testcontainers (Postgres + Kafka) sur les adapters et le parcours outbox → projection.
- ⬜ Tests de contrat entre producteur et consommateurs (ex : jeux d'exemples JSON versionnés dans `event-contract`).
- ⬜ Tests de charge (Gatling, Apache 2.0) sur les parcours critiques, avec objectifs de lag.
- ⬜ Pipeline CI : build, tests, analyse, image signée, déploiement progressif.

## Points de vigilance de cette base

- Spring Cloud 2025.1 est prévu pour Boot 4.0 et le projet est en Boot 4.1 (imposé par Namastack 1.9) : le
  vérificateur de compatibilité est désactivé dans la gateway. À réactiver dès le prochain train Spring Cloud.
- Namastack Outbox est une bibliothèque jeune : suivre les versions, tester les montées de version sur la reprise
  multi-instances.

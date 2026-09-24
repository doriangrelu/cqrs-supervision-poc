# ADR-0005 — Observabilité : OpenTelemetry, Prometheus, Jaeger, Grafana ; starter commun

- **Statut** : accepté
- **Date** : 2026-09-24

## Contexte

La cohérence à terme ne doit pas rendre l'équipe aveugle : il faut savoir **de combien** les lectures sont en retard,
**où** le temps est perdu (outbox, Kafka, traitement) et **suivre une commande** de bout en bout. Contrainte :
middlewares sous licence Apache 2.0.

## Décision

| Besoin | Choix | Licence |
|---|---|---|
| Instrumentation | Micrometer Observation + pont OpenTelemetry (`spring-boot-starter-opentelemetry`) | Apache 2.0 |
| Collecte des traces | OpenTelemetry Collector → Jaeger v2 | Apache 2.0 |
| Métriques | Prometheus, scrape `/actuator/prometheus` (OpenMetrics, exemplars) | Apache 2.0 |
| Lag Kafka indépendant des consommateurs | kafka-exporter | Apache 2.0 |
| SQL dans les traces | datasource-micrometer | Apache 2.0 |
| Tableaux de bord | **Grafana — AGPLv3**, exception assumée : standard de l'entreprise, utilisé sans modification | AGPLv3 |

Métriques en **scrape** plutôt qu'en push OTLP : seul moyen fiable d'obtenir les *exemplars* (lien d'un point de
métrique vers la trace correspondante) avec Micrometer.

Toute la plomberie est dans le module **`observability-starter`** (auto-configuration Spring Boot) :
valeurs par défaut d'exploitation, spans automatiques par couche (pointcut AspectJ sur `application` et
`adapter.out`), recopie du baggage en attributs de span, filtrage du bruit (actuator, polling, SQL hors trace).

Corrélation métier : baggage W3C `order.id`, posé une fois à l'entrée, propagé par HTTP, outbox et Kafka ; présent
dans les logs (MDC) et comme attribut de span. La gateway ignore le baggage envoyé par les clients (anti-usurpation).

## Conséquences

- ➕ Un service rejoint l'écosystème par une dépendance Maven et quelques propriétés.
- ➕ Lag de cohérence décomposé et alertable ; une trace unique de la requête HTTP jusqu'à la projection.
- ➖ Le starter est un composant partagé : il se versionne et se publie (dépôt Maven interne) ; toute évolution
  s'évalue sur l'ensemble des services.
- ➖ Échantillonnage à ajuster en production (`TRACING_SAMPLING_PROBABILITY`) : les métriques restent exhaustives,
  les traces non.
- ➖ Grafana AGPLv3 : à réévaluer si l'outil devait être modifié ou redistribué (alternative Apache 2.0 : Perses).

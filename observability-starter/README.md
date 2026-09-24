# observability-starter

Auto-configuration Spring Boot commune à tous les services : un service rejoint l'écosystème d'observabilité et
d'exploitation par **une dépendance Maven**. Décision : [ADR-0005](../docs/adr/0005-observabilite-opentelemetry.md).

```xml
<dependency>
    <groupId>poc.exploit</groupId>
    <artifactId>observability-starter</artifactId>
</dependency>
```

Apporte transitivement : `spring-boot-starter-actuator`, `spring-boot-starter-opentelemetry`,
`micrometer-registry-prometheus`, `spring-boot-starter-aspectj`.

## Ce qu'il fait

| Fonction | Classe | Désactivation / réglage |
|---|---|---|
| Valeurs par défaut d'exploitation (tracing OTLP, actuator, sondes, arrêt propre, ProblemDetail, SQL tracé sans paramètres) | `ObservabilityDefaultsPostProcessor` + `META-INF/poc/observability-defaults.properties` | toute propriété redéfinie par le service ou l'environnement l'emporte |
| Un span par méthode publique des couches `application` et `infrastructure.adapter.out` | `TracedCodeInterceptor` | `poc.observability.traced-code-enabled=false`, pointcut `poc.observability.traced-code` |
| Recopie des champs de baggage (`management.tracing.baggage.tag-fields`) en attributs de chaque span | `baggageToSpanAttributes` | vider `tag-fields` |
| Pas de trace pour `/actuator` | `WebNoiseFilter` | — |
| Pas de span SQL hors trace (polling, migrations) | `JdbcNoiseFilter` (si datasource-micrometer présent) | — |
| Pas de trace par tick du scheduler Namastack | `OutboxNoiseFilter` (si Namastack présent) | — |

## Variables d'environnement reconnues

| Variable | Défaut | Rôle |
|---|---|---|
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | `http://localhost:4318/v1/traces` | collecteur OTLP (HTTP) |
| `TRACING_SAMPLING_PROBABILITY` | `1.0` | part des traces conservées (prod : 0.05–0.2) |
| `DEPLOYMENT_ENVIRONMENT` | `local` | attribut de ressource `deployment.environment.name` |
| `ACTUATOR_ENDPOINTS` | `health,info,prometheus` | endpoints actuator exposés |
| `ACTUATOR_HEALTH_DETAILS` | `never` | détails de `/actuator/health` |
| `SHUTDOWN_TIMEOUT` | `30s` | délai d'arrêt propre |
| `LOGGING_STRUCTURED_FORMAT_CONSOLE` | *(texte)* | `ecs` → logs JSON (propriété Spring Boot standard) |

## Faire évoluer le starter

Composant partagé : le versionner et le publier sur le dépôt Maven interne ; toute évolution se juge sur l'ensemble
des services. Y mettre uniquement du **transverse technique** (jamais de code métier, jamais de clé de corrélation
propre à un domaine : celles-ci se déclarent dans chaque service).

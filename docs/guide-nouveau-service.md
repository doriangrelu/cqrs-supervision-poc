# Décliner la base technique dans un nouveau service

Ce guide décrit comment créer un service **propriétaire de données** (comme `order-service`) ou un **projecteur**
(comme `order-projector`) qui respecte les conventions de cette base. Lire d'abord
[architecture.md](architecture.md).

## 1. Choisir le type de service

| Vous créez… | Modèle à copier | Il possède | Il publie / consomme |
|---|---|---|---|
| un service métier propriétaire d'un agrégat | `order-service` | sa base (source de vérité) + tables outbox | publie ses événements via l'outbox |
| un modèle de lecture (vue, recherche, agrégation) | `order-projector` | une base de lecture jetable | consomme les événements d'un ou plusieurs propriétaires |

Un même service peut être les deux (il possède un agrégat et projette les événements d'un autre contexte).

## 2. Squelette Maven

```xml
<dependencies>
    <!-- observabilité, actuator, valeurs par défaut d'exploitation : obligatoire -->
    <dependency>
        <groupId>poc.exploit</groupId>
        <artifactId>observability-starter</artifactId>
    </dependency>
    <!-- SQL dans les traces -->
    <dependency>
        <groupId>net.ttddyy.observation</groupId>
        <artifactId>datasource-micrometer-spring-boot</artifactId>
    </dependency>
    <!-- contrat(s) d'événements publiés ou consommés -->
    <dependency>
        <groupId>poc.exploit</groupId>
        <artifactId>event-contract</artifactId>
    </dependency>
    <!-- + spring-boot-starter-webmvc / -jdbc / -flyway / -kafka / -validation selon besoin -->
    <!-- propriétaire : io.namastack:namastack-outbox-starter-jdbc, -kafka, -observability -->
    <!-- tests : spring-boot-starter-test, com.tngtech.archunit:archunit-junit5 -->
</dependencies>
```

Dans un autre dépôt, remplacer le parent `poc-exploit-parent` par le parent Spring Boot et importer les BOM
(Spring Cloud si besoin, `namastack-outbox-bom`), plus les versions publiées du starter et des contrats.

## 3. Arborescence

Reprendre exactement le découpage de [architecture.md § Organisation du code](architecture.md#organisation-du-code),
avec `poc.exploit.<contexte>` comme racine. Le starter trace automatiquement toute méthode publique des packages
`..application..` et `..infrastructure.adapter.out..` : **ne pas renommer ces segments**, sinon adapter
`poc.observability.traced-code`.

Copier `ArchitectureTest` et ses `package-info.java` : les règles de dépendance sont vérifiées à chaque build.

## 4. Écrire le métier (de l'intérieur vers l'extérieur)

1. **Domaine** (`domain/model`, `domain/event`, `domain/exception`) : agrégat avec ses invariants et transitions,
   qui enregistre ses événements de domaine et incrémente sa version. Tests unitaires sans Spring.
2. **Ports** : `port/in/usecase` (ce que le service offre), `port/in/command` (entrées), `port/out/…` (ce dont il a
   besoin : persistance, publication, `UnitOfWork`).
3. **Services applicatifs** (`application/service`) : orchestrent domaine et ports, en Java pur ; la transaction
   passe par `unitOfWork.inTransaction(...)`.
4. **Adapters** : REST (DTO validés par Bean Validation, erreurs ProblemDetail), JDBC, publication outbox avec
   traduction événement de domaine → événement d'intégration, listener Kafka mince.
5. **Câblage** (`infrastructure/config`) : `@Bean` des services applicatifs, `Clock`.

## 5. Publier des événements (service propriétaire)

- Définir l'événement d'intégration dans un module contrat (un par contexte métier) : enveloppe
  `eventId`, `schemaVersion`, `eventType`, `aggregateId`, `aggregateVersion`, `occurredAt`, état complet.
- Écrire l'agrégat et appeler `outbox.schedule(event, aggregateId)` **dans la même transaction**.
- Router vers le topic avec la clé = `aggregateId` (bean `KafkaOutboxRouting`).
- Ajouter la migration Flyway des tables Namastack (copie de `V2__namastack_outbox.sql`) et laisser
  `namastack.outbox.jdbc.schema-initialization.enabled=false`.

## 6. Consommer des événements (projecteur)

- Listener : conversion JSON → événement du contrat, validation (champs, `schemaVersion` supporté), mapping vers
  une command, appel du use case, métriques. Rien d'autre.
- Écriture idempotente : upsert conditionnel sur `aggregateVersion`.
- Copier `KafkaConfig` : convertisseur, retries exponentiels, DLT, classification des erreurs non rejouables.
- Réutiliser `ProjectionMetrics` (mêmes noms de métriques = dashboard et alertes réutilisables, filtrés par
  `application`).

## 7. Corrélation

Choisir la clé métier qui permet de « retrouver ses billes » (ex : `invoice.id`) :

```yaml
management:
  tracing:
    baggage:
      remote-fields: invoice.id
      tag-fields: invoice.id
      correlation:
        fields: invoice.id
logging:
  pattern:
    correlation: "[${spring.application.name:},%X{traceId:-},%X{spanId:-},invoice.id=%X{invoice.id:-}] "
```

et la poser à l'entrée (adapter web) comme `Correlation.withOrderId(...)`. Elle sera propagée automatiquement par
HTTP, l'outbox et Kafka, et recopiée sur chaque span par le starter.

## 8. Configuration

- Uniquement le spécifique au service dans `application.yml` ; le commun vient du starter
  (`META-INF/poc/observability-defaults.properties`).
- Toute valeur d'environnement en variable : `${DB_URL:jdbc:postgresql://localhost:5432/<base>}`.
- Documenter les variables du service dans [configuration.md](configuration.md).

## 9. Exploitation

- Ajouter le service au scrape Prometheus (en Kubernetes : annotation / `ServiceMonitor`).
- Dupliquer les alertes pertinentes de `infra/prometheus/alerts.yml` (lag, outbox, DLT) pour ses topics / groupes.
- Compléter le runbook ([observability.md](observability.md#runbook)).
- Dérouler la [checklist de production](production-checklist.md).

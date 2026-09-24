# ADR-0004 — Clean architecture (hexagonale) dans chaque service

- **Statut** : accepté
- **Date** : 2026-09-24

## Contexte

Les services doivent pouvoir évoluer (changement de base, de broker, d'API) sans réécrire le métier, et servir de
modèle à d'autres équipes. Le métier doit être testable sans infrastructure.

## Décision

Chaque service suit le même découpage (détail dans [architecture.md](../architecture.md#organisation-du-code)) :

- `domain` : Java pur. Agrégats, value objects, événements et exceptions de domaine. Aucune dépendance technique.
- `application` : use cases (`port.in`), besoins envers l'extérieur (`port.out`), implémentations (`service`)
  en Java pur, **sans annotation Spring** ; la transaction est un port (`UnitOfWork`).
- `infrastructure` : adapters entrants (REST, Kafka), adapters sortants (JDBC, outbox), câblage Spring (`config`),
  observabilité.

Règles vérifiées à chaque build par ArchUnit (`ArchitectureTest`) : dépendances vers l'intérieur uniquement ; domaine
et application indépendants de Spring, Kafka, Jakarta et du contrat d'intégration ; adapters indépendants entre eux ;
adapters entrants limités aux ports `in`.

Choix pragmatiques assumés :

- pas de mapping systématique entre couches quand il n'apporte rien (les use cases renvoient l'agrégat, l'adapter web
  le convertit en DTO) ;
- les invariants sont dans le domaine, la validation de forme (Bean Validation) dans l'adapter web ;
- identifiants générés par l'appelant (`OrderId.generate()` dans l'adapter) : ils permettent la corrélation dès
  l'entrée de la requête et, à terme, l'idempotence des créations.

## Conséquences

- ➕ Métier testable unitairement, en millisecondes (tests de domaine sans Spring).
- ➕ Couches lisibles dans les traces : le starter d'observabilité trace automatiquement `application` et
  `adapter.out` (cf. [ADR-0005](0005-observabilite-opentelemetry.md)).
- ➖ Plus de classes qu'un service « controller → repository » ; justifié pour des services au métier non trivial,
  à alléger pour un service purement CRUD.

# ADR-0001 — CQRS par projections, sans event store

- **Statut** : accepté
- **Date** : 2026-09-24

## Contexte

Le produit attend une forte volumétrie en lecture ; les bases relationnelles des services propriétaires ne tiendront
pas la charge si elles servent aussi toutes les lectures. Il faut séparer lecture et écriture.

Deux familles de solutions :

1. **Event sourcing** (event store, ex : Axon, EventStoreDB) : l'état est reconstruit à partir du journal d'événements,
   qui devient la source de vérité.
2. **État + événements** : chaque service stocke son état courant dans sa base (source de vérité) et publie des
   événements métier ; des projecteurs construisent des modèles de lecture dédiés.

## Décision

Option 2. **Le service qui stocke la donnée en est propriétaire et fait autorité.** Les événements sont une
*notification de changement d'état*, pas la source de vérité. Les lectures massives sont servies par des projections
(`order-projector`) alimentées par Kafka.

## Conséquences

- ➕ Modèle mental simple (CRUD + événements), pas de framework d'event sourcing, pas de reconstruction d'état
  par rejeu, pas de migration de journal d'événements.
- ➕ Chaque modèle de lecture est optimisé pour ses requêtes et peut être jeté et reconstruit (rejeu Kafka).
- ➖ **Cohérence à terme** entre écriture et lecture : il faut la mesurer et la superviser (cf. [ADR-0005](0005-observabilite-opentelemetry.md)).
- ➖ Pas d'historique complet « gratuit » : l'historique dépend de la rétention des topics Kafka. Un besoin d'audit
  complet se traite par un consommateur dédié qui archive les événements.
- ➖ Le problème de la double écriture (base + Kafka) doit être résolu : cf. [ADR-0002](0002-transactional-outbox-namastack.md).

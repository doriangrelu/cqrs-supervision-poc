# ADR-0003 — Événements porteurs d'état et projections idempotentes

- **Statut** : accepté
- **Date** : 2026-09-24

## Contexte

Un projecteur peut recevoir un événement en double (outbox *at-least-once*, rejeu) ou, en cas de rejeu partiel,
un événement plus ancien que l'état déjà projeté. Il ne doit pas avoir à rappeler le service propriétaire.

## Décision

- **Event-carried state transfer** : chaque événement porte l'**état complet** de l'agrégat après le changement
  (`OrderPayload`), plus `aggregateVersion` (monotone) et `eventId`.
- **Projection = upsert conditionnel** sur la version :
  `INSERT … ON CONFLICT (order_id) DO UPDATE … WHERE order_view.last_version < EXCLUDED.last_version`.
  La règle est nommée dans le domaine du projecteur (`OrderView.isNewerThan`) mais **appliquée par la base**, seule
  à garantir l'atomicité avec plusieurs consommateurs concurrents.
- Distinction **événement de domaine** (interne, langage du domaine : `OrderCreated`, `OrderStatusChanged`) /
  **événement d'intégration** (contrat public versionné : `OrderEvent`, module `event-contract`). La traduction est
  faite par l'adapter de publication : le domaine peut évoluer sans casser les consommateurs.
- Contrat versionné (`schemaVersion`) avec règles d'évolution additive (Javadoc de `OrderEvent`).

## Conséquences

- ➕ Doublons et événements obsolètes sans effet (`outcome=skipped` dans les métriques).
- ➕ Projection reconstructible à tout moment : reset des offsets du groupe consommateur + rejeu.
- ➕ L'ordre n'est nécessaire que par agrégat (clé Kafka = id) : parallélisme = nombre de partitions.
- ➖ Messages plus volumineux qu'un simple delta.
- ➖ Le contrat expose l'état : son évolution se gouverne (revue des changements du module `event-contract`).

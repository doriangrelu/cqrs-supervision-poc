# ADR-0002 — Publication des événements par transactional outbox (Namastack)

- **Statut** : accepté
- **Date** : 2026-09-24

## Contexte

Écrire en base puis publier sur Kafka sont deux opérations non atomiques. Un arrêt entre les deux (crash, déploiement,
Kafka indisponible) fait perdre l'événement **silencieusement** : la projection diverge sans qu'aucune métrique de lag
ne le détecte.

Alternatives étudiées :

| Option | Écartée parce que |
|---|---|
| Envoi Kafka direct après commit | perte possible, non détectable |
| Transaction XA / Kafka transactions + DB | complexe, couplage fort, pas de vraie atomicité DB ↔ Kafka |
| CDC Debezium sur la table outbox | robuste mais infrastructure supplémentaire (Kafka Connect) à opérer |
| **Outbox applicative (Namastack)** | ✅ retenue |

## Décision

L'agrégat et l'enregistrement d'outbox sont écrits **dans la même transaction** (`UnitOfWork`). Un scheduler
[Namastack Outbox](https://www.namastack.io/outbox/) publie ensuite les enregistrements sur Kafka.

- clé d'outbox = identifiant de l'agrégat → **ordre garanti par agrégat** (et clé Kafka identique) ;
- livraison **au moins une fois** → les consommateurs sont idempotents (cf. [ADR-0003](0003-event-carried-state-transfer.md)) ;
- schéma des tables outbox géré par Flyway (en production l'application n'a pas les droits DDL) ;
- enregistrements publiés supprimés en production (`OUTBOX_DELETE_COMPLETED=true`), conservés en local pour
  remonter d'une ligne de base à sa trace ;
- le contexte de trace (`traceparent` + `baggage`) est stocké dans l'enregistrement et restauré à la publication :
  la trace est continue à travers la frontière asynchrone.

## Conséquences

- ➕ Aucune perte : si Kafka est indisponible, l'outbox grossit puis se vide au retour (testé).
- ➕ Pas d'infrastructure supplémentaire, bibliothèque Apache 2.0 intégrée à Spring Boot.
- ➖ Latence ajoutée (intervalle de polling, 100 ms par défaut) : visible dans la métrique `projection.outbox.wait`.
- ➖ Charge de polling sur la base du service ; à dimensionner (batch, intervalle) et superviser (`outbox_records`).
- ➖ Doublons possibles (reprise après crash) : l'idempotence des consommateurs est obligatoire.

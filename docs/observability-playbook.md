# Cadrer l'observabilité d'un nouveau projet

Ce document capitalise les choix faits dans ce POC ([ADR-0005](adr/0005-observabilite-opentelemetry.md),
[observability.md](observability.md)) sous forme de cadre **réutilisable**, indépendant de la stack CQRS/Kafka, pour
démarrer l'observabilité d'un futur projet dès le premier commit plutôt que de la rattraper en production.

- [1. Les questions à se poser avant de choisir un outil](#1-les-questions-à-se-poser-avant-de-choisir-un-outil)
- [2. Le modèle en couches](#2-le-modèle-en-couches)
- [3. Push vs pull : ce n'est pas un détail](#3-push-vs-pull--ce-nest-pas-un-détail)
- [4. Une seule clé de corrélation métier, posée une fois](#4-une-seule-clé-de-corrélation-métier-posée-une-fois)
- [5. Un starter partagé : quoi y mettre, quoi ne pas y mettre](#5-un-starter-partagé--quoi-y-mettre-quoi-ne-pas-y-mettre)
- [6. Discipline anti-bruit](#6-discipline-anti-bruit)
- [7. Sécurité et vie privée, dès le départ](#7-sécurité-et-vie-privée-dès-le-départ)
- [8. Une alerte sans runbook n'est pas une alerte](#8-une-alerte-sans-runbook-nest-pas-une-alerte)
- [9. Checklist « jour 1 »](#9-checklist--jour-1-)
- [10. Dette assumée à ne pas reproduire sans y penser](#10-dette-assumée-à-ne-pas-reproduire-sans-y-penser)

## 1. Les questions à se poser avant de choisir un outil

Choisir Prometheus/Jaeger/Grafana par réflexe (« c'est ce qu'on connaît ») saute l'étape qui compte. Se poser dans
l'ordre :

| Question | Pourquoi elle vient en premier | Exemple dans ce POC |
|---|---|---|
| Quel est le **SLI qui compte** pour ce métier, pas un SLI générique ? | Il détermine la métrique phare, pas l'inverse | le lag de cohérence lecture/écriture (`projection_lag_seconds`) |
| Combien de temps a-t-on pour répondre « qu'est-ce qui se passe » en prod ? | Dashboard temps réel ≠ recherche manuelle de logs a posteriori | dashboard + exemplar → trace en quelques clics |
| Quelles contraintes de licence ? | Change le choix d'outil, pas seulement sa configuration | Apache 2.0 par défaut, exception Grafana AGPLv3 assumée et documentée |
| Quelle cible de déploiement ? | Sondes, ports de management, format de logs en dépendent | Kubernetes : `liveness`/`readiness`, arrêt propre |
| Combien de services au départ, combien à terme ? | Justifie ou non un starter/bibliothèque partagée | 3 services dès le départ → starter Maven interne dès le départ |

## 2. Le modèle en couches

Le même modèle s'applique quel que soit l'outillage retenu : **instrumentation → transport/collecte → stockage →
visualisation → alerting**. Chaque couche se choisit indépendamment des autres, ce qui rend le tout remplaçable par
morceaux.

| Couche | Rôle | Choix fait ici | Autre option possible |
|---|---|---|---|
| Instrumentation | émettre spans/métriques/logs depuis le code, sans y penser | Micrometer Observation + pont OpenTelemetry, auto-instrumentation Spring | OpenTelemetry SDK natif si hors Spring |
| Transport | acheminer le signal du process vers un backend | OTLP (push) pour les traces, scrape Prometheus (pull) pour les métriques | tout OTLP + Prometheus Remote Write si on veut un seul protocole |
| Collecte/relais | agréger, filtrer, dériver | OTel Collector (dérive des métriques RED depuis les traces) | agent par nœud (DaemonSet) en Kubernetes |
| Stockage | conserver et indexer | Jaeger (traces), Prometheus (métriques) | Tempo/Elasticsearch, Mimir/Thanos pour la rétention longue |
| Visualisation | répondre aux questions humaines | Grafana | outil Apache 2.0 (Perses) si la licence AGPLv3 doit être réévaluée |
| Alerting | déclencher une action | règles Prometheus (`alerts.yml`) | + Alertmanager pour le routage (non fait ici, voir §10) |

## 3. Push vs pull : ce n'est pas un détail

C'est la décision la plus structurante et la plus facile à prendre par défaut sans réfléchir. Deux logiques
différentes, à choisir **signal par signal**, pas globalement :

- **Push (OTLP)** : le process envoie activement ses données vers un collecteur. Naturel pour les **traces** : chaque
  requête produit un événement discret, à un instant précis, qu'on veut acheminer tout de suite vers un point
  central pour assembler l'arbre de spans multi-services.
- **Pull (scrape)** : un backend vient lire périodiquement un endpoint exposé par le process. Naturel pour les
  **métriques**, qui sont un état cumulatif (compteurs, histogrammes) que l'on peut interroger à intervalle régulier.

Le critère de décision concret rencontré ici : **les exemplars** (le lien cliquable d'un point de métrique vers la
trace qui l'a produit) ne sont fiables, côté Micrometer, que sur le registre Prometheus scrapé — pas sur l'exporteur
OTLP metrics. Le détail de ce choix, avec la configuration exacte, est expliqué dans
[observability-explained.md §7](observability-explained.md#7-pourquoi-lotlp-est-coupé-pour-les-métriques-et-les-logs-mais-pas-pour-les-traces).

**Règle générale à retenir pour un futur projet** : ne pas décider push-partout ou pull-partout par cohérence
esthétique. Décider par signal, en fonction de ce que le backend cible sait vraiment bien faire avec chacun.

## 4. Une seule clé de corrélation métier, posée une fois

Recette générique, indépendante du domaine :

1. Choisir **une** clé métier qui permet de « retrouver ses billes » (ici `order.id` ; ailleurs `invoice.id`,
   `tenant.id`…).
2. La poser **une seule fois**, à la frontière d'entrée (gateway, contrôleur d'API), jamais dans chaque couche.
3. La propager comme **baggage W3C** : elle traverse alors HTTP, la messagerie et les frontières transactionnelles
   sans code de propagation manuel.
4. La recopier en attribut de span (recherche par tag dans l'outil de traces) et dans le MDC des logs (corrélation
   logs ↔ traces).
5. **Ne jamais faire confiance à une clé de corrélation envoyée par un client externe** : la frontière d'entrée doit
   supprimer/écraser ce que le client a pu injecter, sinon n'importe qui peut usurper l'identifiant d'un tiers dans
   les traces et les logs.

## 5. Un starter partagé : quoi y mettre, quoi ne pas y mettre

Dès que plusieurs services existent, factoriser la plomberie d'observabilité dans une bibliothèque interne
(auto-configuration) évite la dérive service par service. Règle simple et non négociable :

- ✅ **Transverse technique** : valeurs par défaut d'exploitation, spans automatiques par couche, filtrage du bruit,
  recopie de baggage.
- ❌ **Jamais de code métier.**
- ❌ **Jamais de clé de corrélation propre à un domaine** : chaque service déclare les siennes.

Contrepartie assumée : le starter devient un composant partagé, versionné et publié indépendamment ; toute évolution
s'évalue sur l'ensemble des services qui en dépendent (voir [ADR-0005](adr/0005-observabilite-opentelemetry.md)).

## 6. Discipline anti-bruit

Sans ce travail, les outils de traces/métriques se remplissent de signal sans valeur et noient le signal utile :

- Exclure les endpoints d'exploitation (`/actuator`, health checks) de la production de traces — chaque scrape
  Prometheus créerait sinon une trace.
- Éviter les spans/traces orphelins (requêtes SQL de polling, migrations, tâches planifiées) : soit les rattacher à
  une trace existante, soit les exclure explicitement.
- Décider l'échantillonnage **une seule fois, à la racine** de la requête (gateway/point d'entrée), et le faire
  respecter par tous les services en aval : une trace doit être complète ou totalement absente, jamais partielle.

## 7. Sécurité et vie privée, dès le départ

Pas une case à cocher en fin de projet : à concevoir avec l'instrumentation elle-même.

- Aucune valeur de paramètre SQL dans les spans (les paramètres peuvent contenir des données personnelles).
- Aucune donnée personnelle dans les logs de niveau INFO.
- Actuator restreint aux endpoints strictement nécessaires à l'exploitation (`health`, `info`, `prometheus`), jamais
  les détails de santé en clair en production.
- Erreurs HTTP normalisées sans fuite de détail interne (stacktrace, message technique) au client.
- La frontière d'entrée ignore toute clé de corrélation envoyée par le client (cf. §4).

## 8. Une alerte sans runbook n'est pas une alerte

Une règle Prometheus qui déclenche sans que personne sache quoi faire produit de la fatigue d'alerte, pas de la
fiabilité. Pour chaque alerte définie :

1. Elle référence une métrique qui existe déjà et qui a un seuil justifié par un objectif métier (pas une valeur
   arbitraire copiée d'un autre projet).
2. Elle a une entrée de runbook correspondante : quoi vérifier en premier, quoi vérifier ensuite, comment agir
   (exemple concret : [observability.md § Runbook](observability.md#runbook)).
3. Elle est routée vers quelqu'un (Alertmanager ou équivalent) — une alerte que personne ne reçoit n'existe pas.

## 9. Checklist « jour 1 »

À dérouler au démarrage d'un nouveau projet, avant d'écrire la première fonctionnalité métier :

1. Répondre aux questions du §1 (SLI, budget de réponse, licences, cible de déploiement, nombre de services).
2. Choisir push/pull **par signal** (§3), pas par habitude.
3. Définir la clé de corrélation métier et son mécanisme de propagation (§4).
4. Si plusieurs services sont prévus dès le départ : créer le starter partagé avant le premier service métier, pas
   après le troisième.
5. Mettre en place le filtrage du bruit (§6) en même temps que l'instrumentation, pas en réaction à un dashboard
   illisible.
6. Écrire les premières alertes en même temps que les premières métriques, avec leur runbook (§8).
7. Vérifier la checklist sécurité (§7) avant la mise en production, pas après un incident.

## 10. Dette assumée à ne pas reproduire sans y penser

Ce que ce POC n'a délibérément pas fait, et qu'un projet qui va en production devra trancher explicitement (détail :
[production-checklist.md](production-checklist.md)) :

- **Alertmanager non branché** : les règles s'évaluent mais ne sont routées vers personne.
- **Pas de rétention persistante pour Jaeger** (Elasticsearch/OpenSearch/Cassandra) : les traces disparaissent au
  redémarrage du conteneur.
- **Échantillonnage à 100 %** : à réduire en production (`TRACING_SAMPLING_PROBABILITY`), au prix de traces
  incomplètes pour l'analyse a posteriori — les métriques, elles, restent exhaustives.
- **Pas d'agent de collecte des logs** branché vers un backend centralisé : les logs JSON sont écrits sur stdout et
  supposent qu'une brique de plateforme (hors périmètre de ce POC) les récupère.

Ces quatre points ne sont pas des oublis : ce sont des choix pour aller vite sur un POC, à rouvrir consciemment pour
tout projet qui vise la production.

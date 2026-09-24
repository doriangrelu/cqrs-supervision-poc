#!/usr/bin/env bash
# Lance les 3 applis en arrière-plan (logs dans ./logs). Arguments supplémentaires passés au projecteur,
# ex : scripts/run-apps.sh --spring.kafka.listener.concurrency=1
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs

start() {
    local module=$1; shift
    java -jar "$module/target/$module-0.0.1-SNAPSHOT.jar" "$@" > "logs/$module.log" 2>&1 &
    echo "$module démarré (pid $!, logs/$module.log)"
}

# local : endpoint de charge _bulk actif, historique de l'outbox conservé (lien base → trace)
start order-service --order.load-test.enabled=true --namastack.outbox.processing.delete-completed-records=false
start order-projector "$@"
start gateway

for port in 8081 8082 8080; do
    until curl -sf "localhost:$port/actuator/health" > /dev/null; do sleep 1; done
    echo "port $port prêt"
done

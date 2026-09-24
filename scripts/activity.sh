#!/usr/bin/env bash
# Génère une activité aléatoire réaliste via la gateway : des "clients" créent des commandes, les font avancer
# dans leur cycle de vie, relisent côté écriture et côté lecture (projection).
#
# Usage : scripts/activity.sh [-d durée_s=60] [-w clients=4] [-r requêtes/s par client=5] [-u url=http://localhost:8080]
#   ex : scripts/activity.sh -d 300 -w 8 -r 10
#
# Mesure aussi la cohérence à terme vue du client : une "lecture périmée" est une lecture de la projection
# (GET /orders-view/{id}) qui ne reflète pas encore la dernière écriture faite par ce client.
set -uo pipefail

DURATION=60 WORKERS=4 RATE=5 URL=http://localhost:8080
while getopts "d:w:r:u:h" opt; do
    case $opt in
        d) DURATION=$OPTARG ;;
        w) WORKERS=$OPTARG ;;
        r) RATE=$OPTARG ;;
        u) URL=$OPTARG ;;
        *) sed -n '2,9p' "$0"; exit 0 ;;
    esac
done

PAUSE=$(awk "BEGIN { printf \"%.3f\", 1 / $RATE }")
STATS_DIR=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; report; rm -rf "$STATS_DIR"; exit 0' INT TERM

# Transitions valides : CREATED→PAID|CANCELLED, PAID→SHIPPED|CANCELLED ; SHIPPED et CANCELLED sont terminaux.
next_status() {
    case $1 in
        CREATED) (( RANDOM % 5 == 0 )) && echo CANCELLED || echo PAID ;;
        PAID)    (( RANDOM % 6 == 0 )) && echo CANCELLED || echo SHIPPED ;;
    esac
}

# $1 méthode, $2 chemin, $3 corps JSON optionnel → variables HTTP_CODE et BODY
call() {
    local out
    out=$(curl -s -m 10 -X "$1" "$URL$2" -H 'Content-Type: application/json' ${3:+-d "$3"} -w $'\n%{http_code}')
    HTTP_CODE=${out##*$'\n'}
    BODY=${out%$'\n'*}
}

json_field() { grep -oE "\"$1\":\"?[^,\"}]*" <<< "$BODY" | head -1 | sed -E "s/\"$1\":\"?//"; }

worker() {
    local stats=$STATS_DIR/worker-$1 end=$(( SECONDS + DURATION ))
    declare -A status version   # commandes actives de ce client : statut et version attendus
    local ids=()

    while (( SECONDS < end )); do
        local dice=$(( RANDOM % 100 )) id=""
        (( ${#ids[@]} )) && id=${ids[RANDOM % ${#ids[@]}]}

        if [[ -z $id ]] || (( dice < 30 )); then
            call POST /orders "{\"customerId\":\"customer-$(( RANDOM % 200 ))\",\"amount\":$(( RANDOM % 500 )).$(( RANDOM % 100 ))}"
            echo "create $HTTP_CODE" >> "$stats"
            if [[ $HTTP_CODE == 201 ]]; then
                id=$(json_field id); ids+=("$id"); status[$id]=CREATED; version[$id]=1
            fi

        elif (( dice < 60 )); then
            local target
            if (( dice < 33 )); then
                target=CREATED          # transition interdite volontaire : doit être refusée (409)
            else
                target=$(next_status "${status[$id]}")
            fi
            call PATCH "/orders/$id/status" "{\"status\":\"$target\"}"
            echo "status $HTTP_CODE" >> "$stats"
            if [[ $HTTP_CODE == 200 ]]; then
                status[$id]=$target; version[$id]=$(json_field version)
                if [[ $target == SHIPPED || $target == CANCELLED ]]; then   # terminal : on l'oublie
                    ids=("${ids[@]/$id}"); ids=(${ids[@]}); unset "status[$id]" "version[$id]"
                fi
            fi

        elif (( dice < 75 )); then
            call GET "/orders/$id"
            echo "read-write-side $HTTP_CODE" >> "$stats"

        else
            call GET "/orders-view/$id"
            echo "read-projection $HTTP_CODE" >> "$stats"
            local seen=0
            [[ $HTTP_CODE == 200 ]] && seen=$(json_field lastVersion)
            (( seen < ${version[$id]:-0} )) && echo "stale-read" >> "$stats"
        fi
        sleep "$PAUSE"
    done
}

report() {
    echo
    echo "=== Bilan ($(cat "$STATS_DIR"/worker-* 2>/dev/null | grep -vc stale-read) requêtes) ==="
    cat "$STATS_DIR"/worker-* 2>/dev/null | grep -v stale-read | sort | uniq -c | awk '{ printf "  %-18s HTTP %s : %6d\n", $2, $3, $1 }'
    local reads stale
    reads=$(cat "$STATS_DIR"/worker-* 2>/dev/null | grep -c "^read-projection")
    stale=$(cat "$STATS_DIR"/worker-* 2>/dev/null | grep -c "^stale-read")
    (( reads )) && echo "  Lectures périmées (projection en retard sur l'écriture du client) : $stale / $reads ($(( 100 * stale / reads ))%)"
    echo "  → Grafana http://localhost:3000/d/coherence-cqrs  |  Jaeger http://localhost:16686"
}

echo "Activité : $WORKERS clients × ~$RATE req/s pendant ${DURATION}s sur $URL (Ctrl+C pour arrêter)"
for (( w = 1; w <= WORKERS; w++ )); do worker "$w" & done

while (( $(jobs -rp | wc -l) > 0 )); do
    sleep 5
    printf '\r  %6d requêtes envoyées' "$(cat "$STATS_DIR"/worker-* 2>/dev/null | grep -vc stale-read)"
done
report
rm -rf "$STATS_DIR"

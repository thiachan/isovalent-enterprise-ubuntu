#!/usr/bin/env bash
# Generate allowed + blocked traffic to demonstrate the policies, then the drops
# show up in Hubble and Timescape. Traffic is generated from inside the cluster
# using pods that already have python3 (loadgenerator, recommendationservice).
set -euo pipefail

NS=online-boutique

fe_pod() { kubectl -n "$NS" get pod -l app=frontend   -o jsonpath='{.items[0].status.podIP}'; }
redis_ip() { kubectl -n "$NS" get pod -l app=redis-cart -o jsonpath='{.items[0].status.podIP}'; }
lg_pod()  { kubectl -n "$NS" get pod -l app=loadgenerator -o jsonpath='{.items[0].metadata.name}'; }
rec_pod() { kubectl -n "$NS" get pod -l app=recommendationservice -o jsonpath='{.items[0].metadata.name}'; }

FE=$(fe_pod); REDIS=$(redis_ip); LG=$(lg_pod); REC=$(rec_pod)
echo "frontend=$FE redis-cart=$REDIS loadgen=$LG rec=$REC"

tcp_test() { # pod container ip port label
  kubectl -n "$NS" exec "$1" -c "$2" -- python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(4)
try:
    s.connect(('$3',$4)); print('$5: CONNECTED')
except Exception as e:
    print('$5: BLOCKED (dropped)')" 2>&1
}

http_test() { # pod method ip label
  kubectl -n "$NS" exec "$1" -c main -- python3 -c "
import http.client
c=http.client.HTTPConnection('$3',8080,timeout=5)
c.request('$2','/'); r=c.getresponse(); print('$4:', r.status, r.reason)" 2>&1
}

echo "--- L4: 9999 to frontend (expect BLOCKED) ---"
for i in 1 2 3; do tcp_test "$LG" main "$FE" 9999 "9999"; done

echo "--- L4 east-west: recommendationservice -> redis:6379 (expect BLOCKED) ---"
for i in 1 2 3; do tcp_test "$REC" recommendationservice "$REDIS" 6379 "redis6379"; done

echo "--- L7: GET frontend:8080 (expect 200) ---"
http_test "$LG" GET "$FE" "GET"

echo "--- L7: DELETE frontend:8080 (expect 403 when frontend-l7-http is authoritative) ---"
for i in 1 2 3; do http_test "$LG" DELETE "$FE" "DELETE"; done

echo "Done. Now run scripts/04-verify-timescape.sh to see the records in ClickHouse."

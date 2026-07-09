#!/usr/bin/env bash
# Verify flows + policy verdicts landed in the Timescape ClickHouse `flows` table.
# Verdict codes: 1=FORWARDED, 2=DROPPED, 6=TRACED, 7=TRANSLATED.
set -euo pipefail

NS=hubble-timescape
CH=(kubectl -n "$NS" exec hubble-timescape-lite-0 -c clickhouse --
    clickhouse-client -u timescape_lite -d hubble -q)

echo "== total flows =="
"${CH[@]}" "SELECT count() FROM flows"

echo "== clusters =="
"${CH[@]}" "SELECT \`flow/source/cluster_name\` c, count() FROM flows GROUP BY c HAVING c!=''"

echo "== namespaces =="
"${CH[@]}" "SELECT DISTINCT \`flow/source/namespace\` ns FROM flows WHERE ns!='' ORDER BY ns"

echo "== L4 drops (9999 + redis 6379) =="
"${CH[@]}" "SELECT \`flow/destination/pod_name\` dst, \`flow/l4/tcp/destination_port\` dport, count() \
FROM flows WHERE \`flow/verdict\`=2 AND \`flow/l4/tcp/destination_port\` IN (9999,6379) GROUP BY dst,dport"

echo "== L7 HTTP method/code breakdown (look for DELETE 403) =="
"${CH[@]}" "SELECT \`flow/l7/http/method\` m, \`flow/l7/http/code\` code, count() \
FROM flows WHERE \`flow/l7/http/method\`!='' GROUP BY m,code ORDER BY 3 DESC"

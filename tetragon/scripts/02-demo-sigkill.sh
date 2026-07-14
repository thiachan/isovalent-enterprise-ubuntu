#!/usr/bin/env bash
# Demo: Tetragon detects and blocks (Sigkill) shell execs inside online-boutique.
# Run the event stream on one pane and this on another for a live audience demo.
set -euo pipefail

NS=online-boutique
LG=$(kubectl -n "$NS" get pod -l app=loadgenerator -o jsonpath='{.items[0].metadata.name}')

echo "== apply the block-shell-exec policy =="
kubectl apply -f "$(dirname "$0")/../block-shell-exec.yaml"
sleep 5

echo "== try to run a shell (expect exit 137 = SIGKILL) =="
kubectl -n "$NS" exec "$LG" -c main -- sh -c 'echo hello-from-shell' ; echo "exit: $?"
kubectl -n "$NS" exec "$LG" -c main -- bash -c 'id' ; echo "exit: $?"

echo "== app pod is unharmed =="
kubectl -n "$NS" get pod "$LG" --no-headers

cat <<'DONE'

To watch the events live (second pane):
  kubectl -n tetragon exec ds/tetragon -c tetragon -- tetra getevents -o compact

To remove the policy:
  kubectl -n online-boutique delete tracingpolicynamespaced block-shell-exec
DONE

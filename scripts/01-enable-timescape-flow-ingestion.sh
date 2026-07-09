#!/usr/bin/env bash
# Enable Cilium -> Hubble Timescape flow ingestion (Lite, stream/push API).
# Fixes: Timescape "Choose cluster" dropdown empty / "No matches".
#
# Root cause: Cilium is not configured to stream Hubble flows to the Timescape
# ingester, so the ClickHouse `flows` table stays empty and the UI has no cluster
# to list. This adds the two required cilium-config keys and restarts the agents.
set -euo pipefail

NS_CILIUM=kube-system
TARGET="hubble-timescape-export.hubble-timescape.svc.cluster.local:4261"

echo "== Backing up cilium-config =="
kubectl -n "$NS_CILIUM" get cm cilium-config -o yaml > "/tmp/cilium-config.backup.$(date +%s).yaml"

echo "== Patching cilium-config =="
kubectl -n "$NS_CILIUM" patch cm cilium-config --type merge -p "{\"data\":{\
\"hubble-export-timescape-enabled\":\"true\",\
\"hubble-export-timescape-target\":\"${TARGET}\"}}"

echo "== Verifying keys =="
kubectl -n "$NS_CILIUM" get cm cilium-config -o yaml | grep -E 'hubble-export-timescape'

echo "== Restarting Cilium DaemonSet =="
kubectl -n "$NS_CILIUM" rollout restart ds/cilium
kubectl -n "$NS_CILIUM" rollout status ds/cilium --timeout=180s

echo "== Confirm ingestion (look for stream.flows.flushed) =="
sleep 10
kubectl -n hubble-timescape logs hubble-timescape-lite-0 -c timescape --tail=60 \
  | grep -E 'stream.flows.flushed' | tail -3 || echo "no stream lines yet - re-check in a moment"

echo "Done. The 'default' cluster and namespaces should appear in the Timescape UI shortly."

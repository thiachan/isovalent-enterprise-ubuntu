#!/usr/bin/env bash
# Stand up Prometheus + Grafana (kube-prometheus-stack) and wire Tetragon metrics
# into a Grafana dashboard. Run detached-friendly; the cluster finishes server-side
# even if your SSH drops (helm submits the objects; kubelet does the rest).
set -euo pipefail

NS=monitoring

echo "== add prometheus-community repo =="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "== install kube-prometheus-stack (trimmed) =="
helm -n "$NS" upgrade --install kps prometheus-community/kube-prometheus-stack \
  --set alertmanager.enabled=false \
  --set nodeExporter.enabled=false \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30300 \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.retention=2h \
  --wait --timeout 12m

echo "== scrape Tetragon =="
kubectl apply -f "$(dirname "$0")/tetragon-servicemonitor.yaml"

echo "== import Tetragon dashboard (Grafana sidecar picks up the labelled ConfigMap) =="
kubectl -n "$NS" create configmap tetragon-dashboard \
  --from-file=tetragon-dashboard.json="$(dirname "$0")/grafana/tetragon-dashboard.json" \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

cat <<'DONE'

Done.
- Grafana:  NodePort 30300  (user: admin / pass: admin)
- Dashboard: "Tetragon Runtime Security"  (/d/tetragon-runtime)
- Verify scrape:  up{job="tetragon"} == 1

Tip: the Grafana admin password above is a lab default. Change it for anything real.
DONE

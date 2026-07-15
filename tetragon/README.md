# Tetragon — runtime security (detection + enforcement)

Runtime‑security layer that complements the network story (Cilium/Hubble/Timescape).
Tetragon uses **eBPF** to observe and optionally **enforce** process, file, network, and
capability activity **inside** pods — no sidecar, no app changes.

## Components (in this cluster)
- **agent** — `DaemonSet` (one per node); loads eBPF, observes/enforces for all pods on the node.
- **operator** — `Deployment`; manages `TracingPolicy` CRDs and config.

Both run in the `tetragon` namespace.

---

## 1. Process‑execution visibility (CLI)
No policy needed. Stream events from the agent:

```bash
kubectl -n tetragon exec ds/tetragon -c tetragon -- tetra getevents -o compact
# trigger one in another pane:
kubectl -n online-boutique exec deploy/loadgenerator -c main -- sh -c 'cat /etc/passwd; id'
```
You'll see `🚀 process` / `💥 exit` lines with the pod, binary, args, and full process ancestry.

---

## 2. Runtime enforcement — block shells (Sigkill)
[`block-shell-exec.yaml`](block-shell-exec.yaml) is a `TracingPolicyNamespaced` that **kills any
shell** exec in `online-boutique`.

```bash
./scripts/02-demo-sigkill.sh
```

Expected: `sh`/`bash` in a pod → **exit 137 (SIGKILL)**; the app pod stays `1/1 Running`
(Tetragon kills the offending process, not the workload).

> **Kernel‑signature gotcha (important):** the hook
> `security_bprm_creds_from_file(struct linux_binprm *bprm, struct file *file)` has the **file at
> argument index 1**, not 0. Matching index 0 silently fails to enforce (you'll see a
> `type ... does not match spec type (file)` warning in the agent log). Use index 1.

---

## 3. Grafana UI (aggregate metrics + enforcement)
Tetragon exposes Prometheus metrics on `tetragon:2112`. [`scripts/01-install-grafana-tetragon.sh`](scripts/01-install-grafana-tetragon.sh)
installs `kube-prometheus-stack`, scrapes Tetragon via [`tetragon-servicemonitor.yaml`](tetragon-servicemonitor.yaml),
and imports [`grafana/tetragon-dashboard.json`](grafana/tetragon-dashboard.json).

```bash
./scripts/01-install-grafana-tetragon.sh
```

- **Grafana:** NodePort **30300** (login **admin** / password from the `kps-grafana` secret in the
  `monitoring` namespace — `kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d`).
- **Dashboard:** *Tetragon Runtime Security* (`/d/tetragon-runtime`) — two rows:
  - **Activity:** exec totals, exec‑rate by namespace, top executed binaries, events by type.
  - **Runtime Enforcement:** enforcement actions total (SIGKILL), policies enforcing, enforcement
    rate by policy, and a table of what was blocked by policy/binary/namespace. Driven by the
    `tetragon_policy_events_total` metric.
- Verify scrape: `up{job="tetragon"} == 1`.

> The dashboard is **provisioned** via the `tetragon-dashboard` ConfigMap (label `grafana_dashboard=1`)
> in the `monitoring` namespace, so the Grafana API won't overwrite it directly. To change panels,
> edit [`grafana/tetragon-dashboard.json`](grafana/tetragon-dashboard.json) and replace the ConfigMap:
> ```bash
> kubectl -n monitoring create configmap tetragon-dashboard \
>   --from-file=tetragon-dashboard.json=grafana/tetragon-dashboard.json \
>   --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client | kubectl apply -f -
> ```
> The Grafana sidecar reloads it within ~30–60 s.

---

## What shows where (full picture)
| Layer | Tool | UI |
|-------|------|-----|
| Live network map | Cilium/Hubble → Relay | **Hubble UI** (:30012) |
| Network flows + policies (historical) | Cilium/Hubble → Timescape | Timescape UI (:30900) |
| Runtime process events (aggregate) + **enforcement count** | Tetragon → Prometheus | **Grafana** (:30300) |
| Runtime live events + the actual Sigkill | Tetragon | `tetra getevents` CLI |

Grafana shows **aggregate** metrics (including the enforcement/SIGKILL count) — the per‑event process
tree and the live enforcement event come from the CLI. For a demo, run the Grafana dashboard **and**
a `tetra getevents` pane.

---

## Cleanup
```bash
kubectl -n online-boutique delete tracingpolicynamespaced block-shell-exec
helm -n monitoring uninstall kps
kubectl delete ns monitoring
```

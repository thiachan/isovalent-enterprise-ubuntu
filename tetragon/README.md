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

## 3. Grafana UI (aggregate metrics)
Tetragon exposes Prometheus metrics on `tetragon:2112`. [`scripts/01-install-grafana-tetragon.sh`](scripts/01-install-grafana-tetragon.sh)
installs `kube-prometheus-stack`, scrapes Tetragon via [`tetragon-servicemonitor.yaml`](tetragon-servicemonitor.yaml),
and imports [`grafana/tetragon-dashboard.json`](grafana/tetragon-dashboard.json).

```bash
./scripts/01-install-grafana-tetragon.sh
```

- **Grafana:** NodePort **30300** (login **admin / admin** — lab default, change it for real use).
- **Dashboard:** *Tetragon Runtime Security* (`/d/tetragon-runtime`) — exec totals, exec‑rate by
  namespace, top executed binaries, events by type.
- Verify scrape: `up{job="tetragon"} == 1`.

---

## What shows where (full picture)
| Layer | Tool | UI |
|-------|------|-----|
| Network flows + policies | Cilium/Hubble → Timescape | Timescape UI (:30900) |
| Runtime process events (aggregate counts/rates) | Tetragon → Prometheus | **Grafana (:30300)** |
| Runtime live events + the actual Sigkill | Tetragon | `tetra getevents` CLI |

Grafana shows **aggregate** metrics only — the per‑event process tree and the live enforcement
event come from the CLI. For a demo, run the Grafana dashboard **and** a `tetra getevents` pane.

---

## Cleanup
```bash
kubectl -n online-boutique delete tracingpolicynamespaced block-shell-exec
helm -n monitoring uninstall kps
kubectl delete ns monitoring
```

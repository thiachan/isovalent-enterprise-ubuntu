# Isovalent Enterprise on Ubuntu — Hubble Timescape (Lite) Runbook

Operational notes, manifests, scripts, and tests for running **Isovalent Enterprise for Cilium**
with **Hubble Timescape (Lite)** on a single‑node Ubuntu Kubernetes cluster, using the
**Online Boutique** demo app.

This repo captures a real troubleshooting + demo session:

1. Fixing Timescape so it shows the cluster and namespaces (flow ingestion).
2. Writing L4 and L7 Cilium network policies.
3. Generating and verifying allowed/blocked traffic in Timescape.
4. Enabling the Timescape **Assessment** and **Enforcement Points** (Beta) UI features.

> For a stage‑ready, end‑to‑end walkthrough of **all** the features (with architecture and
> sequence diagrams), see **[DEMO.md](DEMO.md)**.

> Terminology: **SCC** = Cisco Security Cloud Control, **cdFMC** = cloud‑delivered FMC.

---

## 1. Environment

| Component | Detail |
|-----------|--------|
| OS | Ubuntu 24.04 LTS |
| Kubernetes | single node (`ubuntu-amber-yak-88`) |
| CNI | Isovalent Enterprise for Cilium (v1.18.7), Hubble enabled, `cluster-name: default` |
| Live network map | Hubble Relay + **Hubble UI** (`kube-system`) |
| Observability | Hubble Timescape **Lite** (`hubble-timescape` namespace) |
| Runtime | Tetragon |
| Demo app | Online Boutique (`online-boutique` namespace) |

### Demo UIs / NodePorts (host 192.168.7.10)

| UI | NodePort | Login | Purpose |
|----|----------|-------|---------|
| Online Boutique | **30080** | — | the live app |
| Hubble UI | **30012** | — | live service map + real‑time flows |
| Timescape | **30900** | — | historical flows + Network Security posture |
| Grafana | **30300** | admin / see secret† | Tetragon metrics + enforcement dashboard |

> † **Grafana admin password** is not stored in this repo. Fetch it from the cluster:
> ```bash
> kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
> ```

SSH tunnel for all four:

```bash
ssh -J administrator@198.18.133.11 ubuntu@192.168.7.10 -p 32095 -N \
  -L 30080:localhost:30080 -L 30012:localhost:30012 \
  -L 30300:localhost:30300 -L 30900:localhost:30900
```

Timescape Lite components:

- `hubble-timescape-lite-0` — 2 containers: `clickhouse` (store) + `timescape` (ingester + server + UI)
- `hubble-timescape-k8s-exporter` — pushes k8s metadata to the ingester

---

## 2. How flow ingestion works (Lite)

Timescape Lite does **not** use an object storage bucket by default. Flows are **pushed by Cilium**
directly to the Timescape ingester's stream API:

```
Cilium/Hubble  --(gRPC stream :4261)-->  hubble-timescape-export  -->  ClickHouse `flows` table
```

The Timescape UI **Choose cluster** dropdown and the namespace list are built from the `flows`
table (via the `namespaces_flow_source_mv` / `namespaces_flow_destination_mv` materialized views).
**No flows ⇒ empty dropdown / "No matches".**

### The fix — enable Cilium → Timescape flow export

If the cluster dropdown is empty, check `cilium-config` for these two keys. If missing, flows never
reach Timescape (only k8s metadata does):

```yaml
hubble-export-timescape-enabled: "true"
hubble-export-timescape-target: hubble-timescape-export.hubble-timescape.svc.cluster.local:4261
```

Apply with [`scripts/01-enable-timescape-flow-ingestion.sh`](scripts/01-enable-timescape-flow-ingestion.sh).

Confirm ingestion in the `timescape` container logs:

```
level=INFO msg=tick subsys=progress stream.flows.flushed=442/s
```

> `flows-ttl` is `1h` in Lite (only the last hour is retained). ClickHouse uses an `emptyDir`, so a
> pod restart clears history — it refills from the live stream within ~1 minute.

---

## 3. Writing network policies

See [`policies/`](policies). Two patterns are included.

### 3.1 L4 east‑west zero‑trust (`redis-cart`)

Allow `redis-cart:6379` **only** from `cartservice`. Any other source is dropped at L4.

File: [`policies/redis-cart-allow-cartservice.yaml`](policies/redis-cart-allow-cartservice.yaml)

### 3.2 L7 HTTP visibility + enforcement (`frontend`)

Allow only `GET` and `POST` on `frontend:8080`. This single policy does **two** things because an
L7 `ingress` rule puts the endpoint into default‑deny:

- **L4:** any port other than 8080 (e.g. 9999) is dropped.
- **L7:** on 8080, non‑`GET`/`POST` methods (e.g. `DELETE`) get **403 Forbidden**.

File: [`policies/frontend-l7-http.yaml`](policies/frontend-l7-http.yaml)

> **Policy union caveat:** Cilium policies are additive (allow‑list). If you *also* keep a plain
> L4 allow‑all on port 8080 (e.g. the original `allow-frontend-ingress` k8s NetworkPolicy, or the
> reference `frontend-l4-allow-8080.yaml`), the L4 allow‑all **overrides** the L7 method filter and
> `DELETE` is no longer 403 (you'll see the app's own `405` instead). For an L7 deny demo, make the
> L7 CNP authoritative (remove the L4 allow‑all).

Apply the policies:

```bash
kubectl apply -f policies/redis-cart-allow-cartservice.yaml
kubectl apply -f policies/frontend-l7-http.yaml
# For an L7 DENY demo, ensure no L4 allow-all on frontend:8080 exists:
kubectl -n online-boutique delete netpol allow-frontend-ingress --ignore-not-found
```

---

## 4. Running the tests

[`scripts/03-test-policies.sh`](scripts/03-test-policies.sh) generates traffic from inside the
cluster (the `loadgenerator` and `recommendationservice` pods have `python3`):

| Test | Source → Destination | Expected |
|------|----------------------|----------|
| L4 allowed | `cartservice → redis-cart:6379` | connect (app traffic) |
| L4 denied  | `recommendationservice → redis-cart:6379` | **dropped** |
| L4 denied  | `* → frontend:9999` | **dropped** |
| L7 allowed | `GET frontend:8080/` | **200** |
| L7 denied  | `DELETE frontend:8080/` | **403** |

```bash
./scripts/03-test-policies.sh
```

---

## 5. Verifying in Timescape

### CLI (ClickHouse)

[`scripts/04-verify-timescape.sh`](scripts/04-verify-timescape.sh) queries the `flows` table
(verdict codes: `1`=FORWARDED, `2`=DROPPED):

```bash
./scripts/04-verify-timescape.sh
```

Example expected output:

```
clusters:            default <n>
drops 9999 / 6379:   frontend ... 9999 ; redis-cart ... 6379
L7 DELETE:           DELETE 403
```

### UI

`default` cluster → namespace `online-boutique`:

- **Observability → Flows**: filter destination + verdict.
  - `redis-cart` / verdict **Dropped** → east‑west denials.
  - `frontend` / verdict **Dropped** → `:9999` (L4) and `DELETE → 403` (L7).
  - `frontend` / verdict **Forwarded** → HTTP **method / URL / status** (L7 visibility).

---

## 6. Enabling the Beta UI features (Assessment + Enforcement Points)

These are Helm toggles (default `false`). Enable them the upgrade‑safe way with
[`scripts/02-enable-timescape-beta-features.sh`](scripts/02-enable-timescape-beta-features.sh):

```bash
helm -n hubble-timescape upgrade hubble-timescape isovalent/hubble-timescape \
  --version 1.18.7 --reuse-values \
  --set ui.networkSecurity.assessment.enabled=true \
  --set ui.networkSecurity.enforcementPoints.enabled=true
```

The pod restarts (~30–60 s; flow history resets and refills). The **Assessment** report is produced
by the analyzer on `schedule-interval: 24h`.

---

## 7. Repo layout

```
.
├── README.md
├── policies/
│   ├── allow-frontend-ingress.yaml          # original L4 k8s NetworkPolicy (reference)
│   ├── redis-cart-allow-cartservice.yaml    # L4 east-west zero-trust (CNP)
│   ├── frontend-l7-http.yaml                # L7 HTTP allow GET/POST (CNP)
│   └── frontend-l4-allow-8080.yaml          # basic L3/4 allow (reference; unions/overrides L7)
├── scripts/
│   ├── 01-enable-timescape-flow-ingestion.sh
│   ├── 02-enable-timescape-beta-features.sh
│   ├── 03-test-policies.sh
│   └── 04-verify-timescape.sh
└── tetragon/                                # runtime security (detection + enforcement)
    ├── README.md
    ├── block-shell-exec.yaml                # TracingPolicy: Sigkill shells in online-boutique
    ├── tetragon-servicemonitor.yaml         # scrape Tetragon metrics into Prometheus
    ├── grafana/tetragon-dashboard.json      # Grafana dashboard
    └── scripts/
        ├── 01-install-grafana-tetragon.sh   # Prometheus + Grafana + dashboard
        └── 02-demo-sigkill.sh               # enforcement demo
```

See [tetragon/README.md](tetragon/README.md) for the runtime‑security (Tetragon) detection,
Sigkill enforcement, and Grafana dashboard steps.

---

## 8. Troubleshooting quick reference

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Timescape "Choose cluster" empty / "No matches" | Cilium not exporting flows to Timescape | Add the two `hubble-export-timescape-*` keys, restart `ds/cilium` (§2) |
| Only k8s metadata, no flows in logs (`stream.flows.flushed` absent) | same as above | same |
| L7 `DELETE` returns `405` not `403` | an L4 allow‑all on 8080 unions with the L7 CNP | remove the L4 allow‑all so the L7 CNP is authoritative (§3.2) |
| `clickhouse` container `OOMKilled` (exit 137) | ClickHouse memory limit too low | raise ClickHouse resources; unrelated to ingestion wiring |
| ClickHouse `default` user auth error | wrong CLI user | use `clickhouse-client -u timescape_lite -d hubble` |

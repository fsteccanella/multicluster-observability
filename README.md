# Multicluster Observability

A local, reproducible observability demo built with two [kind](https://kind.sigs.k8s.io/) clusters.

- **hub** hosts Mimir, Loki, Tempo, and Grafana.
- **downstream** hosts Grafana Alloy and the [OpenTelemetry Astronomy Shop](https://opentelemetry.io/docs/demo/) distributed e-commerce demo.

Astronomy Shop includes frontend, frontend proxy, cart, checkout, product catalog, recommendation, payment, shipping, ad, fraud detection, accounting, email, currency, Kafka, PostgreSQL, Valkey, feature flags, and load generation.

```text
Astronomy Shop services -- OTLP traces/metrics/logs --> Alloy
Kubernetes container logs --------------------------> Alloy
PostgreSQL and Valkey exporters -- ServiceMonitors --> Alloy
Alloy self-metrics -- ServiceMonitor -------------> Alloy
Alloy --> Mimir (metrics), Loki (logs), Tempo (traces)
Grafana --> Mimir, Loki, Tempo
```

> **Local demo only.** No TLS, authentication between components, persistence, object storage, or high availability is configured. Grafana credentials are `admin` / `password`. Allocate at least **10 GiB** to Docker/OrbStack.

## Public endpoints

After following the deployment procedure below, no port-forward is required:

| Application | Kubernetes NodePort | Workstation URL |
|---|---:|---|
| Astronomy Shop frontend | `30080` | <http://127.0.0.1:18080/> |
| Astronomy Shop load generator UI | `30080` | <http://127.0.0.1:18080/loadgen/> |
| Grafana | `30300` | <http://127.0.0.1:13000> |
| Mimir HTTP API | `30090` | <http://127.0.0.1:19090> |
| Loki HTTP API | `30100` | <http://127.0.0.1:19100> |
| Tempo HTTP API | `30200` | <http://127.0.0.1:19200> |
| Tempo OTLP/gRPC | `30417` | `127.0.0.1:14317` |

The host mappings are defined in `clusters/hub-kind.yaml` and `clusters/downstream-kind.yaml`; kind applies them **only when a cluster is created**.

## Repository layout

```text
clusters/                              # kind definitions and host-port mappings
observability/
├── hub/                               # Mimir, Loki, Tempo, Grafana
└── downstream/                        # Alloy and Services that address the hub
sample-app/                            # Astronomy Shop Helm/Kustomize integration
scripts/apply-hub-endpoints.sh         # resolves hub Docker IP into EndpointSlices
```

## Prerequisites

Install and put on `PATH`:

- Docker Desktop or OrbStack, with 10 GiB+ allocated
- `kind`
- `kubectl`
- standalone `kustomize` v5+ (not only `kubectl kustomize`)
- `helm`
- `curl`

Run every command below from the repository root. The chart is rendered with `kustomize build --enable-helm`; Helm support is not enabled by `kubectl apply -k`.

## Complete clean deployment

The following is the canonical, idempotent clean-start procedure. It deletes local clusters with these names before creating them.

### 1. Recreate clusters

```bash
kind delete cluster --name downstream || true
kind delete cluster --name hub || true

kind create cluster --name hub \
  --image kindest/node:v1.32.2 \
  --config clusters/hub-kind.yaml

kind create cluster --name downstream \
  --image kindest/node:v1.32.2 \
  --config clusters/downstream-kind.yaml

kubectl --context kind-hub get nodes
kubectl --context kind-downstream get nodes
```

### 2. Deploy the hub

```bash
kubectl --context kind-hub apply -k observability/hub

kubectl --context kind-hub -n observability rollout status deployment/mimir --timeout=5m
kubectl --context kind-hub -n observability rollout status deployment/loki --timeout=5m
kubectl --context kind-hub -n observability rollout status deployment/tempo --timeout=5m
kubectl --context kind-hub -n observability rollout status deployment/grafana --timeout=5m

curl -fsS http://127.0.0.1:19090/ready
curl -fsS http://127.0.0.1:19100/ready
curl -fsS http://127.0.0.1:19200/ready
```

### 3. Deploy Alloy and its cross-cluster endpoints

Alloy scrapes its own `/metrics` endpoint and the PostgreSQL and Valkey exporters through ServiceMonitors. Instrumented Astronomy Shop services send application metrics via OTLP. Install the pinned ServiceMonitor CRD before deploying Alloy and Astronomy Shop; a Prometheus Operator deployment is not required:

```bash
kubectl --context kind-downstream apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.78.2/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
kubectl --context kind-downstream wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=2m
```

The downstream cluster cannot resolve hub Kubernetes Services directly. `apply-hub-endpoints.sh` resolves the `hub-control-plane` Docker-network address and creates EndpointSlices pointing to hub NodePorts.

```bash
kubectl --context kind-downstream apply -k observability/downstream
bash scripts/apply-hub-endpoints.sh

# Restart Alloy to load the generated configuration ConfigMap.
kubectl --context kind-downstream -n observability rollout restart deployment/alloy
kubectl --context kind-downstream -n observability rollout status deployment/alloy --timeout=5m
kubectl --context kind-downstream -n observability get svc,endpointslice
```

Rerun `bash scripts/apply-hub-endpoints.sh` after every hub cluster recreation.

### 4. Deploy Astronomy Shop

```bash
kustomize build --enable-helm sample-app | \
  kubectl --context kind-downstream -n demo apply -f -

kubectl --context kind-downstream -n demo rollout status deployment/kafka --timeout=5m
kubectl --context kind-downstream -n demo rollout status deployment/frontend --timeout=5m
kubectl --context kind-downstream -n demo rollout status deployment/frontend-proxy --timeout=5m
kubectl --context kind-downstream -n demo rollout status deployment/checkout --timeout=5m
kubectl --context kind-downstream -n demo rollout status deployment/load-generator --timeout=5m
kubectl --context kind-downstream -n demo rollout status deployment/postgresql-exporter --timeout=5m
kubectl --context kind-downstream -n demo rollout status deployment/valkey-exporter --timeout=5m

kubectl --context kind-downstream -n demo get deployments
```

The Collector, Prometheus, Grafana, Jaeger, and OpenSearch bundled with the Astronomy Shop chart are disabled. Application services send telemetry to Alloy via OTLP; dedicated PostgreSQL and Valkey exporters expose database and cache metrics for ServiceMonitor scraping. Alloy also collects Kubernetes container logs from the `demo` namespace.

The values and patches also:

- keep load generation bounded for a laptop;
- disable the optional `flagd-ui` sidecar;
- raise selected memory limits required on ARM/kind;
- configure both frontend and checkout with `SHIPPING_ADDR=http://shipping:8080`, required for successful shipping and checkout flows.

Allow one or two minutes for load generation and telemetry to populate.

## Use the demo

### Storefront and checkout

Open <http://127.0.0.1:18080/>. The storefront invokes the frontend proxy through NodePort. Checkout should complete with a `200` response once an item has been added to the cart.

The built-in load generator UI is at <http://127.0.0.1:18080/loadgen/>. It is already configured to generate bounded e-commerce traffic.

### Grafana

Open <http://127.0.0.1:13000> and sign in with `admin` / `password`.

The **Alloy Demo / Astronomy Shop Observability** dashboard includes:

- Services Reporting (distinct metric jobs with `target_info`) and frontend request rate;
- frontend p95 latency;
- a showcase request-activity panel combining selected custom and HTTP/RPC request counters by service;
- PostgreSQL connections to the `otel` database and Valkey keys in `db0`, scraped through ServiceMonitors;
- a **Microservice** multi-select filter for logs;
- a single unfiltered application-log panel. Rows containing `trace_id=` expose the `TraceID` derived-field link to Tempo; logs without a trace ID remain visible.

The demo is polyglot; log correlation is available only for selected services. Many stdout/stderr records do not contain a trace ID even when their request traces are present in Tempo.

After load generation has started, open **Explore → Loki**, find a recent application log with `trace_id=`, and follow its `TraceID` link to Tempo. In **Explore → Tempo**, search for traces with, for example:

```traceql
{ resource.service.name = "checkout" }
```

## CLI validation

### Metrics

The Alloy, PostgreSQL exporter, and Valkey exporter ServiceMonitors should each report `up=1`:

```bash
curl -fsSG \
  --data-urlencode 'query=up{cluster="downstream",service=~"alloy|postgresql-exporter|valkey-exporter"}' \
  http://127.0.0.1:19090/prometheus/api/v1/query
```

Confirm that database and cache metrics, not just exporter availability, are present:

```bash
curl -fsSG --data-urlencode 'query=pg_up{cluster="downstream"}' http://127.0.0.1:19090/prometheus/api/v1/query
curl -fsSG --data-urlencode 'query=pg_stat_database_numbackends{cluster="downstream",datname="otel"}' http://127.0.0.1:19090/prometheus/api/v1/query
curl -fsSG --data-urlencode 'query=redis_up{cluster="downstream"}' http://127.0.0.1:19090/prometheus/api/v1/query
curl -fsSG --data-urlencode 'query=redis_db_keys{cluster="downstream",db="db0"}' http://127.0.0.1:19090/prometheus/api/v1/query
```

Application metrics arrive through OTLP:

```bash
curl -fsSG \
  --data-urlencode 'query=sum(rate(app_frontend_requests_total{job="frontend"}[5m]))' \
  http://127.0.0.1:19090/prometheus/api/v1/query
```

### Logs

```bash
curl -fsSG \
  --data-urlencode 'query={namespace="demo", service_name="recommendation"}' \
  --data-urlencode 'limit=20' \
  http://127.0.0.1:19100/loki/api/v1/query_range
```

### Traces

```bash
curl -fsSG \
  --data-urlencode 'q={ resource.service.name = "checkout" }' \
  --data-urlencode 'limit=20' \
  http://127.0.0.1:19200/api/search
```

## Diagnostics

```bash
kubectl --context kind-hub -n observability get pods,svc
kubectl --context kind-downstream -n observability get pods,svc,endpointslice
kubectl --context kind-downstream -n demo get pods,deployments,svc
kubectl --context kind-downstream -n observability logs deployment/alloy --tail=200
```

Open Alloy's local UI only when diagnosing Alloy itself:

```bash
kubectl --context kind-downstream -n observability port-forward service/alloy 12345:12345
```

Then browse <http://127.0.0.1:12345/>.

## Updating the deployment

- After changing hub manifests: `kubectl --context kind-hub apply -k observability/hub`.
- After changing downstream Alloy manifests: `kubectl --context kind-downstream apply -k observability/downstream`; after changing `config.alloy`, run `kubectl --context kind-downstream -n observability rollout restart deployment/alloy` to load the updated ConfigMap.
- After changing Astronomy Shop values or patches: `kustomize build --enable-helm sample-app | kubectl --context kind-downstream -n demo apply -f -`.
- After recreating hub: rerun `bash scripts/apply-hub-endpoints.sh`.
- After changing `extraPortMappings`: recreate the affected kind cluster.

## Cleanup

```bash
kind delete cluster --name downstream
kind delete cluster --name hub
```

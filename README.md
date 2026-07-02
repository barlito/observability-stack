# Observability Stack

Self-hosted monitoring stack running on Docker Swarm behind Traefik.

## At a glance

The stack gives you the three pillars of observability — **metrics**, **logs** and **traces** — plus host/container resource monitoring, all in one Grafana:

| Service | Pillar | What it does |
|---------|--------|--------------|
| **Prometheus** | Metrics | Scrapes and stores time-series metrics (30-day retention). Source of truth for all metric queries. |
| **node-exporter** | Metrics | Exposes **host** metrics (CPU, RAM, disk, network) — one agent per Swarm node. |
| **cAdvisor** | Metrics | Exposes **per-container** metrics (CPU, RAM, net, fs) from the Docker engine — one agent per node. |
| **Loki** | Logs | Stores and indexes logs (30-day retention). Queried from Grafana. |
| **Alloy** | Logs | Collects every container's stdout/stderr via the Docker API and ships it to Loki — one agent per node, no logging driver needed. |
| **Tempo** | Traces | Receives distributed traces over OTLP (gRPC/HTTP) from your applications and stores them. |
| **Grafana** | UI | Single pane of glass: dashboards + Explore over Prometheus, Loki and Tempo, with trace↔log↔metric correlation. |
| **Dozzle** | Logs (live) | Lightweight real-time Docker log viewer (no storage) for quick tailing. |

Everything is pre-wired: datasources and dashboards are provisioned automatically, and the three datasources are cross-linked (a trace in Tempo links to its logs in Loki and its service metrics in Prometheus).

## Services & URLs

| Service | Local | Prod |
|---------|-------|------|
| **Grafana** | `grafana.local.barlito.fr` | `grafana.barlito.fr` |
| **Prometheus** | `prometheus.local.barlito.fr` | `prometheus.barlito.fr` |
| **Dozzle** | `dozzle.local.barlito.fr` | `dozzle.barlito.fr` |
| **Alloy** (debug UI) | `alloy.local.barlito.fr` | `alloy.barlito.fr` |
| **Loki** | Internal only (overlay) | Internal only (overlay) |
| **Tempo** | Internal — OTLP `4317`/`4318` | Internal — OTLP `4317`/`4318` |
| **node-exporter** | Internal (metrics only) | Internal (metrics only) |
| **cAdvisor** | Internal (metrics only) | Internal (metrics only) |

A `log-generator` service is included in local only, to exercise the Loki pipeline.

## Provisioned dashboards

Grafana loads these on startup (`grafana/dashboards/`, no manual import):

| Dashboard | Covers |
|-----------|--------|
| Node Exporter Full | Host CPU / RAM / disk / network |
| cAdvisor | Per-container resource usage |
| Prometheus Overview | Prometheus itself |
| Loki Logs | Log explorer (filter by `service_name`) |
| Traefik | Ingress traffic, latencies, status codes |

> **WSL note:** the cAdvisor dashboard stays empty on WSL2 — its cgroup v1 layout doesn't expose per-container cgroups to cAdvisor. It works on a real Linux server (prod).

## Prerequisites

- Docker with Swarm mode enabled (`docker swarm init`)
- [traefik-base](https://github.com/barlito/traefik-base) stack running with the `traefik_traefik_proxy` network and Authelia

## Setup

```bash
make deploy          # Local
make deploy.prod     # Production
```

No `.env` file needed — authentication is handled by Authelia via Traefik forwardAuth. Grafana uses auth proxy mode (auto-login from the Authelia session).

### CI deploy (production)

`.github/workflows/deploy.yml` deploys to the prod Swarm over SSH (`docker stack deploy` via `DOCKER_HOST=ssh://…`). Trigger it manually from the Actions tab (**workflow_dispatch**); tick `undeploy` for a clean redeploy. No app secrets are needed (auth is Authelia's job) — only the connection to the server:

| Kind | Name | Example |
|------|------|---------|
| Variable | `SERVER_USERNAME` | `barlito` |
| Variable | `SERVER_HOST` | `barlito.fr` |
| Variable | `SERVER_PORT` | `22` |
| Secret | `SSH_PRIVATE_KEY` | deploy key with access to the Swarm manager |

Deploy [traefik-base](https://github.com/barlito/traefik-base) **first** — this stack depends on its external `traefik_traefik_proxy` network and Authelia.

### How configs are shipped (local vs prod)

| | Local | Prod |
|---|-------|------|
| Mechanism | **Bind mounts** (`./prometheus`, `./grafana/…`) | **Swarm configs** |
| Where the files live | The repo on your machine | Inside Swarm (raft store) — **nothing on the server disk** |
| Editing | Edit the file, redeploy (live) | Edit the file, redeploy (content re-shipped) |

Prod uses Swarm `configs:` so the CI can deploy over SSH without the repo being present on the server. Config **names are versioned** with `CONFIG_VERSION` — a hash of all config files computed by `make deploy.prod`:

```makefile
export CONFIG_VERSION=$(cat prometheus/*.yml loki/*.yml … grafana/dashboards/*.json | sha1sum | cut -c1-10)
```

Any change to a config file produces new config objects (`obs_prometheus_cfg_<hash>`, …), so Swarm performs a **rolling update** instead of failing with `only updates to Labels are allowed` (Docker configs are immutable). Old config objects are left behind harmlessly and can be pruned with `docker config rm` / `docker config prune` if desired.

> Adding a dashboard in prod = drop the JSON in `grafana/dashboards/`, add a `configs:` entry (source + target) on the Grafana service and in the top-level `configs:` block, then redeploy.

## Networks

| Network | Scope | Members |
|---------|-------|---------|
| `obs_internal` | **Private** to the stack | Prometheus, Grafana, Loki, Tempo, exporters. Not reachable from app stacks. |
| `obs_ingest` | **Shared** with app stacks | **Tempo only.** Apps join this network to push traces and can reach nothing else in the stack. |
| `traefik_traefik_proxy` | External (traefik-base) | Services exposed through Traefik. |

The split means an application stack that emits traces gets access to Tempo **and nothing else** — Prometheus, Grafana and Loki remain invisible to it.

### Auth

| Service | Auth method |
|---------|-------------|
| Grafana | Authelia forwardAuth + auth proxy (auto-login as server admin) |
| Prometheus | Authelia forwardAuth |
| Dozzle | Authelia forwardAuth + forward-proxy (auto-login) |
| Alloy (debug UI) | Authelia forwardAuth |
| Loki / Tempo | Not exposed (internal only) |

Grafana's built-in admin account is renamed to the Authelia username (`GF_SECURITY_ADMIN_USER`), so the auth proxy login lands directly on the server admin account. Note: this only applies on first init — if `grafana_data` already exists with an `admin` user, reset the volume or rename the user via the API.

## Logs (Alloy → Loki)

Alloy runs as a global service (one agent per node), discovers every container through the Docker socket and streams their stdout/stderr to Loki — no logging driver, no plugin, no per-stack `logging:` config needed. Containers stay on the default `json-file` driver, so `docker logs` and Dozzle keep working.

The Alloy debug UI (live pipeline graph, discovered targets, component health) is exposed at `alloy.{local.}barlito.fr` behind Authelia.

Available Loki labels:

| Label | Example |
|-------|---------|
| `service_name` | `obs_grafana` |
| `container` | `obs_grafana.1.xyz` |
| `service` | `obs_grafana` |
| `stack` | `obs` |

## Metrics from your apps

Prometheus already scrapes itself, node-exporter, cAdvisor and Traefik (see `prometheus/prometheus.yml`). To scrape one of your applications, expose a `/metrics` endpoint and add a scrape job pointing at its service DNS name (the app must share a network Prometheus can reach).

## Sending traces to Tempo

Applications push traces via OpenTelemetry (OTLP) to Tempo:

- **HTTP**: `http://tempo:4318` (recommended — no gRPC dependency)
- **gRPC**: `http://tempo:4317`

To reach `tempo`, the application stack must join the shared `obs_ingest` network (it exposes Tempo and nothing else). In each app's compose:

```yaml
services:
  php:
    networks:
      - carapp_internal        # the app's own private network
      - obs_ingest             # gives access to Tempo only
networks:
  carapp_internal:
  obs_ingest:
    name: observability-stack_obs_ingest
    external: true
```

### PHP / Symfony

Instrument with OpenTelemetry (auto-instrumentation, no code changes):

```bash
pecl install opentelemetry        # PHP extension, then enable extension=opentelemetry.so
composer require \
  open-telemetry/sdk \
  open-telemetry/exporter-otlp \
  open-telemetry/opentelemetry-auto-symfony \
  open-telemetry/opentelemetry-auto-psr18      # traces outgoing HttpClient
# optional: -auto-doctrine (SQL), -auto-psr3 (correlate logs with traces)
```

Configure entirely via environment variables:

```env
OTEL_PHP_AUTOLOAD_ENABLED=true
OTEL_SERVICE_NAME=carapp                       # name shown in Tempo
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4318
OTEL_PROPAGATORS=tracecontext,baggage
```

### Quick test

Generate a few traces from any host on the `obs_ingest` network:

```bash
docker run --rm --network observability-stack_obs_ingest \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-endpoint tempo:4318 --otlp-http --traces 10 --service test-tempo
```

Then in Grafana → Explore → Tempo → Search, filter by service name `test-tempo`.

## Security notes

- Every Docker socket mount (Alloy, Dozzle, cAdvisor) is read-only, and cAdvisor mounts only `/var/run/docker.sock` rather than the whole `/var/run`.
- ⚠️ A read-only socket mount still exposes the **full** Docker API to the container. Hardening these behind a scoped `docker-socket-proxy` (read-only, whitelisted endpoints) is tracked as a separate phase.

## Commands

```bash
make deploy                  # Deploy (local)
make deploy.prod             # Deploy (production)
make undeploy                # Remove the stack
make restart                 # Redeploy (local)
make restart.prod            # Redeploy (production)
make logs service=grafana    # Follow logs for a service
```

## Data retention

- **Prometheus**: 30 days
- **Loki**: 30 days (compactor purges expired chunks)
</content>
</invoke>

# Observability Stack

Self-hosted monitoring stack running on Docker Swarm behind Traefik.

## At a glance

The stack gives you the three pillars of observability — **metrics**, **logs** and **traces** — plus host/container resource monitoring, all in one Grafana:

| Service | Pillar | What it does |
|---------|--------|--------------|
| **Prometheus** | Metrics | Stores time-series metrics (30-day retention), fed by Alloy remote write. Source of truth for all metric queries. |
| **node-exporter** | Metrics | Exposes **host** metrics (CPU, RAM, disk, network) — one agent per Swarm node. |
| **cAdvisor** | Metrics | Exposes **per-container** metrics (CPU, RAM, net, fs) from the Docker engine — one agent per node. |
| **Loki** | Logs | Stores and indexes logs (30-day retention). Queried from Grafana. |
| **Alloy** | Logs, metrics, traces | Edge agent, one per node: ships container logs to Loki (with redaction), scrapes node-exporter / cAdvisor / Traefik into Prometheus by remote write, and is the OTLP entry point for traces. |
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
| **Tempo** | Internal (overlay) | Internal (overlay) |
| **OTLP entry point** | `otlp:4317` / `otlp:4318` on `obs_ingest` (Alloy) | same |
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
| `obs_internal` | **Private** to the stack | Prometheus, Grafana, Loki, Tempo, Alloy, exporters. Not reachable from app stacks. |
| `obs_ingest` | **Shared** with app stacks | **Alloy only**, aliased `otlp`. Apps join it to push traces and reach nothing else. Real name: `obs_obs_ingest` (stack `obs` prefix). |
| `obs_query` | **Shared** with ops-mcp | **Loki, Prometheus, Tempo only.** Fixed name `obs_query`; ops-mcp joins it as an external network to query them. |
| `traefik_traefik_proxy` | External (traefik-base) | Services exposed through Traefik. |

An application stack that emits traces reaches Alloy **and nothing else**. Tempo is no longer on `obs_ingest`: Alloy is the only entry point.

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

### Canonical labels

Every log line and metric series carries the same labels, set by Alloy (`alloy/edge.alloy`):

| Loki / Prometheus label | OTel resource attribute | Source | Example |
|---|---|---|---|
| `server` | `server.name` | env `SERVER_NAME` | `ovh-prod-1` |
| `deployment_environment` | `deployment.environment.name` | env `DEPLOY_ENV` | `production` |
| `host_name` | `host.name` | Swarm `{{.Node.Hostname}}` | `ns3124613` |
| `service_namespace` | `service.namespace` | `com.docker.stack.namespace`, else `com.docker.compose.project` | `carapp` |
| `service_name` | `service.name` | full Swarm service name, else `<compose project>_<compose service>` | `carapp_php` |
| `container` | `container.name` | container name | `carapp_php.1.xyz` |

Local values are `local` / `development` (override through `.env`, see `.env.example`); prod values are set in `docker-compose-prod.yml`. Logs also keep the legacy `stack` and `service` labels (Swarm only) until nothing uses them anymore. Traefik services must be named after the Swarm service so HTTP metrics join with `service_name`.

Caveat: Loki normalises OTLP attribute names, so `deployment.environment.name` becomes `deployment_environment_name` on logs sent over OTLP; Docker logs use `deployment_environment`.

### Redaction

`loki.process` masks secrets with `***` before anything is written to Loki: the password of `scheme://user:pass@host` DSNs, `Bearer <token>`, `password=` / `passwd=` / `pwd=` pairs (also `"password": "..."`) and JWTs (`eyJ...`). Redaction happens at ingestion: existing data is not rewritten, and Dozzle (live, no storage) shows raw lines.

### Traefik access logs (file source)

Traefik writes its **access log** to a file (`/var/log/traefik/access.log`, JSON, one object per request) instead of stdout, so the Docker source above no longer sees it. Alloy tails that file via a `loki.source.file` and ships it to the same Loki endpoint. Traefik's *application* log stays on stdout and is still collected through the Docker source.

This requires the host path `/var/log/traefik` to be bind-mounted read-only into the Alloy container (`/var/log/traefik:/var/log/traefik:ro`, wired in the prod compose file). Since Alloy is a **global** service, every node that runs Traefik must expose that directory.

Access-log lines carry `job="traefik-access"`, `service_namespace="traefik"`, `service_name="traefik_traefik"` (plus the legacy `service`/`stack`) and go through the same redaction. The mount exists in prod only: local Traefik has no access log file. The payload is JSON, so parse fields at query time in Grafana, e.g. `{job="traefik-access"} | json | DownstreamStatus >= 500`.

## Metrics from your apps

Prometheus scrapes only itself. Alloy scrapes node-exporter, cAdvisor, Traefik and itself, then pushes to Prometheus by remote write (`PROM_RW_URL`) with the canonical labels, `server` and `deployment_environment` as `external_labels`, and a disk WAL that buffers 8h if Prometheus is down. cAdvisor only exports the four whitelisted Docker labels. To scrape one of your applications, add a `prometheus.scrape` block in `alloy/edge.alloy` pointing at its service DNS name (the app must share a network with Alloy).

## Sending traces

Applications push traces via OpenTelemetry (OTLP) to Alloy, which adds `server.name`, `deployment.environment.name` and `host.name` and forwards to Tempo:

- **HTTP**: `http://otlp:4318` (recommended — no gRPC dependency)
- **gRPC**: `http://otlp:4317`

The application stack must join the shared `obs_ingest` network (it exposes Alloy as `otlp` and nothing else). In each app's compose:

```yaml
services:
  php:
    networks:
      - carapp_internal        # the app's own private network
      - obs_ingest             # gives access to the OTLP entry point only
networks:
  carapp_internal:
  obs_ingest:
    name: obs_obs_ingest
    external: true
```

Tempo generates service-graph and span metrics (`traces_spanmetrics_*`) into Prometheus and keeps traces for 7 days. No stack in the sibling repos sends OTLP to `tempo:` today.

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
OTEL_EXPORTER_OTLP_ENDPOINT=http://otlp:4318
OTEL_PROPAGATORS=tracecontext,baggage
```

### Quick test

Generate a few traces from any host on the `obs_ingest` network:

```bash
docker run --rm --network obs_obs_ingest \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-endpoint otlp:4318 --otlp-http --traces 10 --service test-tempo
```

Then in Grafana → Explore → Tempo → Search, filter by service name `test-tempo`.

## Security notes

- Alloy and Dozzle reach the Docker API through the read-only `docker-socket-proxy` (containers, networks, events, info; no writes). cAdvisor keeps a direct read-only socket mount, the one documented exception.
- Loki, Prometheus and Tempo are only reachable from `obs_internal` and `obs_query`; apps only see the OTLP entry point.
- Secrets in logs are masked at ingestion (see Redaction).

## Commands

```bash
make deploy                  # Deploy (local)
make deploy.prod             # Deploy (production)
make undeploy                # Remove the stack
make restart                 # Redeploy (local)
make restart.prod            # Redeploy (production)
make logs service=grafana    # Follow logs for a service
make validate                # Lint configs and compose files (Docker only)
make smoke                   # End-to-end check in an isolated `obs-smoke` compose project
```

## Data retention

- **Prometheus**: 30 days
- **Loki**: 30 days (compactor purges expired chunks)
- **Tempo**: 7 days

Image tags are pinned on the minor and patches float, except where upstream publishes no minor tag (Prometheus, Tempo, Alloy, node-exporter, cAdvisor, docker-socket-proxy): those use an exact patch tag, bumped by hand.

## Rollback

Redeploy the previous master sha: `git checkout <sha> && make deploy.prod`, or run the deploy workflow on that ref. Volumes are untouched. After a rollback Prometheus scrapes again and series lose the remote-write labels (`server`, `service_name`, ...); the legacy `stack`/`service` log labels are kept in both directions. Detect a failure fast with `up` in Grafana, the provisioned dashboards, and Loki ingestion (`sum(rate({server="ovh-prod-1"}[1m]))`).

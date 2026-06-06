# Observability Stack

Self-hosted monitoring stack running on Docker Swarm behind Traefik.

## Services

| Service | Role | Local | Prod |
|---------|------|-------|------|
| **Prometheus** | Metrics collection & storage | `prometheus.local.barlito.fr` | `prometheus.barlito.fr` |
| **Grafana** | Dashboards (metrics, logs, traces) | `grafana.local.barlito.fr` | `grafana.barlito.fr` |
| **Loki** | Log aggregation | Internal (overlay only) | Internal (overlay only) |
| **Alloy** | Log collection (Docker discovery, one agent per node) | Internal | Internal |
| **Tempo** | Distributed tracing (OTel receiver) | Internal (port 4317/4318) | Internal (port 4317/4318) |
| **Dozzle** | Real-time Docker log viewer | `dozzle.local.barlito.fr` | `dozzle.barlito.fr` |
| **Beszel** | Server & container monitoring | `beszel.local.barlito.fr` | `beszel.barlito.fr` |

A `log-generator` service is included in local for testing the Loki pipeline.

## Prerequisites

- Docker with Swarm mode enabled (`docker swarm init`)
- [traefik-base](https://github.com/barlito/traefik-base) stack running with `traefik_traefik_proxy` network and Authelia

## Setup

```bash
make deploy          # Local
make deploy.prod     # Production
```

No `.env` file needed — authentication is handled by Authelia via Traefik forwardAuth. Grafana uses auth proxy mode (auto-login from Authelia session).

### Auth

| Service | Auth method |
|---------|-------------|
| Prometheus | Authelia forwardAuth |
| Grafana | Authelia forwardAuth + auth proxy (auto-login as server admin) |
| Dozzle | Authelia forwardAuth + forward-proxy (auto-login) |
| Beszel | Own auth (PocketBase) |
| Loki | Not exposed (internal only) |
| Tempo | Not exposed (internal only) |

Grafana's built-in admin account is renamed to the Authelia username (`GF_SECURITY_ADMIN_USER`), so the auth proxy login lands directly on the server admin account. Note: this only applies on first init — if `grafana_data` already exists with an `admin` user, reset the volume or rename the user via the API.

### Beszel agent

The Beszel agent runs standalone with `--network host` (not inside the Swarm stack) to get full system metrics.

1. Open the Beszel hub and create an account
2. Click **Add system** — Beszel generates a `docker run` command with the KEY and TOKEN
3. Run the generated command, replacing `HUB_URL` with the Traefik URL:

```bash
docker run -d \
  --name beszel-agent \
  --network host \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v beszel_agent_data:/var/lib/beszel-agent \
  -e KEY="ssh-ed25519 AAAA..." \
  -e LISTEN=45876 \
  -e TOKEN="<token>" \
  -e HUB_URL="https://beszel.barlito.fr" \
  henrygd/beszel-agent
```

### Logs (Alloy → Loki)

Alloy runs as a global service (one agent per node), discovers every container through the Docker socket and streams their stdout/stderr to Loki — no logging driver, no plugin, no per-stack `logging:` config needed. Containers stay on the default `json-file` driver, so `docker logs` and Dozzle keep working.

Available Loki labels:

| Label | Example |
|-------|---------|
| `container` | `obs_grafana.1.xyz` |
| `service` | `obs_grafana` |
| `stack` | `obs` |

> Migration note: the old `grafana/loki-docker-driver` plugin is no longer needed. Remove `logging:` blocks from other stacks, redeploy them, then `docker plugin disable loki && docker plugin rm loki`.

### Sending traces to Tempo

Applications send traces via OpenTelemetry to Tempo on the Docker overlay network:

- **gRPC**: `http://tempo:4317`
- **HTTP**: `http://tempo:4318`

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

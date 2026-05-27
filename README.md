# Observability Stack

Self-hosted monitoring stack running on Docker Swarm behind Traefik.

## Services

| Service | Role | Local | Prod |
|---------|------|-------|------|
| **Prometheus** | Metrics collection & storage | `prometheus.local.barlito.fr` | `prometheus.barlito.fr` |
| **Grafana** | Dashboards (metrics, logs, traces) | `grafana.local.barlito.fr` | `grafana.barlito.fr` |
| **Loki** | Log aggregation (Docker log driver) | `localhost:3100` | `127.0.0.1:3100` |
| **Tempo** | Distributed tracing (OTel receiver) | Internal (port 4317/4318) | Internal (port 4317/4318) |
| **Dozzle** | Real-time Docker log viewer | `dozzle.local.barlito.fr` | `dozzle.barlito.fr` |
| **Beszel** | Server & container monitoring | `beszel.local.barlito.fr` | `beszel.barlito.fr` |

A `log-generator` service is included in local for testing the Loki pipeline.

## Prerequisites

- Docker with Swarm mode enabled (`docker swarm init`)
- [traefik-base](https://github.com/barlito/traefik-base) stack running with `traefik_traefik_proxy` network and Authelia
- Loki Docker log driver plugin: `docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions`

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
| Grafana | Authelia forwardAuth + auth proxy (auto-login) |
| Dozzle | Authelia forwardAuth |
| Beszel | Own auth (PocketBase) |
| Loki | Not exposed (localhost only) |
| Tempo | Not exposed (internal only) |

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
  -e HUB_URL="http://beszel.barlito.fr" \
  henrygd/beszel-agent
```

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

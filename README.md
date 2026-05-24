# Observability Stack

Self-hosted monitoring stack running on Docker Swarm behind Traefik.

## Services

| Service | Role | Local | Prod |
|---------|------|-------|------|
| **Prometheus** | Metrics collection & storage | `prometheus.local.barlito.fr` | `prometheus.barlito.fr` |
| **Grafana** | Metrics dashboards | `grafana.local.barlito.fr` | `grafana.barlito.fr` |
| **Loki** | Log aggregation (Docker log driver) | `localhost:3100` | `127.0.0.1:3100` |
| **Dozzle** | Real-time Docker log viewer | `dozzle.local.barlito.fr` | `dozzle.barlito.fr` |
| **Beszel** | Server & container monitoring | `beszel.local.barlito.fr` | `beszel.barlito.fr` |

A `log-generator` service is included in local for testing the Loki pipeline.

## Prerequisites

- Docker with Swarm mode enabled (`docker swarm init`)
- [traefik-base](https://github.com/barlito/traefik-base) stack running with `traefik_traefik_proxy` network
- Loki Docker log driver plugin: `docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions`

## Local setup

```bash
cp .env.example .env
# Edit .env with your credentials
make deploy
```

## Production setup

```bash
cp .env.example .env
# Set strong GRAFANA_ADMIN_PASSWORD
# Generate OBS_BASIC_AUTH: echo "$(htpasswd -nB user)" | sed -e s/\\$/\\$\\$/g
make deploy.prod
```

### Security (prod)

- **HTTPS enforced** with Let's Encrypt via Traefik
- **Prometheus & Dozzle** protected by HTTP Basic Auth (`OBS_BASIC_AUTH`)
- **Beszel** has its own auth (PocketBase)
- **Grafana** has its own auth (sign-up disabled, secure cookies)
- **Loki** bound to `127.0.0.1` only (not exposed externally)
- **Security headers** applied via Traefik middleware

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

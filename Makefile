stack_name=obs
smoke_project=obs-smoke
compose_smoke=docker compose -p $(smoke_project) -f docker-compose.smoke.yml

# Image of a service, read from the compose file so tags are defined once.
image=$$(docker compose -f docker-compose.yaml config --images 2>/dev/null | grep '$(1)')

.PHONY: deploy
deploy:
	docker compose pull || true
	docker compose config | sed '/^name:/d; s/published: "\([0-9]*\)"/published: \1/g' | docker stack deploy -c - $(stack_name)

.PHONY: undeploy
undeploy:
	docker stack rm $(stack_name)

.PHONY: restart
restart:
	$(MAKE) undeploy
	sleep 5
	$(MAKE) deploy

.PHONY: deploy.prod
# CONFIG_VERSION = hash of every config file, injected into the Swarm config
# names so a content change rolls out cleanly (see docker-compose-prod.yml).
deploy.prod:
	docker compose -f docker-compose-prod.yml pull
	export CONFIG_VERSION=$$(cat prometheus/prometheus.yml loki/loki.yml tempo/tempo.yml alloy/edge.alloy grafana/provisioning/datasources/datasources.yml grafana/provisioning/dashboards/dashboards.yml grafana/dashboards/*.json | sha1sum | cut -c1-10) && \
	docker compose -f docker-compose-prod.yml config | sed '/^name:/d; s/published: "\([0-9]*\)"/published: \1/g' | docker stack deploy -c - $(stack_name)

.PHONY: restart.prod
restart.prod:
	$(MAKE) undeploy
	sleep 5
	$(MAKE) deploy.prod

.PHONY: logs
logs:
	docker service logs -f $(stack_name)_$(service)

.PHONY: validate
validate:
	@set -e; \
	for f in docker-compose.yaml docker-compose-prod.yml; do \
		out=$$(docker compose -f $$f config -q 2>&1) || { echo "$$out"; exit 1; }; \
	done; \
	docker run --rm -v $(CURDIR)/alloy:/alloy $(call image,grafana/alloy) fmt /alloy/edge.alloy | diff -u alloy/edge.alloy -; \
	docker run --rm -e SERVER_NAME=x -e DEPLOY_ENV=x -e HOST_NAME=x -e LOKI_URL=http://x -e PROM_RW_URL=http://x -e OTLP_URL=x:4317 \
		-v $(CURDIR)/alloy:/alloy $(call image,grafana/alloy) validate /alloy/edge.alloy; \
	docker run --rm --entrypoint promtool -v $(CURDIR)/prometheus:/prometheus $(call image,prom/prometheus) check config /prometheus/prometheus.yml; \
	docker run --rm -v $(CURDIR)/loki:/etc/loki $(call image,grafana/loki) -config.file=/etc/loki/loki.yml -verify-config; \
	docker run --rm -v $(CURDIR)/tempo:/etc/tempo $(call image,grafana/tempo) -config.file=/etc/tempo/tempo.yml -config.verify=true; \
	echo "validate: OK"

.PHONY: smoke
smoke:
	@$(compose_smoke) up -d --quiet-pull 2>&1 | grep -v 'level=warning'; \
	$(compose_smoke) run --rm tester; rc=$$?; \
	if [ $$rc -ne 0 ]; then $(compose_smoke) logs --tail 40 alloy loki tempo; fi; \
	$(compose_smoke) --profile test down --volumes 2>&1 | grep -v 'level=warning'; \
	exit $$rc

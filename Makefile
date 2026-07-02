stack_name=obs

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
	export CONFIG_VERSION=$$(cat prometheus/prometheus.yml loki/loki.yml tempo/tempo.yml alloy/config.alloy grafana/provisioning/datasources/datasources.yml grafana/provisioning/dashboards/dashboards.yml grafana/dashboards/*.json | sha1sum | cut -c1-10) && \
	docker compose -f docker-compose-prod.yml config | sed '/^name:/d; s/published: "\([0-9]*\)"/published: \1/g' | docker stack deploy -c - $(stack_name)

.PHONY: restart.prod
restart.prod:
	$(MAKE) undeploy
	sleep 5
	$(MAKE) deploy.prod

.PHONY: logs
logs:
	docker service logs -f $(stack_name)_$(service)

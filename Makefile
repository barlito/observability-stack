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
deploy.prod:
	docker compose -f docker-compose-prod.yml pull
	docker compose -f docker-compose-prod.yml config | sed '/^name:/d; s/published: "\([0-9]*\)"/published: \1/g' | docker stack deploy -c - $(stack_name)

.PHONY: restart.prod
restart.prod:
	$(MAKE) undeploy
	sleep 5
	$(MAKE) deploy.prod

.PHONY: logs
logs:
	docker service logs -f $(stack_name)_$(service)

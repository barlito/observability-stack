#!/bin/sh
set -eu
apk add --no-cache -q curl jq

fail() { echo "FAIL: $1"; exit 1; }

# retry <description> <command...>: up to 90s
retry() {
	desc=$1; shift
	for _ in $(seq 1 45); do
		if "$@" >/dev/null 2>&1; then echo "PASS: $desc"; return 0; fi
		sleep 2
	done
	fail "$desc"
}

now=$(date +%s)
loki() { curl -sfG http://loki:3100/loki/api/v1/query_range --data-urlencode "query=$1" --data-urlencode "start=$((now - 600))000000000" --data-urlencode "limit=100"; }
prom() { curl -sfG http://prometheus:9090/api/v1/query --data-urlencode "query=$1"; }

wait_ready() {
	for _ in $(seq 1 60); do
		curl -sf http://loki:3100/ready >/dev/null && curl -sf http://prometheus:9090/-/ready >/dev/null && curl -sf http://tempo:3200/ready >/dev/null && return 0
		sleep 2
	done
	fail "backends ready"
}
wait_ready

trace_id=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
span_id=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
t0=$(date +%s)
send_trace() {
	curl -sf -X POST http://otlp:4318/v1/traces -H 'Content-Type: application/json' -d "{
	\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"smoke-app\"}}]},
	\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$trace_id\",\"spanId\":\"$span_id\",\"name\":\"GET /smoke\",\"kind\":2,
	\"startTimeUnixNano\":\"${t0}000000000\",\"endTimeUnixNano\":\"$((t0 + 1))000000000\"}]}]}]}"
}
retry "OTLP trace accepted on otlp:4318" send_trace

logs_ok() {
	loki '{server="local",service_namespace="obs-smoke",service_name="obs-smoke_log-emitter"}' \
		| jq -e '.data.result | length > 0'
}
retry "Loki has logs with server/service_namespace/service_name" logs_ok

lines=$(loki '{service_name="obs-smoke_log-emitter"}' | jq -r '.data.result[].values[][1]')
for secret in S3cretPw abcdef0123456789token hunter2hunter2 c2lnbmF0dXJl; do
	echo "$lines" | grep -q "$secret" && fail "secret $secret not redacted"
done
echo "$lines" | grep -q 'postgres://app:\*\*\*@db' || fail "DSN redaction keeps scheme and user"
echo "$lines" | grep -q 'plain line without secrets' || fail "plain line untouched"
echo "PASS: secrets redacted (DSN, bearer, password=, JWT)"

# prom_has <query>: the instant query returns at least one series
prom_has() { prom "$1" | jq -e '.data.result | length > 0'; }

retry "Prometheus up{server=local,job=node-exporter} = 1" prom_has 'up{server="local",deployment_environment="development",host_name="smoke-host",job="node-exporter"} == 1'
retry "Prometheus up{server=local,job=integrations/self} = 1" prom_has 'up{server="local",job="integrations/self"} == 1'
retry "cAdvisor swarm labels mapped to canonical labels" \
	prom_has 'container_memory_working_set_bytes{server="local",service_namespace="carapp",service_name="carapp_php",container="carapp_php.1.abc"}'
retry "cAdvisor compose labels mapped to canonical labels" \
	prom_has 'container_memory_working_set_bytes{server="local",service_namespace="proj",service_name="proj_web"}'

tempo_has_trace() {
	curl -sf "http://tempo:3200/api/traces/$trace_id" \
		| jq -e '[.. | .stringValue? // empty] | index("local") != null and index("smoke-host") != null'
}
retry "Tempo returns the trace with server.name and host.name added by Alloy" tempo_has_trace

retry "Tempo span metrics reach Prometheus" prom_has 'traces_spanmetrics_calls_total{service="smoke-app"}'

echo "ALL SMOKE CHECKS PASSED"

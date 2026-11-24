# shellcheck shell=bash disable=SC2154 # real is set by assert.sh, which sources this file
# The OpenTelemetry Collector checks. Sourced by assert.sh, after the requests whose
# counts they check; uses its check, via, no_connection and real. What the Collector
# exports is read from the test backend's stdout.

via sandbox-labelled "http://otel-collector.observability.svc.cluster.local:4318/v1/logs" --noproxy '*'
check "labelled sandbox cannot reach the OpenTelemetry Collector" no_connection
collector_refused() { # exit 3 only when the connection itself times out or is refused
  local rc=0
  kubectl -n upstream exec deploy/echo -- python3 -c 'import socket, sys
try: socket.create_connection(("otel-collector.observability.svc.cluster.local", 4318), timeout=5)
except (TimeoutError, ConnectionRefusedError): sys.exit(3)' || rc=$?
  (( rc == 3 ))
}
check "a pod with open egress, not an iron-proxy pod, cannot reach the Collector" collector_refused
# wget exits non-zero on the 400 that Go's TLS server sends a plain HTTP request.
plain_http_refused() {
  local out
  out="$(kubectl -n ws-demo exec deploy/proxy-env-demo -c iron-proxy -- \
    wget -q -O /dev/null http://otel-collector.observability:4318/v1/logs 2>&1)" && return 1
  grep -q '400 Bad Request' <<<"$out"
}
check "the Collector refuses plain HTTP from the proxy (TLS only)" plain_http_refused

log "the Collector counts the requests above from the proxy's OTLP audit records"
collector_out() { kubectl -n otel-backend logs deploy/otel-backend | grep '^{"resource' || true; }
# counts <metric>: the metric's total per label set, as {"action=..,rejected_by=..,swapped=..": n}.
counts() {
  collector_out | jq -sc --arg m "$1" '[.[].resourceMetrics[]?.scopeMetrics[].metrics[]
      | select(.name == $m) | .sum.dataPoints[]
      | {k: ([.attributes[]? | "\(.key)=\(.value | to_entries[0].value)"] | sort | join(",")),
         v: (.asInt | tonumber)}]
    | group_by(.k) | map({(.[0].k): (map(.v) | add)}) | add // {}'
}
# One swap on api.upstream.test; other.upstream.test, plain HTTP to api.upstream.test and
# missing.upstream.test; blocked.upstream.test and both requests to 169.254.169.254; metadata.demo.test's refused dial.
# Allowed CONNECTs are not counted.
want_requests='{
  "action=allow,rejected_by=none,swapped=true": 1,
  "action=allow,rejected_by=none,swapped=false": 3,
  "action=reject,rejected_by=allowlist,swapped=false": 3,
  "action=error,rejected_by=none,swapped=false": 1}'
requests_counted() { REQUESTS="$(counts egress_proxy_requests)"; jq -e --argjson w "$want_requests" '. == $w' <<<"$REQUESTS" >/dev/null; }
check "egress_proxy_requests matches the requests made (within 60 s)" retry 20 3 requests_counted
log "egress_proxy_requests: ${REQUESTS:-none}"
check "egress_proxy_secret_failures counted missing.upstream once" \
  test "$(counts egress_proxy_secret_failures)" = '{"":1}'
logs_carry_ids() {
  collector_out | jq -se '[.[].resourceLogs[]? | .resource.attributes
      | map({(.key): (.value | to_entries[0].value)}) | add
      | .["agentd.workspace_id"] == "wrk_Demo01" and .["agentd.environment_id"] == "env_Demo01"]
    | length > 0 and all' >/dev/null
}
check "log records carry the workspace and environment ids" logs_carry_ids
metrics_lack_ids() {
  collector_out | jq -se '[.[].resourceMetrics[]? | .. | objects | .key? // empty
      | select(. == "agentd.workspace_id" or . == "agentd.environment_id")] | length == 0' >/dev/null
}
check "no workspace or environment id on the metrics" metrics_lack_ids
no_credential_exported() {
  ! { kubectl -n observability logs -l app=otel-collector --tail=-1
    kubectl -n otel-backend logs deploy/otel-backend; } | grep -qF -- "$real"
}
check "the credential value never reaches the Collector or its backend" no_credential_exported

# shellcheck shell=bash disable=SC2154 # PROXY_PODS, real and work are set by assert.sh, which sources this file
# The OpenTelemetry Collector checks. Sourced by assert.sh, after the requests whose
# counts they check; uses its check, via, no_connection, real and work. What the Collector
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
check "the echo pod, allowed out to the Collector port but not an iron-proxy pod, cannot reach the Collector" collector_refused
# wget exits non-zero on the 400 that Go's TLS server sends a plain HTTP request.
plain_http_refused() {
  local out
  out="$(kubectl -n ws-demo exec deploy/proxy-env-demo -c iron-proxy -- \
    wget -q -O /dev/null http://otel-collector.observability:4318/v1/logs 2>&1)" && return 1
  grep -q '400 Bad Request' <<<"$out"
}
check "the Collector refuses plain HTTP from the proxy (TLS only)" plain_http_refused

log "the proxies trust the Collector CA for OTLP, never the agentd root"
pem_of_secret() { kubectl -n "$1" get secret "$2" -o jsonpath='{.data.tls\.crt}' | base64 -d >"${work}/$3"; }
pem_of_secret observability agentd-otel-ca otlp-ca.crt
pem_of_secret observability otel-collector-tls otlp-server.crt
pem_of_secret ws-demo iron-proxy-ca otlp-intermediate.crt
kubectl -n sandboxes get configmap agentd-root-ca -o jsonpath='{.data.ca\.crt}' >"${work}/otlp-root.crt"
kubectl -n ws-demo get configmap otel-ca -o jsonpath='{.data.ca\.crt}' >"${work}/otlp-trusted.crt"
# not_signed_by <ca> <cert>: both parse as certificates, and the cert does not chain to the CA.
not_signed_by() {
  openssl x509 -noout -in "${work}/$1" && openssl x509 -noout -in "${work}/$2" \
    && ! openssl verify -CAfile "${work}/$1" "${work}/$2" >/dev/null 2>&1
}
check "the Collector's certificate chains to the Collector CA" \
  openssl verify -CAfile "${work}/otlp-ca.crt" "${work}/otlp-server.crt"
check "the Collector's certificate does not chain to the agentd root" not_signed_by otlp-root.crt otlp-server.crt
fingerprint() { openssl x509 -noout -fingerprint -sha256 -in "${work}/$1"; }
# openssl reads only a file's first certificate, so <trusted> must hold exactly one.
only_cert_is() { # <ca> <trusted>
  [[ $(grep -c -- '-----BEGIN CERTIFICATE-----' "${work}/$2") == 1 ]] \
    && [[ -n $(fingerprint "$1") && $(fingerprint "$1") == "$(fingerprint "$2")" ]]
}
check "the proxies' OTLP trust (ConfigMap otel-ca) is the Collector CA alone" only_cert_is otlp-ca.crt otlp-trusted.crt
check "control: the workspace intermediate chains to the agentd root" \
  openssl verify -CAfile "${work}/otlp-root.crt" "${work}/otlp-intermediate.crt"
check "nothing the workspace intermediate signs chains to the proxies' OTLP trust" \
  not_signed_by otlp-trusted.crt otlp-intermediate.crt

log "the Collector counts the requests above from the proxy's OTLP audit records"
# Fails when the backend's log cannot be read, so no check passes on empty input.
collector_out() {
  local out
  out="$(kubectl -n otel-backend logs deploy/otel-backend)" || return 1
  grep '^{"resource' <<<"$out" || true
}
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
# The namespace and pod names carry the workspace id too, so no k8s.* key either.
metrics_lack_ids() {
  collector_out | jq -se '[.[].resourceMetrics[]?] as $m | ($m | length > 0)
    and ([$m[] | .. | objects | .key? // empty | strings
      | select(startswith("agentd.") or startswith("k8s."))] | length == 0)' >/dev/null
}
check "no workspace, environment, namespace or pod name on the metrics" metrics_lack_ids
no_credential_exported() {
  local collector backend
  collector="$(kubectl -n observability logs -l app=otel-collector --tail=-1)" || return 1
  backend="$(kubectl -n otel-backend logs deploy/otel-backend)" || return 1
  [[ -n $backend ]] || return 1
  local rc=0
  grep -qF -- "$real" <<<"${collector}${backend}" || rc=$?
  (( rc == 1 )) # 1 is no match; 0 is a match and 2 an error
}
check "the credential value never reaches the Collector or its backend" no_credential_exported

log "the Collector takes the ids from the sending pod, never from the record"
# A container added to a proxy pod shares its network, so it sends from the
# pod's address, as a compromised proxy would. Its record names another workspace.
forge_pod="$(kubectl -n ws-demo get pod -l "$PROXY_PODS" -o jsonpath='{.items[0].metadata.name}')"
forge_ip="$(kubectl -n ws-demo get pod "$forge_pod" -o jsonpath='{.status.podIP}')"
forge_body="forged-$(openssl rand -hex 8)"
forge_record="$(jq -cn --arg b "$forge_body" '{resourceLogs: [{
  resource: {attributes: [
    {key: "agentd.workspace_id", value: {stringValue: "wrk_Forged01"}},
    {key: "agentd.environment_id", value: {stringValue: "env_Forged01"}},
    {key: "k8s.pod.ip", value: {stringValue: "192.0.2.1"}}]},
  scopeLogs: [{logRecords: [{body: {stringValue: $b}}]}]}]}')"
# Base64, since kubectl debug splits --env values on commas.
b64() { openssl base64 -A <"${work}/$1"; }
printf '%s' "$forge_record" >"${work}/forge-record.json"
# shellcheck disable=SC2016 # the variables expand inside the debug container
kubectl -n ws-demo debug "$forge_pod" --profile=restricted --container=forge-otlp \
  --image=docker.io/curlimages/curl:8.15.0@sha256:4026b29997dc7c823b51c164b71e2b51e0fd95cce4601f78202c513d97da2922 \
  --env="CA_B64=$(b64 otlp-trusted.crt)" --env="RECORD_B64=$(b64 forge-record.json)" -- \
  sh -c 'echo "$CA_B64" | base64 -d >/tmp/ca.crt && echo "$RECORD_B64" | base64 -d \
    | curl -sS -f --cacert /tmp/ca.crt -H "Content-Type: application/json" --data-binary @- \
      https://otel-collector.observability:4318/v1/logs'
forge_sent() {
  FORGE_EXIT="$(kubectl -n ws-demo get pod "$forge_pod" -o json | jq -er '.status.ephemeralContainerStatuses[]?
    | select(.name == "forge-otlp") | .state.terminated.exitCode // empty')"
}
retry 30 2 forge_sent || true
check "a proxy pod sent a record naming another workspace, over TLS (within 60 s)" test "${FORGE_EXIT:-}" = 0
forge_relabelled() {
  collector_out | jq -se --arg b "$forge_body" --arg pod "$forge_pod" --arg ip "$forge_ip" '
    [.[].resourceLogs[]? | select([.scopeLogs[]?.logRecords[]?.body.stringValue] | index($b))
      | .resource.attributes | map({(.key): (.value | to_entries[0].value)}) | add] as $r
    | ($r | length > 0) and ($r | all(.["agentd.workspace_id"] == "wrk_Demo01"
        and .["agentd.environment_id"] == "env_Demo01"
        and .["k8s.pod.name"] == $pod and .["k8s.pod.ip"] == $ip))' >/dev/null
}
check "the record carries the sending pod's workspace, environment, name and address (within 60 s)" \
  retry 20 3 forge_relabelled
no_forged_id() {
  local out rc=0
  out="$(kubectl -n otel-backend logs deploy/otel-backend)" || return 1
  grep -qE 'wrk_Forged01|env_Forged01|192[.]0[.]2[.]1' <<<"$out" || rc=$?
  (( rc == 1 ))
}
check "the forged ids and address reach no record" no_forged_id

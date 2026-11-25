#!/usr/bin/env bash
# The e2e assertions. Each check prints PASS or FAIL; the script runs them all
# and exits non-zero if any failed.
source "$(dirname "$0")/lib.sh"

PROXY="http://proxy-env-demo.ws-demo.svc.cluster.local:8080"
STAND_IN="agentd-ph-crd_Demo01"
API="https://api.upstream.test/"
OTHER="https://other.upstream.test/"
BLOCKED="https://blocked.upstream.test/"
MISSING="https://missing.upstream.test/"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
check() { # <name> <command...>
  local name=$1
  shift
  if "$@"; then
    printf 'PASS %s\n' "$name"
  else
    if ci; then printf '::error::'; fi
    printf 'FAIL %s (codes="%s" tcp=%s curl exit=%s)\n' "$name" "${CODES:-}" "${TCP:-}" "${RC:-}"
    failures=$((failures + 1))
  fi
}

# via <pod> <url> [curl args...]
# Requests <url> from a sandbox pod through the proxy. Sets BODY, CODES
# ("<CONNECT status> <HTTP status>", 000 when there was none), TCP (seconds to
# the first TCP connect, 0 when none completed) and RC (curl's exit code).
via() {
  local pod=$1 url=$2 out
  shift 2
  RC=0
  out="$(kubectl -n sandboxes exec "$pod" -- curl -sS --connect-timeout 5 --max-time 20 \
    --proxy "$PROXY" --cacert /etc/agentd-ca/ca.crt \
    -w '\n%{http_connect} %{http_code} %{time_connect}' ${@+"$@"} "$url")" || RC=$?
  CODES="$(tail -n 1 <<<"$out" | cut -d ' ' -f 1,2)"
  TCP="$(tail -n 1 <<<"$out" | cut -d ' ' -f 3)"
  BODY="$(sed '$d' <<<"$out")"
}

# The upstream returns each header's SHA-256, never its value.
header_sha() { jq -r --arg h "$1" '.header_sha256[$h] // empty' <<<"$BODY"; }
sha() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
refused_at_connect() { [[ $CODES == 403\ * ]] && (( RC != 0 )); }
# A timeout counts only when no TCP connection completed, so a stalled TLS
# handshake or a name that fails to resolve (curl exit 6) is not a refusal.
no_connection() { [[ $CODES == "000 000" && $TCP == 0.000000 ]] && (( RC == 7 || RC == 28 )); }

real="$(kubectl -n moto exec deploy/moto -- python3 -c "$(cat "${DEMO_DIR}/scripts/secrets-manager.py")" get "$SECRET_ID" \
  | jq -r .secret_value)"
[[ -n $real ]] || fail "could not read the credential value back from moto"
mask "$real"

log "stand-in swapped for the real value on the credential's host"
via sandbox-labelled "$API" -H "X-Api-Key: ${STAND_IN}"
check "labelled sandbox connects through its proxy" test "$CODES" = "200 200"
check "stand-in replaced on api.upstream.test" test "$(header_sha x-api-key)" = "$(sha "$real")"

log "stand-in left alone on another allowed host"
via sandbox-labelled "$OTHER" -H "X-Api-Key: ${STAND_IN}"
check "other.upstream.test answered" test "$CODES" = "200 200"
check "stand-in not replaced on other.upstream.test" test "$(header_sha x-api-key)" = "$(sha "$STAND_IN")"

log "stand-in left alone outside TLS, even on the credential's host (require_tls)"
via sandbox-labelled "http://api.upstream.test/" -H "X-Api-Key: ${STAND_IN}"
check "plain HTTP to api.upstream.test answered" test "$CODES" = "000 200"
check "stand-in not replaced over plain HTTP" test "$(header_sha x-api-key)" = "$(sha "$STAND_IN")"

log "a credential whose secret cannot be read"
via sandbox-labelled "$MISSING" -H "X-Api-Key: agentd-ph-crd_Missing01"
check "missing.upstream.test answered" test "$CODES" = "200 200"
check "its stand-in passes unchanged" test "$(header_sha x-api-key)" = "$(sha agentd-ph-crd_Missing01)"

log "host outside the allowlist"
via sandbox-labelled "$BLOCKED"
check "blocked.upstream.test refused with 403 at CONNECT" refused_at_connect

log "cloud metadata address"
via sandbox-labelled "https://169.254.169.254/latest/meta-data/"
check "CONNECT to 169.254.169.254 refused with 403" refused_at_connect
via sandbox-labelled "http://169.254.169.254/latest/meta-data/"
check "plain HTTP to 169.254.169.254 refused with 403" test "$CODES" = "000 403"
via sandbox-labelled "https://metadata.demo.test/latest/meta-data/"
check "allowed name resolving to 169.254.169.254 gets 502" test "$CODES" = "200 502"
check "...because upstream_deny_cidrs refused the dial" \
  bash -c 'kubectl -n ws-demo logs deploy/proxy-env-demo -c iron-proxy | grep -q "denied by upstream_deny_cidrs: 169.254.169.254"'

log "network policy"
via sandbox-unlabelled "$OTHER"
check "unlabelled sandbox cannot reach the proxy" no_connection
via sandbox-other-env "$OTHER"
check "sandbox labelled for another environment cannot reach the proxy" no_connection
via sandbox-labelled "$API" --noproxy '*'
check "labelled sandbox cannot bypass the proxy to the upstream" no_connection
internet_reachable() {
  kubectl -n upstream exec deploy/echo -- python3 -c \
    'import urllib.request; urllib.request.urlopen("https://example.com/", timeout=10)'
}
check "control: the cluster reaches example.com from outside the sandbox policy" internet_reachable
via sandbox-labelled "https://example.com/" --noproxy '*'
check "labelled sandbox cannot reach example.com directly" no_connection
source "$(dirname "$0")/assert-collector.sh"

log "autoscaler"
hpa="$(kubectl -n ws-demo get hpa proxy-env-demo -o json)"
hpa_shape() {
  jq -e '.spec.minReplicas == 1 and .spec.maxReplicas == 5
    and ([.spec.metrics[] | {(.resource.name): .resource.target.averageUtilization}] | add)
        == {"cpu": 70, "memory": 70}' <<<"$hpa" >/dev/null
}
check "HPA scales proxy-env-demo 1 to 5 on CPU and memory at 70%" hpa_shape
hpa_reads_metrics() {
  kubectl -n ws-demo get hpa proxy-env-demo -o json | jq -e '
    ([.status.conditions[]? | select(.type == "ScalingActive" and .status == "True")] | length == 1)
    and ([.status.currentMetrics[]?.resource | select(.current.averageUtilization != null) | .name]
         | sort == ["cpu", "memory"])' >/dev/null
}
check "HPA reads live CPU and memory from metrics-server (within 180 s)" retry 36 5 hpa_reads_metrics

log "intermediate CA Secret is restored by cert-manager"
old_serial="$(kubectl -n ws-demo get secret iron-proxy-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)"
kubectl -n ws-demo delete secret iron-proxy-ca
restored() { kubectl -n ws-demo get secret iron-proxy-ca -o jsonpath='{.data.tls\.key}' 2>/dev/null | grep -q .; }
check "iron-proxy-ca Secret recreated within 60 s" retry 30 2 restored
kubectl -n sandboxes get configmap agentd-root-ca -o jsonpath='{.data.ca\.crt}' >"${work}/root.crt"
kubectl -n ws-demo get secret iron-proxy-ca -o jsonpath='{.data.tls\.crt}' | base64 -d >"${work}/intermediate.crt"
check "restored intermediate is newly issued" \
  test "$(openssl x509 -noout -serial -in "${work}/intermediate.crt")" != "$old_serial"
check "restored intermediate chains to the root" \
  openssl verify -CAfile "${work}/root.crt" "${work}/intermediate.crt"
check "restored intermediate is a CA" \
  bash -c "openssl x509 -noout -text -in '${work}/intermediate.crt' | grep -q 'CA:TRUE'"

log "a config change reaches the running proxy through the watcher"
kubectl -n ws-demo get configmap proxy-env-demo-config -o json \
  | jq '.data["proxy.yaml"] |= sub("(?<i> *)- \"other.upstream.test\"\n";
      "\(.i)- \"other.upstream.test\"\n\(.i)- \"blocked.upstream.test\"\n")' \
  | kubectl replace -f -
blocked_allowed() { via sandbox-labelled "$BLOCKED"; [[ $CODES == "200 200" ]]; }
check "blocked.upstream.test allowed after the ConfigMap change (within 180 s)" retry 36 5 blocked_allowed
watcher_lines() { kubectl -n ws-demo logs deploy/proxy-env-demo -c config-reload | grep -c "$1" || true; }
sleep 10 # two more watcher polls, so a repeated reload would show
check "watcher reloaded exactly once for the change" test "$(watcher_lines 'iron-proxy reloaded')" = 1

log "a config the proxy rejects is logged at ERROR and the running config stays"
kubectl -n ws-demo get configmap proxy-env-demo-config -o json \
  | jq '.data["proxy.yaml"] += "not_a_field: true\n"' \
  | kubectl replace -f -
reload_error_logged() {
  kubectl -n ws-demo logs deploy/proxy-env-demo -c config-reload | grep -q 'level=ERROR msg="iron-proxy reload failed"'
}
check "watcher logged the rejected reload at ERROR (within 180 s)" retry 36 5 reload_error_logged
sleep 10
check "watcher tried the rejected config exactly once" \
  test "$(watcher_lines 'level=ERROR msg="iron-proxy reload failed"')" = 1
via sandbox-labelled "$API" -H "X-Api-Key: ${STAND_IN}"
check "proxy still swaps with the last good config" test "$(header_sha x-api-key)" = "$(sha "$real")"
via sandbox-labelled "$BLOCKED"
check "last good config, not the startup one, still serves blocked.upstream.test" test "$CODES" = "200 200"

if (( failures > 0 )); then
  fail "${failures} check(s) failed"
fi
log "all checks passed"

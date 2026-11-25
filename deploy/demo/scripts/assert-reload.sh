# shellcheck shell=bash disable=SC2154 # API, BLOCKED, STAND_IN, PROXY_PODS, real and work are set by assert.sh, which sources this file
# The config reload checks. Sourced by assert.sh, last, since they change the
# proxy's ConfigMap; uses its check, via, header_sha, sha and retry. The HPA can
# add or remove proxy pods during the run, so every check reads every pod's
# watcher.

reloaded='msg="iron-proxy reloaded"'
rejected='msg="iron-proxy reload failed"'
# The proxy answers a config it rejects with 422 and the YAML decoder's error.
reason='msg="iron-proxy reload failed" status=422 answer=.*not_a_field'

proxy_pods() {
  kubectl -n ws-demo get pod -l "$PROXY_PODS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}
# watcher_lines <pod> <regex>: how many lines of the pod's watcher log match; fails if the log cannot be read.
watcher_lines() {
  local out
  out="$(kubectl -n ws-demo logs "$1" -c config-reload)" || return 1
  grep -cE -- "$2" <<<"$out" || true
}
# per_pod <regex> <count> <pods before the change>: each pod that ran before the
# change logged <regex> exactly <count> times, and at least one of them still
# runs. A pod started since may have mounted either config, so it logged it at
# most <count> times.
per_pod() {
  local regex=$1 count=$2 before=$3 pods pod n seen=0
  pods="$(proxy_pods)" || return 1
  while IFS= read -r pod; do
    [[ -n $pod ]] || continue
    n="$(watcher_lines "$pod" "$regex")" || return 1
    [[ $n =~ ^[0-9]+$ ]] || return 1
    if grep -qxF -- "$pod" <<<"$before"; then
      seen=$((seen + 1))
      (( n == count )) || return 1
    else
      (( n <= count )) || return 1
    fi
  done <<<"$pods"
  (( seen > 0 ))
}

log "a config change reaches every running proxy through its watcher"
before="$(proxy_pods)"
kubectl -n ws-demo get configmap proxy-env-demo-config -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)
      | .data["proxy.yaml"] |= sub("(?<i> *)- \"other.upstream.test\"\n";
      "\(.i)- \"other.upstream.test\"\n\(.i)- \"blocked.upstream.test\"\n")' >"${work}/good-config.json"
kubectl replace -f "${work}/good-config.json"
check "every proxy pod's watcher reloaded for the change (within 180 s)" retry 36 5 per_pod "$reloaded" 1 "$before"
blocked_allowed() { via sandbox-labelled "$BLOCKED"; [[ $CODES == "200 200" ]]; }
check "blocked.upstream.test allowed after the ConfigMap change (within 60 s)" retry 12 5 blocked_allowed
sleep 10 # two more watcher polls, so a repeated reload would show
check "each watcher reloaded exactly once for the change" per_pod "$reloaded" 1 "$before"

log "a config the proxy rejects is logged at ERROR with the proxy's reason, and the running config stays"
before="$(proxy_pods)"
jq '.data["proxy.yaml"] += "not_a_field: true\n"' "${work}/good-config.json" | kubectl replace -f -
check "every proxy pod's watcher logged the rejected reload at ERROR (within 180 s)" \
  retry 36 5 per_pod "$rejected" 1 "$before"
sleep 10
check "each watcher tried the rejected config exactly once" per_pod "$rejected" 1 "$before"
check "each watcher logged the proxy's answer: 422 and the unknown field" per_pod "$reason" 1 "$before"
via sandbox-labelled "$API" -H "X-Api-Key: ${STAND_IN}"
check "proxy still swaps with the last good config" test "$(header_sha x-api-key)" = "$(sha "$real")"
via sandbox-labelled "$BLOCKED"
check "last good config, not the startup one, still serves blocked.upstream.test" test "$CODES" = "200 200"

log "the last good config is restored, and new proxy pods start with it"
kubectl replace -f "${work}/good-config.json"
kubectl -n ws-demo rollout restart deploy/proxy-env-demo
check "proxy pods restarted on the restored config become ready (within 180 s)" \
  kubectl -n ws-demo rollout status deploy/proxy-env-demo --timeout=180s
# kindnet takes a few seconds to admit the new pods' addresses.
check "restarted proxy serves blocked.upstream.test from the restored config (within 60 s)" retry 12 5 blocked_allowed
restarted_swaps() { via sandbox-labelled "$API" -H "X-Api-Key: ${STAND_IN}"; [[ $(header_sha x-api-key) == "$(sha "$real")" ]]; }
check "restarted proxy swaps the stand-in (within 60 s)" retry 12 5 restarted_swaps

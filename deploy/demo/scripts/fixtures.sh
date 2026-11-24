#!/usr/bin/env bash
# Test fixtures that stand in for things outside the cluster: moto for
# Secrets Manager, a fake HTTPS upstream, and a DNS name that resolves to the
# cloud metadata address.
source "$(dirname "$0")/lib.sh"

SECRET_ID="agentd/wrk_Demo01/vlt_Demo01/crd_Demo01"

log "moto and the fake upstream"
kubectl apply -f "${DEMO_DIR}/fixtures/moto.yaml"
kubectl apply -f "${DEMO_DIR}/fixtures/upstream.yaml"
kubectl -n upstream wait certificate/upstream-ca certificate/echo-tls --for=condition=Ready --timeout=120s
kubectl -n upstream rollout status deploy/echo --timeout=180s
kubectl -n moto rollout status deploy/moto --timeout=180s

log "credential value in Secrets Manager, shaped as agentd stores it"
value="real-$(openssl rand -hex 16)"
echo "::add-mask::${value}"
printf '{"secret_value":"%s"}' "$value" \
  | kubectl -n moto exec -i deploy/moto -- python3 -c "$(cat "${DEMO_DIR}/scripts/secrets-manager.py")" create "$SECRET_ID"

log "fake upstream's CA, for the proxy only"
kubectl -n upstream get secret upstream-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"${RUNNER_TEMP:-/tmp}/upstream-ca.crt"
kubectl -n ws-demo create configmap upstream-ca --from-file=ca.crt="${RUNNER_TEMP:-/tmp}/upstream-ca.crt"

log "metadata.demo.test resolves to 169.254.169.254"
corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
grep -q '^\.:53 {' <<<"$corefile" || fail "unexpected Corefile layout"
patched="$(awk '{ print } /^\.:53 \{/ { print "    hosts {\n        169.254.169.254 metadata.demo.test\n        fallthrough\n    }" }' <<<"$corefile")"
kubectl -n kube-system create configmap coredns --from-literal=Corefile="$patched" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns --timeout=120s

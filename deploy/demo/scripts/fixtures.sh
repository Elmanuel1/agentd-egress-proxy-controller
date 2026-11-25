#!/usr/bin/env bash
# Test fixtures that stand in for things outside the cluster: moto for
# Secrets Manager, a fake HTTPS upstream on a public test address, and a DNS
# name that resolves to the cloud metadata address.
source "$(dirname "$0")/lib.sh"

log "moto and the fake upstream"
kubectl apply -f "${DEMO_DIR}/fixtures/moto.yaml"
kubectl apply -f "${DEMO_DIR}/fixtures/upstream.yaml"
kubectl -n upstream wait certificate/upstream-ca certificate/echo-tls --for=condition=Ready --timeout=120s
kubectl -n upstream rollout status deploy/echo --timeout=180s
kubectl -n moto rollout status deploy/moto --timeout=180s

log "credential value in Secrets Manager, shaped as agentd stores it"
value="real-$(openssl rand -hex 16)"
mask "$value"
printf '{"secret_value":"%s"}' "$value" \
  | kubectl -n moto exec -i deploy/moto -- python3 -c "$(cat "${DEMO_DIR}/scripts/secrets-manager.py")" create "$SECRET_ID"

log "fake upstream's CA, for the proxy only"
upstream_ca="$(secret_pem upstream upstream-ca ca.crt)"
kubectl -n ws-demo create configmap upstream-ca --from-literal=ca.crt="$upstream_ca"

log "the upstream's names resolve to its external IP; metadata.demo.test to 169.254.169.254"
corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
grep -q '^\.:53 {' <<<"$corefile" || fail "unexpected Corefile layout"
hosts='    hosts {
        203.0.113.10 api.upstream.test other.upstream.test blocked.upstream.test missing.upstream.test
        169.254.169.254 metadata.demo.test
        fallthrough
    }'
patched="$(HOSTS="$hosts" awk '{ print } /^\.:53 \{/ { print ENVIRON["HOSTS"] }' <<<"$corefile")"
kubectl -n kube-system create configmap coredns --from-literal=Corefile="$patched" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns --timeout=120s

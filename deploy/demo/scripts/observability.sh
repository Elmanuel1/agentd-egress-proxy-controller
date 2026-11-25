#!/usr/bin/env bash
# The OpenTelemetry Collector that receives the proxies' OTLP audit records,
# and the test backend it exports to.
source "$(dirname "$0")/lib.sh"

log "test backend"
kubectl apply -f "${DEMO_DIR}/fixtures/otel-backend.yaml"
kubectl -n otel-backend wait certificate/otel-backend-tls --for=condition=Ready --timeout=120s
kubectl -n otel-backend rollout status deploy/otel-backend --timeout=180s

log "Collector (deploy/observability) with the test backend's ConfigMap and policy"
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
backend_ca="$(secret_pem otel-backend otel-backend-tls ca.crt)"
kubectl -n observability create configmap otel-backend \
  --from-literal=endpoint=otel-backend.otel-backend.svc.cluster.local:4317 \
  --from-literal=ca.crt="$backend_ca"
# The platform's policy for the Collector to reach the API server, which
# k8s_attributes watches pods through. Its addresses are known only once the
# cluster runs: the Service address, and the endpoint kube-proxy sends it to.
ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
api_service="$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
api_slice="$(kubectl -n default get endpointslice -l kubernetes.io/service-name=kubernetes -o json)"
api_endpoint="$(jq -r '.items[0].endpoints[0].addresses[0] // empty' <<<"$api_slice")"
api_port="$(jq -r '.items[0].ports[] | select(.name == "https") | .port' <<<"$api_slice")"
ipv4 "$api_service" && ipv4 "$api_endpoint" && [[ $api_port =~ ^[0-9]+$ ]] \
  || fail "could not read the API server's address (service=${api_service} endpoint=${api_endpoint} port=${api_port})"
kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: otel-collector-api-server
  namespace: observability
spec:
  podSelector:
    matchLabels:
      app: otel-collector
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: ${api_service}/32
      ports:
        - port: 443
          protocol: TCP
    - to:
        - ipBlock:
            cidr: ${api_endpoint}/32
      ports:
        - port: ${api_port}
          protocol: TCP
YAML
kubectl apply -k "${DEMO_DIR}/test/observability"
kubectl -n observability wait certificate/agentd-otel-ca --for=condition=Ready --timeout=120s
kubectl -n observability wait issuer/agentd-otel-ca --for=condition=Ready --timeout=60s
kubectl -n observability wait certificate/otel-collector-tls --for=condition=Ready --timeout=120s
kubectl -n observability rollout status deploy/otel-collector --timeout=180s

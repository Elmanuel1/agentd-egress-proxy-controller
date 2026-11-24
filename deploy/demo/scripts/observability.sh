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
kubectl -n observability create configmap otel-backend \
  --from-literal=endpoint=otel-backend.otel-backend.svc.cluster.local:4317 \
  --from-literal=ca.crt="$(kubectl -n otel-backend get secret otel-backend-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)"
kubectl apply -k "${DEMO_DIR}/test/observability"
kubectl -n observability wait certificate/otel-collector-tls --for=condition=Ready --timeout=120s
kubectl -n observability rollout status deploy/otel-collector --timeout=180s

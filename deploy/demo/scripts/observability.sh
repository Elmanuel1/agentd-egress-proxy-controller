#!/usr/bin/env bash
# The OpenTelemetry Collector that receives the proxies' OTLP audit records.
source "$(dirname "$0")/lib.sh"

kubectl apply -f "${DEMO_DIR}/../observability/collector.yaml"
kubectl -n observability rollout status deploy/otel-collector --timeout=180s

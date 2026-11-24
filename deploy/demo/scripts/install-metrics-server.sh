#!/usr/bin/env bash
# Installs the pinned metrics-server release, so the proxy's
# HorizontalPodAutoscaler reads live CPU and memory.
source "$(dirname "$0")/lib.sh"

manifest="$(mktemp)"
trap 'rm -f "$manifest" "${manifest}.kind"' EXIT

log "metrics-server ${METRICS_SERVER_VERSION}"
fetch_manifest "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" \
  "$METRICS_SERVER_SHA256" "$manifest" "$METRICS_SERVER_IMAGES"
# Test-only: kind's kubelets serve self-signed certificates, which a managed
# cluster's kubelets do not.
sed 's#^\( *\)- --cert-dir=/tmp$#&\n\1- --kubelet-insecure-tls#' "$manifest" >"${manifest}.kind"
grep -q -- '- --kubelet-insecure-tls' "${manifest}.kind" || fail "could not add --kubelet-insecure-tls"
kubectl apply -f "${manifest}.kind"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
kubectl wait apiservice/v1beta1.metrics.k8s.io --for=condition=Available --timeout=120s

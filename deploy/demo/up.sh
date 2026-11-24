#!/usr/bin/env bash
# Builds the demo on a new local kind cluster and runs the e2e checks. CI runs
# this same script. Needs Docker (about 4 GB free for it), kind, kubectl,
# openssl, jq and curl. Remove the cluster with down.sh.
source "$(dirname "$0")/scripts/lib.sh"

for tool in docker kind kubectl openssl jq curl; do
  command -v "$tool" >/dev/null || fail "${tool} is not installed"
done
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  fail "kind cluster ${CLUSTER} already exists; run deploy/demo/down.sh first"
fi

phase() { # <title> <script>
  if ci; then printf '::group::%s\n' "$1"; fi
  log "$1"
  "${DEMO_DIR}/scripts/$2" || {
    log "failed; deploy/demo/scripts/dump.sh prints the cluster state"
    return 1
  }
  if ci; then printf '::endgroup::\n'; fi
}

log "kind cluster ${CLUSTER}"
mkdir -p "$(dirname "$KUBECONFIG")"
kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" \
  --config "${DEMO_DIR}/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 120s

phase "cert-manager" install-cert-manager.sh
phase "root CA and ClusterIssuer (stand-in for Secrets Manager and External Secrets)" root-ca.sh
phase "fixtures (moto, fake upstream, metadata DNS name)" fixtures.sh
phase "OpenTelemetry Collector" observability.sh
phase "workspace proxy and sandboxes" proxy.sh
phase "assertions" assert.sh

log "demo is up; KUBECONFIG=${KUBECONFIG}"

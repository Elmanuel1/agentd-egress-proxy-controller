#!/usr/bin/env bash
# Installs the pinned cert-manager release after checking its checksum.
source "$(dirname "$0")/lib.sh"

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT

log "cert-manager ${CERT_MANAGER_VERSION}"
curl -fsSL --retry 3 -o "$manifest" \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
echo "${CERT_MANAGER_SHA256}  ${manifest}" | shasum -a 256 -c -

kubectl apply -f "$manifest"
for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
  kubectl -n cert-manager rollout status "deploy/${d}" --timeout=180s
done

# The webhook is ready only once its serving certificate is injected; a
# server-side dry run of an issuer goes through the webhook and proves it.
retry 30 2 kubectl apply --dry-run=server -f "${DEMO_DIR}/root-issuer.yaml" >/dev/null \
  || fail "cert-manager webhook did not become ready"

#!/usr/bin/env bash
# Deploys what the controller writes for workspace wrk_Demo01 and environment
# env_Demo01, then the sandbox stand-ins.
source "$(dirname "$0")/lib.sh"

log "management key (the controller makes one per workspace with crypto/rand)"
kubectl -n ws-demo create secret generic iron-proxy-management \
  --from-literal=api-key="$(openssl rand -hex 32)"

log "workspace identity and intermediate CA"
kubectl apply -f "${DEMO_DIR}/workspace/identity.yaml"
kubectl -n ws-demo wait certificate/iron-proxy-ca --for=condition=Ready --timeout=120s

log "proxy"
kubectl apply -f "${DEMO_DIR}/workspace/config.yaml" -f "${DEMO_DIR}/workspace/proxy.yaml"
kubectl -n ws-demo rollout status deploy/proxy-env-demo --timeout=180s

log "sandboxes"
kubectl apply -f "${DEMO_DIR}/sandboxes/egress.yaml" -f "${DEMO_DIR}/sandboxes/pods.yaml"
kubectl -n sandboxes wait pod --all --for=condition=Ready --timeout=180s

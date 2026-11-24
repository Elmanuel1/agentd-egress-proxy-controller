#!/usr/bin/env bash
# Makes the root CA and its ClusterIssuer. In production the root's certificate
# and key live in AWS Secrets Manager and External Secrets writes them to the
# same Secret, cert-manager/agentd-root-ca; the demo runs without AWS, so it
# generates a throwaway root here. The private key leaves the machine running
# the demo only into that Secret, and the local copy is deleted on exit.
source "$(dirname "$0")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"${work}/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
CN = agentd demo root CA
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF

log "root CA"
(umask 077 && openssl ecparam -name prime256v1 -genkey -noout -out "${work}/ca.key")
openssl req -x509 -new -key "${work}/ca.key" -sha256 -days 7 \
  -config "${work}/ca.cnf" -out "${work}/ca.crt"

kubectl apply -f "${DEMO_DIR}/namespaces.yaml"
kubectl -n cert-manager create secret tls agentd-root-ca \
  --cert "${work}/ca.crt" --key "${work}/ca.key"
kubectl apply -f "${DEMO_DIR}/root-issuer.yaml"
kubectl wait clusterissuer/agentd-root-ca --for=condition=Ready --timeout=60s

# Sandboxes trust the root certificate only.
kubectl -n sandboxes create configmap agentd-root-ca --from-file=ca.crt="${work}/ca.crt"

#!/usr/bin/env bash
# Deletes the demo's kind cluster and its kubeconfig.
source "$(dirname "$0")/scripts/lib.sh"

kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
rm -f "$KUBECONFIG"

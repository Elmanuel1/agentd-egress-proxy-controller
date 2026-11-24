# shellcheck shell=bash disable=SC2034 # its settings are read by the scripts that source it
# Shared settings and helpers for the demo scripts. Sourced, not run.
# Written for bash 3.2 (macOS /bin/bash) as well as current Linux bash.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEMO_DIR

CLUSTER="epc-demo"
KIND_NODE_IMAGE="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
CERT_MANAGER_VERSION="v1.21.3"
CERT_MANAGER_SHA256="c04a51295adda2b1a775146751f973e787190778c7f35180861d9678876e5c74"
SECRET_ID="agentd/wrk_Demo01/vlt_Demo01/crd_Demo01"

# The demo cluster gets its own kubeconfig, so no script ever reads or changes
# the caller's current kubectl context.
KUBECONFIG="${EPC_DEMO_KUBECONFIG:-${XDG_CACHE_HOME:-$HOME/.cache}/epc-demo/kubeconfig}"
export KUBECONFIG

ci() { [[ -n ${GITHUB_ACTIONS:-} ]]; }
log() { printf '==> %s\n' "$*"; }
fail() {
  if ci; then printf '::error::%s\n' "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi
  exit 1
}
# Hides a value from the GitHub Actions log. Locally the value is never printed.
mask() {
  if ci; then printf '::add-mask::%s\n' "$1"; fi
}

# retry <attempts> <delay seconds> <command...>
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    n=$((n + 1))
    sleep "$delay"
  done
}

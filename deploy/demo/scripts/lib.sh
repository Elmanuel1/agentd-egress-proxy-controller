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
CERT_MANAGER_IMAGES="quay.io/jetstack/cert-manager-controller:v1.21.3@sha256:9f4f96a33c7774cef24466fcd85031997531a03a8d117f151126baa8d1290dcc
quay.io/jetstack/cert-manager-cainjector:v1.21.3@sha256:083d0e906f8eb44e255fe4ff817ae54e49f9ed82e22f1011bb4e9e4f4b8a641f
quay.io/jetstack/cert-manager-webhook:v1.21.3@sha256:055ac8e9de6a0ba6763794838fe38944acc650f68ebe1b01dd8be079e580f458
quay.io/jetstack/cert-manager-acmesolver:v1.21.3@sha256:c8c1225bb2fe8ab37a330b77f0d8c2ee6a41210fcb54fc07ca606ab9a022b8b7"
METRICS_SERVER_VERSION="v0.9.1"
METRICS_SERVER_SHA256="3c7f57cdbee0f57fb0259a150e8f6d6cb4f29d72d1aa5dce8803151dd6d4c2a1"
METRICS_SERVER_IMAGES="registry.k8s.io/metrics-server/metrics-server:v0.9.1@sha256:9b0ba1926e1d3089673f45461c3c1416109dea33b3ba3434048defd380df329b"
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

# fetch_manifest <url> <sha256> <out> <pinned images, one per line>
# Downloads a release manifest, checks its checksum, and rewrites each image
# reference (an `image:` field or an `-image=` flag) to its pinned digest;
# fails if any image stays unpinned.
fetch_manifest() {
  local url=$1 sum=$2 out=$3 images=$4 ref
  curl -fsSL --retry 3 -o "$out" "$url"
  echo "${sum}  ${out}" | shasum -a 256 -c - >/dev/null || fail "checksum mismatch for ${url}"
  while IFS= read -r ref; do
    sed "s#${ref%@*}\(\"\{0,1\}\)\$#${ref}\1#" "$out" >"${out}.pinned" && mv "${out}.pinned" "$out"
  done <<<"$images"
  if grep -E '^ *image:|-image=' "$out" | grep -v '@sha256:' >&2; then
    fail "unpinned image in ${url}"
  fi
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

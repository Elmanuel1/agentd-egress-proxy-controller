# shellcheck shell=bash
# Shared settings and helpers for the demo scripts. Sourced, not run.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEMO_DIR

log() { printf '==> %s\n' "$*"; }
fail() { printf '::error::%s\n' "$*"; exit 1; }

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

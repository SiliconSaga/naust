#!/usr/bin/env bash
# Component self-test. Uses the workspace-vendored bats; shellcheck via the
# koalaman container unless a host shellcheck exists.
set -euo pipefail
cd "$(dirname "$0")/.."
WS_ROOT="$(cd ../.. && pwd)"
BATS="$(command -v bats || true)"
BATS="${BATS:-$WS_ROOT/tests/vendor/bats-core/bin/bats}"

shellcheck_run() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$@"
  else
    ws docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable "$@"
  fi
}

case "${1:-test}" in
  test)
    sel="${2:-}"
    if [ -z "$sel" ]; then
      exec bash "$BATS" tests/
    elif [ -f "$sel" ]; then
      exec bash "$BATS" "$sel"
    fi
    if [ "$(bash "$BATS" --count --filter "$sel" tests/)" -eq 0 ]; then
      echo "no test name matches '$sel' (a bats --filter regex over tests/)" >&2
      exit 1
    fi
    exec bash "$BATS" --filter "$sel" tests/
    ;;
  lint) shellcheck_run bin/naust bin/*.sh tests/*.sh ;;
  *) echo "usage: tests/run.sh {test [selector]|lint}" >&2; exit 2 ;;
esac

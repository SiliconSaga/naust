#!/usr/bin/env bash
# Queue a pull request by hand, ahead of polled ones. The trust gate still
# applies to the head as it is now; the debounce does not.
#
#   run.sh <profile> <number> [--with <target>#<n>]... [--bay <name>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
require_tool gh
gh_auth

profile="${1:-}"; number="${2:-}"
[ -n "$profile" ] && [ -n "$number" ] || die "usage: naust run <profile> <number> [--with <target>#<n>]... [--bay <name>]"
shift 2
with="" bay=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with) with="${with:+$with,}$2"; shift 2 ;;
    --bay) bay="$2"; shift 2 ;;
    *) die "naust run: unknown argument '$1'" ;;
  esac
done
repo="$(prof "$profile" .repo)"; [ -n "$repo" ] || die "profile $profile has no repo"
IFS=$'\t' read -r head base author head_repo < <(gh pr view "$number" --repo "$repo" \
  --json headRefOid,baseRefName,author,headRepositoryOwner,headRepository \
  --jq '[.headRefOid, .baseRefName, .author.login, ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))] | @tsv')
[ -n "$head" ] || die "naust run: could not read $repo#$number"
IFS=$'\t' read -r decision reason < <(bash "$HERE/gate.sh" decide "$profile" "$repo" "$number" "$author" "$head_repo" "$head")
if [ "$decision" != run ]; then
  die "naust run: $repo#$number $reason"
fi
log "run: $repo#$number ($reason)"
bash "$HERE/queue.sh" put "$profile" "$repo" "$number" "$head" "$base" "$author" "$head_repo" --priority 10 ${with:+--with "$with"} ${bay:+--bay "$bay"}
bash "$HERE/poll.sh" mark "$profile" "$number" queued "$head"

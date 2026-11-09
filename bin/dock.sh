#!/usr/bin/env bash
# Queue a pull request by hand, ahead of polled ones. The operator's command
# is the vouch: the nod exists for the unattended tick, where nobody is at
# the keyboard, so no GitHub review is asked for here and the debounce does
# not apply. The head is read now and the job stops if it has moved by the
# time it runs, since that is a commit the operator never saw.
#
#   dock.sh <profile> <number> [--with <target>#<n>]... [--bay <name>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
require_tool gh
gh_auth

profile="${1:-}"; number="${2:-}"
[ -n "$profile" ] && [ -n "$number" ] || die "usage: naust dock <profile> <number> [--with <target>#<n>]... [--bay <name>]"
shift 2
with="" bay=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with) with="${with:+$with,}$2"; shift 2 ;;
    --bay) bay="$2"; shift 2 ;;
    *) die "naust dock: unknown argument '$1'" ;;
  esac
done
repo="$(prof "$profile" .repo)"; [ -n "$repo" ] || die "profile $profile has no repo"
IFS=$'\t' read -r head base author head_repo < <(gh pr view "$number" --repo "$repo" \
  --json headRefOid,baseRefName,author,headRepositoryOwner,headRepository \
  --jq '[.headRefOid, .baseRefName, .author.login, ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))] | @tsv')
[ -n "$head" ] || die "naust dock: could not read $repo#$number"
log "dock: $repo#$number at ${head:0:7} by $author queued on the operator's word"
bash "$HERE/queue.sh" put "$profile" "$repo" "$number" "$head" "$base" "$author" "$head_repo" --priority 10 ${with:+--with "$with"} ${bay:+--bay "$bay"}
bash "$HERE/poll.sh" mark "$profile" "$number" queued "$head"

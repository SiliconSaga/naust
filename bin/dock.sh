#!/usr/bin/env bash
# Bring a pull request into a bay by hand, now. The operator's command is the
# vouch: nobody on GitHub is asked, and the report comes back here, to the
# terminal, not to the PR, unless --comment says so. The head is read now and
# the job stops if it has moved by the time it runs, since that is a commit
# the operator never saw.
#
#   dock.sh <profile> <number> [--with <target>#<n>]... [--bay <name>] [--comment] [--queue]
#
# --queue leaves the job for the next tick instead of running it here; so
# does a tick already running a job, or no free bay, with a word to say so.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
require_tool gh
gh_auth

profile="${1:-}"; number="${2:-}"
[ -n "$profile" ] && [ -n "$number" ] || die "usage: naust dock <profile> <number> [--with <target>#<n>]... [--bay <name>] [--comment] [--queue]"
shift 2
with="" bay="" comment=off queue_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with) with="${with:+$with,}$2"; shift 2 ;;
    --bay) bay="$2"; shift 2 ;;
    --comment) comment=on; shift ;;
    --queue) queue_only=1; shift ;;
    *) die "naust dock: unknown argument '$1'" ;;
  esac
done
repo="$(prof "$profile" .repo)"; [ -n "$repo" ] || die "profile $profile has no repo"
IFS=$'\t' read -r head base author head_repo < <(gh pr view "$number" --repo "$repo" \
  --json headRefOid,baseRefName,author,headRepositoryOwner,headRepository \
  --jq '[.headRefOid, .baseRefName, .author.login, ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))] | @tsv')
[ -n "$head" ] || die "naust dock: could not read $repo#$number"
log "dock: $repo#$number at ${head:0:7} by $author queued on the operator's word"
bash "$HERE/queue.sh" put "$profile" "$repo" "$number" "$head" "$base" "$author" "$head_repo" --priority 10 --comment "$comment" ${with:+--with "$with"} ${bay:+--bay "$bay"}
bash "$HERE/poll.sh" mark "$profile" "$number" queued "$head"
[ "$queue_only" -eq 0 ] || exit 0

if ! with_lock; then
  log "dock: a tick holds $STATE_DIR/lock, so a job is running; $repo#$number is queued for the next tick"
  exit 1
fi
queued="$STATE_DIR/queue/${repo//\//__}__$number.job"
ran="$(mktemp)"
rc=0
bash "$HERE/run.sh" job "$queued" > "$ran" || rc=$?
IFS=$'\t' read -r ran_bay jobid outputs < "$ran" || true
rm -f "$ran"
if [ -z "$ran_bay" ]; then
  log "dock: $repo#$number could not run now and stays queued for the next tick"
  exit 1
fi
[ -f "$outputs/report.md" ] && cat "$outputs/report.md"
printf '\nBay %s holds %s; outputs in %s\n' "$ran_bay" "$jobid" "$outputs"
exit "$rc"

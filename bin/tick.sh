#!/usr/bin/env bash
# One tick: poll, gate, queue, notify, run at most one job, exit. The OS
# scheduler calls this every few minutes; the lock makes overlapping ticks
# harmless and a crashed tick's lock is reclaimed after LOCK_STALE_HOURS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
gh_auth
JOB_SCRIPT="${NAUST_JOB_SCRIPT:-$HERE/job.sh}"

if ! with_lock; then
  log "tick: another tick holds $STATE_DIR/lock; nothing to do"
  exit 0
fi

while IFS= read -r profile; do
  [ -n "$profile" ] || continue
  while IFS=$'\t' read -r p repo number sha base author head_repo; do
    [ -n "$number" ] || continue
    IFS=$'\t' read -r decision reason < <(bash "$HERE/gate.sh" decide "$p" "$repo" "$number" "$author" "$head_repo" "$sha")
    if [ "$decision" = run ]; then
      bash "$HERE/queue.sh" put "$p" "$repo" "$number" "$sha" "$base" "$author" "$head_repo"
      bash "$HERE/poll.sh" mark "$p" "$number" queued "$sha"
      log "tick: $repo#$number queued ($reason)"
    else
      seen="$STATE_DIR/seen/${repo//\//__}/$number"
      if [ "$(kv_get "$seen" notified)" != "$sha" ]; then
        bash "$HERE/notify.sh" say "PR #$number on $repo by @$author at ${sha:0:7} needs a nod before a bay runs it: a maintainer's Approve, or a review saying \"$(trust "$p" .nod_phrase 'ok to test')\". https://github.com/$repo/pull/$number ($reason)" || true
        bash "$HERE/poll.sh" mark "$p" "$number" notified "$sha"
      fi
      log "tick: $repo#$number waiting ($reason)"
    fi
  done < <(bash "$HERE/poll.sh" candidates "$profile")
done < <(cfg_list .profiles)

job="$(bash "$HERE/queue.sh" next)" || { log "tick: queue empty"; exit 0; }
profile="$(kv_get "$job" profile)"
repo="$(kv_get "$job" repo)"; number="$(kv_get "$job" number)"; head="$(kv_get "$job" head)"
jobid="${repo//\//__}-$number-${head:0:7}"
bay="$(kv_get "$job" bay)"
if [ -z "$bay" ]; then
  bay="$(bash "$HERE/bay.sh" free-for "$profile")" || { log "tick: no free bay for $profile; $repo#$number stays queued"; exit 0; }
fi
if ! bash "$HERE/bay.sh" claim "$bay" "$jobid"; then
  log "tick: bay $bay is not free; $repo#$number stays queued"
  exit 0
fi
run="$STATE_DIR/jobs/$jobid.job"
mv "$job" "$run"
log "tick: running $jobid in $bay"
if bash "$JOB_SCRIPT" "$bay" "$run"; then
  log "tick: $jobid finished"
else
  log "tick: $jobid finished with failures (see the report)"
fi
exit 0

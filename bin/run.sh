#!/usr/bin/env bash
# Run a queued job through a bay. The caller holds the tick lock.
#
#   run.sh next              the first queued job that can have a bay; nothing to run is fine
#   run.sh job <queuefile>   this job now; exits 2 when no bay can take it
#
# When a job runs, one line goes to stdout: <bay><TAB><jobid><TAB><outputs>,
# and the exit status is the job's.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
JOB_SCRIPT="${NAUST_JOB_SCRIPT:-$HERE/job.sh}"

# Claim a bay for a queued job: its pinned bay, else a free one of its
# profile. Prints the bay name; fails, with the reason logged, when none can
# take it now.
claim_for() { # <queuefile>
  local cand="$1" profile repo number bay bay_profile jobid
  profile="$(kv_get "$cand" profile)"
  repo="$(kv_get "$cand" repo)"; number="$(kv_get "$cand" number)"
  jobid="${repo//\//__}-$number-$(kv_get "$cand" head | cut -c1-7)"
  bay="$(kv_get "$cand" bay)"
  if [ -z "$bay" ]; then
    bay="$(bash "$HERE/bay.sh" free-for "$profile")" || { log "run: no free bay for $profile; $repo#$number stays queued"; return 1; }
  else
    # A pinned bay is run as its own profile's, so a bay of another profile
    # would run the PR against the wrong component and commands.
    bay_profile="$(bash "$HERE/bay.sh" list | awk -F'\t' -v b="$bay" '$1 == b { print $3 }')"
    if [ "$bay_profile" != "$profile" ]; then
      log "run: bay $bay belongs to ${bay_profile:-no profile}, not $profile; $repo#$number stays queued"
      return 1
    fi
  fi
  bash "$HERE/bay.sh" claim "$bay" "$jobid" || { log "run: bay $bay is not free; $repo#$number stays queued"; return 1; }
  printf '%s\n' "$bay"
}

run_job() { # <queuefile> <bay>
  local cand="$1" bay="$2" repo number head jobid run rc=0
  repo="$(kv_get "$cand" repo)"; number="$(kv_get "$cand" number)"; head="$(kv_get "$cand" head)"
  jobid="${repo//\//__}-$number-${head:0:7}"
  run="$STATE_DIR/jobs/$jobid.job"
  mv "$cand" "$run"
  log "run: $jobid in $bay"
  printf '%s\t%s\t%s\n' "$bay" "$jobid" "$BAYS_DIR/$bay/.outputs/naust/$jobid"
  bash "$JOB_SCRIPT" "$bay" "$run" || rc=$?
  if [ "$rc" -eq 0 ]; then log "run: $jobid finished"; else log "run: $jobid finished with failures (see the report)"; fi
  return "$rc"
}

cmd_next() {
  # The first job in queue order that can have a bay runs; one that cannot
  # (its pinned bay is held, or its profile has no free bay) stays queued and
  # does not hold the ones behind it.
  local cand bay
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    bay="$(claim_for "$cand")" || continue
    run_job "$cand" "$bay"
    return $?
  done < <(bash "$HERE/queue.sh" order)
  log "run: nothing to run"
  return 0
}

cmd_job() {
  local cand="$1" bay
  [ -f "$cand" ] || die "run job: no queued job at $cand"
  bay="$(claim_for "$cand")" || return 2
  run_job "$cand" "$bay"
}

case "${1:-}" in
  next) cmd_next ;;
  job)  shift; [ $# -eq 1 ] || die "run job <queuefile>"; cmd_job "$1" ;;
  *) echo "usage: run.sh {next|job <queuefile>}" >&2; exit 2 ;;
esac

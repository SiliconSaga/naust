#!/usr/bin/env bash
# The tick, over and over, in a terminal kept open: start it when the machine
# is ready for jobs and stop it when the machine is wanted back. Every tick
# runs as a child, so its log lines reach the terminal as they happen and a
# Ctrl-C reaches this loop at once rather than when the tick ends.
#
# Ctrl-C between ticks just ends the loop. Ctrl-C during a tick kills it: a
# tick between jobs leaves nothing behind, and one in the middle of a job
# leaves its lock and a busy bay, both of which are put right here, since the
# next job resets its bay before touching it. The job itself is abandoned,
# and its PR is not called in again until someone asks: `naust dock` runs it.
#
#   watch.sh [--every <duration>]    5m by default; 30s, 2m and 1h are durations
set -euo pipefail
# Job control, so each tick runs in a process group of its own: the stop then
# reaches the whole tick, run.sh, job.sh and the build under them, and not only
# the tick's bash. A background job of a plain script has INT ignored and no
# group of its own, so neither a Ctrl-C nor a TERM to its pid would end its job.
set -m
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
TICK="${NAUST_TICK_SCRIPT:-$HERE/tick.sh}"

every=5m
while [ $# -gt 0 ]; do
  case "$1" in
    --every) every="${2:-}"; shift 2 ;;
    *) die "watch: unknown argument '$1'" ;;
  esac
done
[[ "$every" =~ ^([0-9]+)([smh]?)$ ]] || die "--every wants a duration like 30s, 5m or 1h, not '$every'"
case "${BASH_REMATCH[2]}" in
  m) secs=$(( BASH_REMATCH[1] * 60 )) ;;
  h) secs=$(( BASH_REMATCH[1] * 3600 )) ;;
  *) secs=$(( BASH_REMATCH[1] )) ;;
esac

STOP=0 CHILD="" IN_TICK=0
# shellcheck disable=SC2329   # the trap below calls it
on_signal() {
  STOP=1
  [ -z "$CHILD" ] || kill -TERM -- "-$CHILD" 2>/dev/null || true
}
trap on_signal INT TERM

# The tick is one bash and its job, and the build under that, are the rest of
# its process group. After a stop, wait for every member to go, and KILL what
# has not gone after a while, so nothing of the job is still writing to its
# bay when the bay is handed back. The TERM is repeated every two seconds on
# the way: a process the job was starting at the moment of the first one can
# miss it, while two seconds is long enough for a member's exit trap to finish
# before a second TERM cuts it short. This runs before the tick is reaped, so a
# tick that ignores TERM is killed too rather than waited on. The grace is 30 s;
# the tests shorten it.
GRACE="${NAUST_WATCH_GRACE:-30}"
group_gone() { # <pgid>
  local pgid="$1" i
  for i in $(seq 1 $(( GRACE * 2 ))); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    [ $(( i % 4 )) -ne 0 ] || kill -TERM -- "-$pgid" 2>/dev/null || true
    sleep 0.5
  done
  log "watch: the stopped tick's processes are still running after $GRACE s; killing them"
  kill -KILL -- "-$pgid" 2>/dev/null || true
  sleep 1
}

# Run a command as a child, in its own group with no terminal to read, and wait
# for it, so a signal during it runs the trap now. A stop that arrived before
# the start means nothing more starts, and one that arrived while the child was
# being started ends it as the trap would have.
run_child() {
  [ "$STOP" -eq 0 ] || return 0
  "$@" < /dev/null & CHILD=$!
  [ "$STOP" -eq 0 ] || kill -TERM -- "-$CHILD" 2>/dev/null || true
  wait "$CHILD" || true
  if [ "$STOP" -ne 0 ]; then
    group_gone "$CHILD"
    wait "$CHILD" 2>/dev/null || true
  fi
  CHILD=""
}

# The tick was killed. Its lock and the bay it was working are its leftovers,
# unless the lock is held by something still running, in which case the tick
# had found it held and was about to leave: nothing here is ours to touch.
# The bays are read under the lock, taken here, so no tick can start a job
# in between and have its bay mistaken for the stopped one's; a tick that got
# the lock first keeps its bays, and the stopped job's bay is freed by hand.
stopped_mid_tick() {
  local lock="$STATE_DIR/lock" owner f name job
  if [ -d "$lock" ]; then
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    case "$owner" in
      ''|*[!0-9]*) ;;
      *) if kill -0 "$owner" 2>/dev/null; then
           log "watch: the lock belongs to a running pid $owner, not to the stopped tick; left alone"
           return 0
         fi ;;
    esac
    rm -rf "$lock"
    log "watch: released the stopped tick's lock"
  fi
  if ! mkdir "$lock" 2>/dev/null; then
    log "watch: another tick took the lock already and its bays are its own; a bay left busy by the stopped job is freed by \`naust bay reset <name>\`"
    return 0
  fi
  printf '%s\n' "$$" > "$lock/pid"
  for f in "$STATE_DIR"/bays/*.state; do
    [ -f "$f" ] || continue
    [ "$(kv_get "$f" state)" = busy ] || continue
    name="$(basename "$f" .state)"; job="$(kv_get "$f" job)"
    kv_set "$f" state free; kv_set "$f" job ""; kv_set "$f" since "$(now)"
    log "watch: $name was busy with $job; freed, the next job's reset puts it back to base, and \`naust dock\` runs the abandoned PR again"
  done
  rm -rf "$lock"
}

# Everything this terminal shows also goes to a file, so someone (or an agent
# in another session) can follow the watch without sitting at it.
export NAUST_TEE_LOG="${NAUST_TEE_LOG:-$STATE_DIR/watch.log}"
mkdir -p "$(dirname "$NAUST_TEE_LOG")"
log "watch: a tick every $every; Ctrl-C stops it; this log is also $NAUST_TEE_LOG"
ticks=0
while :; do
  IN_TICK=1
  run_child bash "$TICK"
  [ "$STOP" -eq 0 ] || break
  IN_TICK=0
  ticks=$(( ticks + 1 ))
  if [ -n "${NAUST_WATCH_TICKS:-}" ] && [ "$ticks" -ge "$NAUST_WATCH_TICKS" ]; then exit 0; fi
  log "watch: next look in $every (Ctrl-C to stop)"
  run_child sleep "$secs"
  [ "$STOP" -eq 0 ] || break
done
[ "$IN_TICK" -eq 0 ] || stopped_mid_tick
log "watch: stopped"
exit 130

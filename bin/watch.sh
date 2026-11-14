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
  [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null || true
}
trap on_signal INT TERM

# Run a command as a child and wait for it, so a signal during it runs the trap
# now; after a stop, wait again so the child is gone before anything is cleaned.
run_child() {
  "$@" & CHILD=$!
  wait "$CHILD" || true
  [ "$STOP" -eq 0 ] || wait "$CHILD" 2>/dev/null || true
  CHILD=""
}

# The tick was killed. Its lock and the bay it was working are its leftovers,
# unless the lock is held by something still running, in which case the tick
# had found it held and was about to leave: nothing here is ours to touch.
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
  for f in "$STATE_DIR"/bays/*.state; do
    [ -f "$f" ] || continue
    [ "$(kv_get "$f" state)" = busy ] || continue
    name="$(basename "$f" .state)"; job="$(kv_get "$f" job)"
    kv_set "$f" state free; kv_set "$f" job ""; kv_set "$f" since "$(now)"
    log "watch: $name was busy with $job; freed, the next job's reset puts it back to base, and \`naust dock\` runs the abandoned PR again"
  done
}

log "watch: a tick every $every; Ctrl-C stops it"
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

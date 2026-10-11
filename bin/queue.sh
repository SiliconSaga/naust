#!/usr/bin/env bash
# The job queue: one key=value file per pull request under state/queue/.
#
#   queue.sh put <profile> <repo> <number> <head> <base> <author> <head_repo> [--priority N] [--with <csv>] [--bay <name>]
#   queue.sh next        queue.sh order        queue.sh drop <path>        queue.sh list
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config

job_path() { printf '%s/queue/%s__%s.job\n' "$STATE_DIR" "${1//\//__}" "$2"; }

cmd_put() {
  local profile="$1" repo="$2" number="$3" head="$4" base="$5" author="$6" head_repo="$7"
  shift 7
  local priority=0 with="" bay="" f
  while [ $# -gt 0 ]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      --with) with="$2"; shift 2 ;;
      --bay) bay="$2"; shift 2 ;;
      *) die "queue put: unknown argument '$1'" ;;
    esac
  done
  f="$(job_path "$repo" "$number")"
  if [ -f "$f" ] && [ "$(kv_get "$f" head)" = "$head" ]; then
    # The same head again: keep its place in the queue, but an operator's
    # `naust run` on top of a polled entry must not be lost. Priority only
    # rises; a named target or bay replaces an absent one.
    local changed=""
    if [ "$priority" -gt "$(kv_get "$f" priority)" ]; then kv_set "$f" priority "$priority"; changed="$changed priority=$priority"; fi
    if [ -n "$with" ] && [ "$with" != "$(kv_get "$f" with)" ]; then kv_set "$f" with "$with"; changed="$changed with=$with"; fi
    if [ -n "$bay" ] && [ "$bay" != "$(kv_get "$f" bay)" ]; then kv_set "$f" bay "$bay"; changed="$changed bay=$bay"; fi
    log "queue: $repo#$number at ${head:0:7} already queued${changed:+; updated:$changed}"
    return 0
  fi
  [ -f "$f" ] && log "queue: $repo#$number moved to ${head:0:7}, replacing the queued head"
  printf 'profile=%s\nrepo=%s\nnumber=%s\nhead=%s\nbase=%s\nauthor=%s\nhead_repo=%s\npriority=%s\nwith=%s\nbay=%s\nenqueued=%s\n' \
    "$profile" "$repo" "$number" "$head" "$base" "$author" "$head_repo" "$priority" "$with" "$bay" "$(now)" > "$f"
  log "queue: $repo#$number at ${head:0:7} queued (priority $priority)"
}

# Every queued job's path, highest priority first, then the earliest enqueued.
cmd_order() {
  local f
  for f in "$STATE_DIR"/queue/*.job; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(kv_get "$f" priority)" "$(kv_get "$f" enqueued)" "$f"
  done | sort -t $'\t' -k1,1nr -k2,2n | cut -f3
}

cmd_next() {
  local best
  best="$(cmd_order | sed -n 1p)"     # not head: it closes the pipe early and trips pipefail
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

cmd_drop() { rm -f "$1"; }

cmd_list() {
  local f
  for f in "$STATE_DIR"/queue/*.job; do
    [ -f "$f" ] || continue
    printf '%s#%s\t%s\tpriority %s\tenqueued %s\n' "$(kv_get "$f" repo)" "$(kv_get "$f" number)" "$(kv_get "$f" head)" "$(kv_get "$f" priority)" "$(kv_get "$f" enqueued)"
  done
}

case "${1:-}" in
  put)  shift; [ $# -ge 7 ] || die "queue put <profile> <repo> <number> <head> <base> <author> <head_repo> [...]"; cmd_put "$@" ;;
  next) cmd_next ;;
  order) cmd_order ;;
  drop) shift; cmd_drop "$1" ;;
  list) cmd_list ;;
  *) echo "usage: queue.sh {put|next|order|drop|list} ..." >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# naust's view of a bay: its state, and add/reset as the profile's hooks
# wrapped around what `ws bay` does. The workspace mechanics (clone, trust,
# fetch, reset, clean) are ws's; what a bay is *for* is here.
#
#   bay.sh add <name> --profile <p>     bay.sh reset <name> [--deep] [--keep <jobid>]
#   bay.sh list                         bay.sh release <name>
#   bay.sh claim <name> <jobid>         bay.sh set <name> <state>
#   bay.sh free-for <profile>           bay.sh repos <name>
#   bay.sh dir <name>                   bay.sh env <name>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config

bay_dir() { printf '%s/%s\n' "$BAYS_DIR" "$1"; }
bay_state_file() { printf '%s/bays/%s.state\n' "$STATE_DIR" "$1"; }
bay_state() { kv_get "$(bay_state_file "$1")" state; }
bay_profile() { kv_get "$(bay_state_file "$1")" profile; }
bay_known() { [ -f "$(bay_state_file "$1")" ]; }
bay_require() { bay_known "$1" || die "no bay named '$1' (naust bay list)"; }

bay_set_state() { # <name> <state> [job]
  local f; f="$(bay_state_file "$1")"
  kv_set "$f" state "$2"
  kv_set "$f" job "${3-$(kv_get "$f" job)}"
  kv_set "$f" since "$(now)"
}

# Export what hooks and profile commands rely on.
bay_env() { # <name>
  local dir profile comp
  dir="$(bay_dir "$1")"; profile="$(bay_profile "$1")"
  comp="$(prof "$profile" .component)"
  [ -n "$comp" ] || die "profile $profile has no component"
  export NAUST_BAY_DIR="$dir" NAUST_BAY_NAME="$1" NAUST_PROFILE="$profile"
  export NAUST_COMP_DIR="$dir/components/$comp"
  export NAUST_REALM_DIR="$dir/realms/$REALM"
  export GRADLE_USER_HOME="$GRADLE_HOME"
}

# Run a profile command or hook in the component dir, through the bay's own
# ws exec like every other step, so it sees the bay's environment and never
# this process's. Empty means skip. A failure marks the bay broken: a bay
# whose warm-up or hook died is not one a job may use, and set -e would
# otherwise exit before anything recorded that.
bay_run_in_comp() { # <label> <command>
  [ -n "$2" ] || return 0
  log "$1: $2"
  if ! bay_ws "$NAUST_BAY_NAME" exec "$(basename "$NAUST_COMP_DIR")" bash -c "$2"; then
    bay_set_state "$NAUST_BAY_NAME" broken
    die "$1 failed in $NAUST_BAY_NAME; bay marked broken"
  fi
}

cmd_repos() {
  bay_require "$1"; bay_env "$1"
  local g d comp
  comp="$(basename "$NAUST_COMP_DIR")"
  printf '%s\n' "$NAUST_COMP_DIR"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    for d in "$NAUST_COMP_DIR"/$g; do
      [ -d "$d/.git" ] && printf '%s\n' "$d"
    done
  done < <(adapter_list "$comp" .nested)
}

cmd_env() {
  bay_require "$1"; bay_env "$1"
  local v
  for v in NAUST_BAY_DIR NAUST_BAY_NAME NAUST_PROFILE NAUST_COMP_DIR NAUST_REALM_DIR GRADLE_USER_HOME; do
    printf 'export %s=%q\n' "$v" "${!v}"
  done
}

cmd_reset() {
  local name="$1" deep="" keep="" started d
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --deep) deep="--deep"; shift ;;
      --keep) keep="$2"; shift 2 ;;
      *) die "bay reset: unknown argument '$1'" ;;
    esac
  done
  bay_require "$name"; bay_env "$name"
  started="$(now)"
  log "reset $name: ws bay reset${deep:+ $deep}"
  if ! bash "$WS" bay reset "$name" ${deep:+"$deep"}; then
    bay_set_state "$name" broken
    die "reset $name: ws bay reset failed; bay marked broken"
  fi
  # Previous jobs' outputs go. The job that is resetting keeps its own
  # directory: its log of this very step is open there, and Windows refuses
  # to delete a directory holding an open file.
  for d in "$NAUST_BAY_DIR"/.outputs/naust/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "$keep" ] || rm -rf "$d"
  done
  bay_run_in_comp "after_reset" "$(prof "$NAUST_PROFILE" .hooks.after_reset)"
  bay_set_state "$name" free ""
  log "reset $name: free in $(( $(now) - started )) s"
}

cmd_add() {
  local name="$1" profile="" comp from
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      *) die "bay add: unknown argument '$1'" ;;
    esac
  done
  [ -n "$profile" ] || die "bay add: --profile <name> is required"
  [ -f "$PROFILE_DIR/$profile.yaml" ] || die "bay add: no profile $PROFILE_DIR/$profile.yaml"
  ! bay_known "$name" || die "bay add: naust already has a bay named $name"
  comp="$(prof "$profile" .component)"
  [ -n "$comp" ] || die "profile $profile has no component"
  from="$(cfg .workspace_repo)"
  log "add $name: ws bay add --with $comp --realm $REALM${from:+ --from $from}"
  bash "$WS" bay add "$name" --with "$comp" --realm "$REALM" ${from:+--from "$from"}
  printf 'state=provisioning\nprofile=%s\njob=\nsince=%s\n' "$profile" "$(now)" > "$(bay_state_file "$name")"
  bay_env "$name"
  log "add $name: warming the Gradle cache"
  if ! bay_ws "$name" build "$comp"; then
    bay_set_state "$name" broken
    die "add $name: ws build $comp failed; bay marked broken"
  fi
  bay_run_in_comp "compile_all" "$(prof "$profile" .steps.compile_all)"
  bay_run_in_comp "after_add" "$(prof "$profile" .hooks.after_add)"
  cmd_reset "$name"
}

cmd_list() {
  local f name state profile job since
  for f in "$STATE_DIR"/bays/*.state; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .state)"
    state="$(kv_get "$f" state)"; profile="$(kv_get "$f" profile)"
    job="$(kv_get "$f" job)"; since="$(kv_get "$f" since)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$state" "$profile" "$job" "$(( $(now) - ${since:-$(now)} ))"
  done
}

cmd_claim() {
  bay_require "$1"
  [ "$(bay_state "$1")" = free ] || { log "claim $1: not free ($(bay_state "$1"))"; return 1; }
  bay_set_state "$1" busy "$2"
}

cmd_release() {
  bay_require "$1"
  case "$(bay_state "$1")" in
    ready|held) bay_set_state "$1" free "" ;;
    *) die "release $1: state is $(bay_state "$1"), only ready or held can be released" ;;
  esac
}

cmd_set() {
  bay_require "$1"
  case "$2" in free|busy|ready|held|broken) ;; *) die "set: unknown state '$2'" ;; esac
  bay_set_state "$1" "$2"
}

cmd_free_for() {
  local profile="$1" f name ttl since
  ttl="$(prof "$profile" .bay.ready_ttl_days 7)"
  for f in "$STATE_DIR"/bays/*.state; do
    [ -f "$f" ] || continue
    [ "$(kv_get "$f" profile)" = "$profile" ] || continue
    name="$(basename "$f" .state)"
    if [ "$(kv_get "$f" state)" = ready ]; then
      since="$(kv_get "$f" since)"
      if [ $(( $(now) - since )) -gt $(( ttl * 86400 )) ]; then
        log "free-for: $name ready for more than $ttl days, back in the pool"
        bay_set_state "$name" free ""
      fi
    fi
    if [ "$(kv_get "$f" state)" = free ]; then printf '%s\n' "$name"; return 0; fi
  done
  return 1
}

case "${1:-}" in
  add)      shift; [ $# -ge 1 ] || die "bay add <name> --profile <p>"; cmd_add "$@" ;;
  reset)    shift; [ $# -ge 1 ] || die "bay reset <name> [--deep] [--keep <jobid>]"; cmd_reset "$@" ;;
  list)     cmd_list ;;
  release)  shift; cmd_release "$1" ;;
  claim)    shift; cmd_claim "$1" "$2" ;;
  set)      shift; cmd_set "$1" "$2" ;;
  free-for) shift; cmd_free_for "$1" ;;
  repos)    shift; cmd_repos "$1" ;;
  env)      shift; cmd_env "$1" ;;
  dir)      shift; bay_require "$1"; bay_dir "$1" ;;
  *) echo "usage: bay.sh {add|reset|list|release|claim|set|free-for|repos|env|dir} ..." >&2; exit 2 ;;
esac

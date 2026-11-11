#!/usr/bin/env bash
# Shared helpers for naust: logging, config, state files, the tick lock.
# Sourced, never executed. Every script that sources it calls load_config.
#
# naust lives in a yggdrasil workspace at components/naust and keeps its
# machine-local config and state in that workspace's bays/.naust/. Profiles,
# the trust list and the adapters come from the workspace's realm checkout.

NAUST_WORKSPACE="${NAUST_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
NAUST_DIR="${NAUST_DIR:-$NAUST_WORKSPACE/bays/.naust}"
NAUST_CONFIG="${NAUST_CONFIG:-$NAUST_DIR/naust.yaml}"
NAUST_ENV_FILE="${NAUST_ENV_FILE:-$NAUST_WORKSPACE/.env}"

# Log lines go to stderr, or to NAUST_LOG when set (the tests set it, so a
# script's stdout stays an exact contract and the log is grepped on its own).
# With a bay in scope (bay_env sets NAUST_BAY_LOG) every line also lands in
# that bay's log, the one `ws bay log <name>` tails, so whoever watches the
# bay sees naust's steps in order with everything ws bay wrote there.
log() {
  local line; line="$(printf '%s naust: %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*")"
  if [ -n "${NAUST_LOG:-}" ]; then printf '%s\n' "$line" >> "$NAUST_LOG"; else printf '%s\n' "$line" >&2; fi
  if [ -n "${NAUST_BAY_LOG:-}" ] && [ -d "${NAUST_BAY_LOG%/*}" ]; then printf '%s\n' "$line" >> "$NAUST_BAY_LOG" 2>/dev/null || true; fi
}
die() { log "ERROR: $*"; [ -n "${NAUST_LOG:-}" ] && printf 'naust: ERROR: %s\n' "$*" >&2; exit 1; }
# Overridable so tests get a fixed clock.
now() { printf '%s\n' "${NAUST_NOW:-$(date +%s)}"; }
require_tool() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH"; }

# One scalar from a YAML file, with a default when absent or null. Not
# `path // default`: yq treats a YAML false as missing under //, and
# `skip_drafts: false` must read back as false.
#
# A file yq cannot read is an error, never a default: a malformed naust.yaml
# read as "no profiles" would make a tick poll nothing and say nothing.
_yq_scalar() { # <file> <path> [default]
  local v=""
  if [ -f "$1" ]; then
    v="$(yq "$2" "$1" 2>&1)" || die "cannot read $2 from $1: $v"
  fi
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s\n' "${3:-}"; else printf '%s\n' "$v"; fi
}
# A YAML list, one item per line (empty when absent).
_yq_list() { # <file> <path>
  [ -f "$1" ] || return 0
  yq "($2 // [])[]" "$1" || die "cannot read $2 from $1"
}
# A YAML map's keys, one per line (empty when absent).
_yq_keys() { # <file> <path>
  [ -f "$1" ] || return 0
  yq "($2 // {}) | keys | .[]" "$1" || die "cannot read $2 from $1"
}

cfg() { _yq_scalar "$NAUST_CONFIG" "$1" "${2:-}"; }
cfg_list() { _yq_list "$NAUST_CONFIG" "$1"; }
prof() { _yq_scalar "$PROFILE_DIR/$1.yaml" "$2" "${3:-}"; }
prof_list() { _yq_list "$PROFILE_DIR/$1.yaml" "$2"; }
trust() { _yq_scalar "$PROFILE_DIR/trust.yaml" ".$1$2" "${3:-}"; }
trust_keys() { _yq_keys "$PROFILE_DIR/trust.yaml" ".$1$2"; }
adapter() { _yq_scalar "$ADAPTER_DIR/$1.yaml" "$2" "${3:-}"; }
adapter_list() { _yq_list "$ADAPTER_DIR/$1.yaml" "$2"; }

load_config() {
  [ -f "$NAUST_CONFIG" ] || die "no config at $NAUST_CONFIG (copy naust.example.yaml there)"
  require_tool yq; require_tool git
  WORKSPACE="$NAUST_WORKSPACE"
  WS="$WORKSPACE/scripts/ws"
  [ -f "$WS" ] || die "no scripts/ws at $WORKSPACE; naust must sit in a yggdrasil workspace (or set NAUST_WORKSPACE)"
  REALM="$(cfg .realm)"
  [ -n "$REALM" ] || REALM="$(_yq_scalar "$WORKSPACE/ecosystem.local.yaml" .realm)"
  [ -n "$REALM" ] || die "realm is required: set realm: in $NAUST_CONFIG or activate one with ws realm use"
  REALM_DIR="$WORKSPACE/realms/$REALM"
  PROFILE_DIR="$REALM_DIR/naust"
  ADAPTER_DIR="$REALM_DIR/adapters"
  [ -d "$PROFILE_DIR" ] || die "no profiles at $PROFILE_DIR"
  BAYS_DIR="$WORKSPACE/bays"
  STATE_DIR="$NAUST_DIR/state"
  GRADLE_HOME="$NAUST_DIR/gradle-home"
  LOCK_STALE_HOURS="$(cfg .lock_stale_hours 6)"
  # Checked here, since with_lock does arithmetic on it under set -u: a word
  # would end the tick without the lock ever being taken, a leading zero
  # would read as octal, and a long enough number would overflow the seconds.
  [[ "$LOCK_STALE_HOURS" =~ ^[0-9]{1,6}$ ]] || die "lock_stale_hours must be a whole number of hours, up to six digits, not '$LOCK_STALE_HOURS' ($NAUST_CONFIG)"
  LOCK_STALE_HOURS=$((10#$LOCK_STALE_HOURS))
  mkdir -p "$STATE_DIR/queue" "$STATE_DIR/seen" "$STATE_DIR/jobs" "$STATE_DIR/bays" "$GRADLE_HOME"
  export WORKSPACE WS REALM REALM_DIR PROFILE_DIR ADAPTER_DIR BAYS_DIR STATE_DIR GRADLE_HOME LOCK_STALE_HOURS
}

# Everything that runs inside a bay goes through the parent's `ws bay exec`,
# which runs the bay's own ws from the bay with this workspace's roots and
# every key its .env defines unset. That scrub knows only the .env's keys, so
# a GH_TOKEN merely inherited from the shell or the tick is dropped here,
# before ws is reached, and nothing the PR controls ever sees one. It goes
# through only when the caller asks by setting NAUST_PASS_GH_TOKEN for the
# one call: job.sh does so for its two review calls alone. GITHUB_TOKEN, which
# gh reads just the same, is never passed and always dropped.
bay_ws() { # <bay> <ws-args...>
  local bay="$1"; shift
  if [ -n "${NAUST_PASS_GH_TOKEN:-}" ]; then
    env -u GITHUB_TOKEN bash "$WS" bay exec --pass GH_TOKEN "$bay" "$@"
  else
    env -u GH_TOKEN -u GITHUB_TOKEN bash "$WS" bay exec "$bay" "$@"
  fi
}

# Read one value out of the workspace's .env, literally: the optional `export `
# prefix is stripped, surrounding quotes are removed, nothing is evaluated.
env_value() {
  local key="$1" line
  [ -f "$NAUST_ENV_FILE" ] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$NAUST_ENV_FILE" | tail -n1)" || true
  [ -n "$line" ] || return 0
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s\n' "$line"
}

# Give this process the machine account's token for its own gh calls. Only the
# tick and naust dock call it; job.sh unsets GH_TOKEN before PR code runs. No
# token is an error, not a fallback: gh would otherwise use whatever token or
# stored login the environment carries, and naust posts as nobody but the
# machine account.
gh_auth() {
  local t; t="$(env_value NAUST_GITHUB_TOKEN)"
  [ -n "$t" ] || die "NAUST_GITHUB_TOKEN is not set in $NAUST_ENV_FILE; naust never borrows another account's token"
  export GH_TOKEN="$t"
}

# key=value state files. Keys are [A-Za-z0-9_], values are single lines.
kv_get() { # <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n1
}
kv_set() { # <file> <key> <value>
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$file.XXXXXX")"          # beside its destination, so the mv is a rename and a reader never sees half a file
  { [ -f "$file" ] && grep -v "^$key=" "$file" || true; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  mv "$tmp" "$file"
}

# A file's modification time as an epoch, on GNU (Linux, Git Bash) and BSD
# (macOS) stat alike. Fails when neither form works.
file_mtime() { # <path>
  stat -c %Y "$1" 2>/dev/null && return 0
  stat -f %m "$1" 2>/dev/null
}

# The tick lock: a directory, because mkdir is atomic everywhere. Holds the pid
# of the tick that took it. A lock older than LOCK_STALE_HOURS belongs to a tick
# that died without cleaning up and is reclaimed; a job never runs that long. A
# lock whose age cannot be read is treated as fresh: two jobs on one host is
# the worse failure.
#
# Reclaiming renames the stale directory away before removing it, so of two
# ticks that both find it stale only the one whose rename succeeds removes
# anything, and neither can remove a lock the other has just made. Releasing
# checks the pid first for the same reason.
with_lock() {
  local lock="$STATE_DIR/lock" age mtime stale owner
  if ! mkdir "$lock" 2>/dev/null; then
    if ! mtime="$(file_mtime "$lock")"; then
      log "cannot read the age of $lock; treating it as held"
      return 1
    fi
    age=$(( $(now) - mtime ))
    [ "$age" -gt $(( LOCK_STALE_HOURS * 3600 )) ] || return 1
    # Old is not the same as dead: a job past the stale age with its tick
    # still running keeps the lock, or a second job would start beside it.
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    case "$owner" in
      ''|*[!0-9]*) ;;
      *) if kill -0 "$owner" 2>/dev/null; then log "lock is $age s old but its tick (pid $owner) is still running; leaving it"; return 1; fi ;;
    esac
    stale="$lock.stale.$$"
    if mv "$lock" "$stale" 2>/dev/null; then
      log "reclaiming a lock $age s old (pid $(cat "$stale/pid" 2>/dev/null || echo '?'))"
      rm -rf "$stale"
    fi
    mkdir "$lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$lock/pid"
  trap 'release_lock' EXIT
  return 0
}
release_lock() {
  local lock="$STATE_DIR/lock"
  if [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$lock"; fi
  return 0
}

# Escape a string for use inside a JSON string literal: backslash, quote, the
# named controls, and every other control character as \u00XX, since a stray
# one from a log tail would otherwise make the whole payload invalid JSON.
# No subshells: printf -v builds each character. A bash string cannot hold NUL.
json_escape() {
  local s="$1" i hex c
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v hex '%02x' "$i"
    printf -v c '%b' "\\x$hex"
    s="${s//"$c"/\\u00$hex}"
  done
  printf '%s' "$s"
}

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
log() {
  local line; line="$(printf '%s naust: %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*")"
  if [ -n "${NAUST_LOG:-}" ]; then printf '%s\n' "$line" >> "$NAUST_LOG"; else printf '%s\n' "$line" >&2; fi
}
die() { log "ERROR: $*"; [ -n "${NAUST_LOG:-}" ] && printf 'naust: ERROR: %s\n' "$*" >&2; exit 1; }
# Overridable so tests get a fixed clock.
now() { printf '%s\n' "${NAUST_NOW:-$(date +%s)}"; }
require_tool() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH"; }

# One scalar from a YAML file, with a default when absent or null. Not
# `path // default`: yq treats a YAML false as missing under //, and
# `skip_drafts: false` must read back as false.
_yq_scalar() { # <file> <path> [default]
  local v=""
  [ -f "$1" ] && { v="$(yq "$2" "$1" 2>/dev/null)" || v=""; }
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s\n' "${3:-}"; else printf '%s\n' "$v"; fi
}
# A YAML list, one item per line (empty when absent).
_yq_list() { # <file> <path>
  [ -f "$1" ] || return 0
  yq "($2 // [])[]" "$1" 2>/dev/null || true
}

cfg() { _yq_scalar "$NAUST_CONFIG" "$1" "${2:-}"; }
cfg_list() { _yq_list "$NAUST_CONFIG" "$1"; }
prof() { _yq_scalar "$PROFILE_DIR/$1.yaml" "$2" "${3:-}"; }
prof_list() { _yq_list "$PROFILE_DIR/$1.yaml" "$2"; }
trust() { _yq_scalar "$PROFILE_DIR/trust.yaml" ".$1$2" "${3:-}"; }
trust_list() { _yq_list "$PROFILE_DIR/trust.yaml" ".$1$2"; }
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
  mkdir -p "$STATE_DIR/queue" "$STATE_DIR/seen" "$STATE_DIR/jobs" "$STATE_DIR/bays" "$GRADLE_HOME"
  export WORKSPACE WS REALM REALM_DIR PROFILE_DIR ADAPTER_DIR BAYS_DIR STATE_DIR GRADLE_HOME LOCK_STALE_HOURS
}

# Everything that runs inside a bay goes through the parent's `ws bay exec`,
# which runs the bay's own ws from the bay with this workspace's roots and
# every key its .env defines unset. GH_TOKEN is passed through only when the
# caller set it on purpose: job.sh unsets it first thing and sets it for the
# two review calls alone, so nothing the PR controls ever sees a token.
bay_ws() { # <bay> <ws-args...>
  local bay="$1"; shift
  bash "$WS" bay exec ${GH_TOKEN:+--pass GH_TOKEN} "$bay" "$@"
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
# tick and naust run call it; job.sh unsets GH_TOKEN before PR code runs. No
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
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$lock"
  return 0
}

# Escape a string for use inside a JSON string literal. Enough for the Discord
# payload and the comment body: backslash, quote, newline, tab, carriage return.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

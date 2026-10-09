#!/usr/bin/env bash
# Post to the Discord webhook from outside any agent session. Optional: with no
# webhook configured every call is a logged no-op, so a bay machine without
# Discord still runs jobs.
#
#   notify.sh say <text> [--file <path>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"

MAX_CONTENT=1900   # Discord's ceiling is 2000; leave room for the ellipsis

cmd_say() {
  local text="" file="" hook
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="$2"; shift 2 ;;
      *) text="$1"; shift ;;
    esac
  done
  [ -n "$text" ] || die "notify say: text is required"
  hook="$(env_value NAUST_DISCORD_WEBHOOK)"
  if [ -z "$hook" ]; then
    log "no NAUST_DISCORD_WEBHOOK in $NAUST_ENV_FILE; not posting: ${text:0:80}"
    return 0
  fi
  if [ "${#text}" -gt "$MAX_CONTENT" ]; then
    text="${text:0:$MAX_CONTENT} …"
  fi
  local payload
  payload="{\"content\":\"$(json_escape "$text")\"}"
  if [ -n "$file" ]; then
    [ -f "$file" ] || die "notify say: no such file $file"
    curl -fsS --connect-timeout 5 --max-time 60 -F "payload_json=$payload" -F "file=@$file" "$hook" >/dev/null
  else
    curl -fsS --connect-timeout 5 --max-time 30 -F "payload_json=$payload" "$hook" >/dev/null
  fi
}

case "${1:-}" in
  say) shift; cmd_say "$@" ;;
  *) echo "usage: notify.sh say <text> [--file <path>]" >&2; exit 2 ;;
esac

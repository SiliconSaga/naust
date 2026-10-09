#!/usr/bin/env bash
# Poll one profile's repository for open pull requests and emit the ones that
# deserve a job: new or moved heads, past the debounce, not yet queued at that
# head, not drafts while skip_drafts is on. Seen-state lives in state/seen/<repo>/<n>.
#
#   poll.sh candidates <profile>
#   poll.sh mark <profile> <number> queued|notified <sha>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
require_tool gh

PR_FIELDS='number,headRefOid,baseRefName,author,headRepositoryOwner,headRepository,isDraft,updatedAt'
PR_SHAPE='.[] | [.number, .headRefOid, .baseRefName, .author.login, ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // "")), (.isDraft|tostring), .updatedAt] | @tsv'

seen_dir() { printf '%s/seen/%s\n' "$STATE_DIR" "${1//\//__}"; }

cmd_candidates() {
  local profile="$1" repo debounce skip_drafts dir tmp open=" "
  local number sha base author head_repo draft f first_seen age
  repo="$(prof "$profile" .repo)"; [ -n "$repo" ] || die "profile $profile has no repo"
  debounce="$(prof "$profile" .poll.debounce_minutes 10)"
  skip_drafts="$(prof "$profile" .poll.skip_drafts true)"
  dir="$(seen_dir "$repo")"; mkdir -p "$dir"
  tmp="$(mktemp)"
  gh pr list --repo "$repo" --state open --limit 100 --json "$PR_FIELDS" --jq "$PR_SHAPE" > "$tmp"
  while IFS=$'\t' read -r number sha base author head_repo draft _; do
    [ -n "$number" ] || continue
    open="$open$number "
    f="$dir/$number"
    if [ "$(kv_get "$f" sha)" != "$sha" ]; then
      kv_set "$f" sha "$sha"
      kv_set "$f" first_seen "$(now)"
      log "poll: $repo#$number at ${sha:0:7} (${author}) seen"
    fi
    if [ "$draft" = true ] && [ "$skip_drafts" = true ]; then
      continue
    fi
    [ "$(kv_get "$f" queued)" = "$sha" ] && continue
    first_seen="$(kv_get "$f" first_seen)"
    age=$(( $(now) - first_seen ))
    if [ "$age" -lt $(( debounce * 60 )) ]; then
      log "poll: $repo#$number debouncing (${age}s of $((debounce * 60))s)"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile" "$repo" "$number" "$sha" "$base" "$author" "$head_repo"
  done < "$tmp"
  rm -f "$tmp"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    number="$(basename "$f")"
    case "$open" in
      *" $number "*) ;;
      *) log "poll: $repo#$number is no longer open; forgetting it"
         rm -f "$f" "$STATE_DIR/queue/${repo//\//__}__$number.job" ;;
    esac
  done
}

cmd_mark() {
  local profile="$1" number="$2" key="$3" sha="$4" repo
  repo="$(prof "$profile" .repo)"
  case "$key" in queued|notified) ;; *) die "poll mark: key must be queued or notified" ;; esac
  mkdir -p "$(seen_dir "$repo")"          # naust run marks a PR no poll has seen yet
  kv_set "$(seen_dir "$repo")/$number" "$key" "$sha"
}

case "${1:-}" in
  candidates) shift; cmd_candidates "$1" ;;
  mark) shift; [ $# -eq 4 ] || die "poll mark <profile> <number> queued|notified <sha>"; cmd_mark "$@" ;;
  *) echo "usage: poll.sh {candidates <profile>|mark <profile> <number> queued|notified <sha>}" >&2; exit 2 ;;
esac

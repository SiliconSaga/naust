#!/usr/bin/env bash
# Poll one profile's repository for open pull requests and emit the ones the
# gate should look at: every PR whose head is not already queued and on which
# something has happened since the gate last looked (a push, a review, a
# comment all move GitHub's updatedAt), so a quiet PR costs no review read.
# Seen-state lives in state/seen/<repo>/<n>.
#
#   poll.sh candidates <profile>
#   poll.sh mark <profile> <number> queued <sha>
#   poll.sh mark <profile> <number> gated <updatedAt>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
require_tool gh

PR_FIELDS='number,headRefOid,baseRefName,author,headRepositoryOwner,headRepository,isDraft,updatedAt'
PR_LIMIT=500   # a list this long may be cut off, and a cut-off list must not read as "the rest closed"
PR_SHAPE='.[] | [.number, .headRefOid, .baseRefName, .author.login, ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // "")), (.isDraft|tostring), .updatedAt] | @tsv'

seen_dir() { printf '%s/seen/%s\n' "$STATE_DIR" "${1//\//__}"; }

cmd_candidates() {
  local profile="$1" repo dir tmp open=" " count=0
  local number sha base author head_repo updated f q
  repo="$(prof "$profile" .repo)"; [ -n "$repo" ] || die "profile $profile has no repo"
  dir="$(seen_dir "$repo")"; mkdir -p "$dir"
  tmp="$(mktemp)"
  gh pr list --repo "$repo" --state open --limit "$PR_LIMIT" --json "$PR_FIELDS" --jq "$PR_SHAPE" > "$tmp"
  while IFS=$'\t' read -r number sha base author head_repo _ updated; do   # the draft flag is listed but not read: a call is a call
    [ -n "$number" ] || continue
    open="$open$number "
    count=$((count + 1))
    f="$dir/$number"
    if [ "$(kv_get "$f" sha)" != "$sha" ]; then
      kv_set "$f" sha "$sha"
      log "poll: $repo#$number at ${sha:0:7} (${author}) seen"
    fi
    if [ "$(kv_get "$f" queued)" = "$sha" ]; then
      # A queued head is not read again, but the PR can be retargeted while
      # it waits, and the job must test against the base it has now.
      q="$STATE_DIR/queue/${repo//\//__}__$number.job"
      if [ -f "$q" ] && [ -n "$base" ] && [ "$(kv_get "$q" base)" != "$base" ]; then
        kv_set "$q" base "$base"
        log "poll: $repo#$number now targets $base; the queued job follows"
      fi
      continue
    fi
    [ "$(kv_get "$f" gated)" = "$updated" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile" "$repo" "$number" "$sha" "$base" "$author" "$head_repo" "$updated"
  done < "$tmp"
  rm -f "$tmp"
  if [ "$count" -ge "$PR_LIMIT" ]; then
    log "poll: $repo has $count open PRs, the most one poll reads; not forgetting any"
    return 0
  fi
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
  local profile="$1" number="$2" key="$3" value="$4" repo
  repo="$(prof "$profile" .repo)"
  case "$key" in queued|gated) ;; *) die "poll mark: key must be queued or gated" ;; esac
  mkdir -p "$(seen_dir "$repo")"          # naust dock marks a PR no poll has seen yet
  kv_set "$(seen_dir "$repo")/$number" "$key" "$value"
}

case "${1:-}" in
  candidates) shift; cmd_candidates "$1" ;;
  mark) shift; [ $# -eq 4 ] || die "poll mark <profile> <number> queued|gated <value>"; cmd_mark "$@" ;;
  *) echo "usage: poll.sh {candidates <profile>|mark <profile> <number> queued|gated <value>}" >&2; exit 2 ;;
esac

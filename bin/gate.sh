#!/usr/bin/env bash
# The trust gate: may this pull request head run in a bay, and why.
#
#   gate.sh decide <profile> <repo> <number> <author> <head_repo> <head>
#
# Prints "run<TAB>reason" or "nod<TAB>reason". A nod is a review, because
# GitHub records the commit every review was submitted against: an approval
# or an "ok to test" from a maintainer admits that commit and no other. A
# label cannot say which commit it meant, so labels are never read.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
require_tool gh

has_line() { grep -qxF -- "$1"; }          # stdin: one candidate per line
has_line_ci() { grep -qxiF -- "$1"; }

cmd_decide() {
  local profile="$1" repo="$2" number="$3" author="$4" head_repo="$5" head="$6"
  local maintainers trusted phrase lphrase reviews login state oid has_phrase ignored="" stale="" why
  maintainers="$(trust_list "$profile" .maintainers)"
  trusted="$(trust_list "$profile" .trusted)"
  if printf '%s\n' "$maintainers" | has_line "$author"; then
    printf 'run\tauthor %s is a maintainer\n' "$author"; return 0
  fi
  if printf '%s\n' "$trusted" | has_line "$author"; then
    printf 'run\tauthor %s is trusted\n' "$author"; return 0
  fi
  if printf '%s\n' "$trusted" | has_line_ci "$head_repo"; then
    printf 'run\thead repository %s is trusted\n' "$head_repo"; return 0
  fi
  phrase="$(trust "$profile" .nod_phrase 'ok to test')"
  lphrase="$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')"
  # The phrase sits inside a jq string literal (gh's --jq takes no --arg), so
  # its backslashes and quotes are escaped for jq; nothing else is special there.
  lphrase="${lphrase//\\/\\\\}"; lphrase="${lphrase//\"/\\\"}"
  reviews="$(gh pr view "$number" --repo "$repo" --json reviews \
      --jq ".reviews[] | [.author.login, .state, (.commit.oid // \"\"), (((.body // \"\") | ascii_downcase | contains(\"$lphrase\")) | tostring)] | @tsv" 2>/dev/null || true)"
  while IFS=$'\t' read -r login state oid has_phrase; do
    [ -n "$login" ] || continue
    [ "$state" != DISMISSED ] || continue
    if [ "$state" != APPROVED ] && [ "$has_phrase" != true ]; then continue; fi
    if ! printf '%s\n' "$maintainers" | has_line "$login"; then
      ignored="${ignored:+$ignored; }nod from $login"
      continue
    fi
    if [ "$oid" = "$head" ]; then
      if [ "$state" = APPROVED ]; then
        printf 'run\tapproved at %s by maintainer %s\n' "${oid:0:7}" "$login"
      else
        printf 'run\t"%s" at %s from maintainer %s\n' "$phrase" "${oid:0:7}" "$login"
      fi
      return 0
    fi
    stale="${stale:+$stale; }$login approved ${oid:0:7}, head is ${head:0:7}"
  done <<< "$reviews"
  why="needs a nod from a maintainer"
  [ -n "$stale" ] && why="$why (stale: $stale)"
  [ -n "$ignored" ] && why="$why (ignored: $ignored)"
  printf 'nod\t%s\n' "$why"
}

case "${1:-}" in
  decide) shift; [ $# -eq 6 ] || die "gate decide <profile> <repo> <number> <author> <head_repo> <head>"; cmd_decide "$@" ;;
  *) echo "usage: gate.sh decide <profile> <repo> <number> <author> <head_repo> <head>" >&2; exit 2 ;;
esac

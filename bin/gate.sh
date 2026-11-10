#!/usr/bin/env bash
# The gate: has someone called this pull request head into one of this
# naust's bays, and who.
#
#   gate.sh decide <profile> <repo> <number> <head>
#
# Prints "run<TAB>reason" or "wait<TAB>reason". Nothing runs unasked. A call
# is a review on the PR whose text says the realm's phrase addressed to this
# naust's machine account ("@agent-refr haul it in"), from a login the realm
# lists under forges. GitHub records the commit every review was submitted
# against, so a call admits that commit and no other; a push after it needs
# a new call. A review aimed at another naust's account is not for this one.
# Approvals are a verdict on the code, not a request to run it, and labels
# cannot say which commit they meant: neither is read.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
require_tool gh

has_line() { grep -qxF -- "$1"; }          # stdin: one candidate per line

# The phrase and the address sit inside a jq string literal (gh's --jq takes
# no --arg), so backslashes and quotes are escaped for jq; nothing else is
# special there.
jq_literal() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

cmd_decide() {
  local profile="$1" repo="$2" number="$3" head="$4"
  local account forges phrase lphrase laddress reviews login state oid called ignored="" stale="" why
  account="$(cfg .account)"
  [ -n "$account" ] || die "account: is not set in $NAUST_CONFIG; naust cannot tell which calls are for it"
  forges="$(trust_keys "$profile" .forges)"
  phrase="$(trust "$profile" .nod_phrase 'haul it in')"
  lphrase="$(jq_literal "$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')")"
  laddress="$(jq_literal "@$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]')")"
  reviews="$(gh pr view "$number" --repo "$repo" --json reviews \
      --jq ".reviews[] | [.author.login, .state, (.commit.oid // \"\"), (((.body // \"\") | ascii_downcase) as \$b | (\$b | contains(\"$lphrase\")) and (\$b | contains(\"$laddress\")) | tostring)] | @tsv" 2>/dev/null || true)"
  while IFS=$'\t' read -r login state oid called; do
    [ -n "$login" ] || continue
    [ "$state" != DISMISSED ] || continue
    [ "$called" = true ] || continue
    if ! printf '%s\n' "$forges" | has_line "$login"; then
      ignored="${ignored:+$ignored; }a call from $login"
      continue
    fi
    if [ "$oid" = "$head" ]; then
      printf 'run\tcalled in by %s at %s\n' "$login" "${oid:0:7}"
      return 0
    fi
    stale="${stale:+$stale; }$login called ${oid:0:7} in"
  done <<< "$reviews"
  why="no one listed has called ${head:0:7} in"
  [ -n "$stale" ] && why="$why (stale: $stale)"
  [ -n "$ignored" ] && why="$why (ignored: $ignored)"
  printf 'wait\t%s\n' "$why"
}

case "${1:-}" in
  decide) shift; [ $# -eq 4 ] || die "gate decide <profile> <repo> <number> <head>"; cmd_decide "$@" ;;
  *) echo "usage: gate.sh decide <profile> <repo> <number> <head>" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# One tick: poll, gate, queue, run at most one job, exit. The OS scheduler
# calls this every few minutes; the lock makes overlapping ticks harmless and
# a crashed tick's lock is reclaimed after LOCK_STALE_HOURS.
#
# Nothing runs unasked: a PR is queued only once someone the realm lists has
# called it into this naust by name, in a review on the PR. A job the tick
# starts reports back where the call came from, as a comment on the PR, when
# the profile allows it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
gh_auth

if ! with_lock; then
  log "tick: another tick holds $STATE_DIR/lock; nothing to do"
  exit 0
fi

# The calls this naust answers are addressed to its account, and its reports
# post as the token's owner. Those must be the same login, or a review meant
# for one yard would be answered by another under a different name.
account="$(cfg .account)"
[ -n "$account" ] || die "account: is not set in $NAUST_CONFIG; naust cannot tell which calls are for it"
login="$(gh api user --jq .login 2>/dev/null || true)"
# GitHub logins are one name whatever their case, so the comparison is too.
[ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]')" ] \
  || die "NAUST_GITHUB_TOKEN belongs to '${login:-nobody gh can name}', not to the configured account '$account'"

while IFS= read -r profile; do
  [ -n "$profile" ] || continue
  while IFS=$'\t' read -r p repo number sha base author head_repo updated; do
    [ -n "$number" ] || continue
    IFS=$'\t' read -r decision reason < <(bash "$HERE/gate.sh" decide "$p" "$repo" "$number" "$sha")
    if [ "$decision" = run ]; then
      bash "$HERE/queue.sh" put "$p" "$repo" "$number" "$sha" "$base" "$author" "$head_repo" --comment "$(prof "$p" .report.comment on)"
      bash "$HERE/poll.sh" mark "$p" "$number" queued "$sha"
      log "tick: $repo#$number queued ($reason)"
    elif [ "$decision" = error ]; then
      # The reviews could not be read, so nothing is known: the PR is not
      # marked gated, and the next tick reads it again.
      log "tick: $repo#$number left for the next tick ($reason)"
    else
      bash "$HERE/poll.sh" mark "$p" "$number" gated "$updated"
      log "tick: $repo#$number waiting ($reason)"
    fi
  done < <(bash "$HERE/poll.sh" candidates "$profile")
done < <(cfg_list .profiles)

bash "$HERE/run.sh" next > /dev/null || true
exit 0

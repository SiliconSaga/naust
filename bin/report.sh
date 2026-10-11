#!/usr/bin/env bash
# Render a job directory into report.md (for the bay and Discord) and
# comment.md (for the PR). Verdicts come from the JUnit XML, never from exit
# codes, and a step that did not run says so.
#
#   report.sh render <jobdir>
#   report.sh junit <dir>        totals line, then one failing case per line
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config

# Sum <testsuite> attributes and list failing <testcase>s across a directory.
cmd_junit() {
  local dir="$1" f suite t fl e sk
  local tests=0 failures=0 errors=0 skipped=0
  attr() { printf '%s' "$1" | sed -nE "s/.*[[:space:]]$2=\"([0-9]+)\".*/\1/p"; }
  for f in "$dir"/*.xml; do
    [ -f "$f" ] || continue
    suite="$(grep -o '<testsuite[^>]*>' "$f" | head -n1)"
    t="$(attr "$suite" tests)"; fl="$(attr "$suite" failures)"; e="$(attr "$suite" errors)"; sk="$(attr "$suite" skipped)"
    tests=$((tests + ${t:-0})); failures=$((failures + ${fl:-0})); errors=$((errors + ${e:-0})); skipped=$((skipped + ${sk:-0}))
  done
  printf '%s\t%s\t%s\t%s\n' "$tests" "$failures" "$errors" "$skipped"
  for f in "$dir"/*.xml; do
    [ -f "$f" ] || continue
    awk '
      /<testcase / { match($0, /name="[^"]*"/); n=substr($0, RSTART+6, RLENGTH-7);
                     match($0, /classname="[^"]*"/); c=substr($0, RSTART+11, RLENGTH-12); open=1; bad=0 }
      open && /<(failure|error)[ >]/ { bad=1 }
      open && (/\/>/ || /<\/testcase>/) { if (bad) print c "." n; open=0 }
    ' "$f"
  done | sort -u
}

yaml_get() { sed -n "s/^$2: //p" "$1" | head -n1; }

cmd_render() {
  local job="$1" persona repo number head base bay steps_rows="" id name status secs
  local pr_tot base_tot pr_fail base_fail new_fail old_fail human="" line
  persona="$(prof "${NAUST_PROFILE:-terasology}" .persona naust)"
  repo="$(yaml_get "$job/job.yaml" repo)"; number="$(yaml_get "$job/job.yaml" number)"
  head="$(yaml_get "$job/job.yaml" head)"; base="$(yaml_get "$job/job.yaml" base)"
  bay="$(yaml_get "$job/job.yaml" bay)"
  while IFS=$'\t' read -r id name status secs; do
    [ -n "$id" ] || continue
    case "$status" in skipped) status="not run" ;; esac
    steps_rows="$steps_rows| $id | $name | $status | ${secs}s |"$'\n'
    case "$status" in
      fail) human="$human- $name failed; see \`$name.log\`."$'\n' ;;
    esac
  done < "$job/steps.tsv"
  human="${human//- smoke failed; see \`smoke.log\`./- smoke boot failed: the game did not reach the renderer, or the screenshot is missing; read \`smoke.log\`.}"
  human="${human//- reset failed; see \`reset.log\`./- reset failed: the bay is marked broken and nothing ran; read \`reset.log\`.}"
  human="${human//- tree failed; see \`tree.log\`./- the working tree is not clean after the run; see the clean-tree section.}"
  if grep -q '^head moved' "$job/checkout.log" 2>/dev/null; then
    human="${human//- checkout failed; see \`checkout.log\`./- $(grep -m1 '^head moved' "$job/checkout.log"). Nothing was built; approve the new head to run it.}"
  fi

  # One read per directory, split on the first newline: piping cmd_junit into
  # head trips pipefail when head closes the pipe early.
  local tests_section="" pr_all base_all
  if ls "$job/reports"/*.xml >/dev/null 2>&1; then
    pr_all="$(cmd_junit "$job/reports")"
    pr_tot="${pr_all%%$'\n'*}"
    pr_fail=""; [ "$pr_all" = "$pr_tot" ] || pr_fail="${pr_all#*$'\n'}"
    if ls "$job/baseline"/*.xml >/dev/null 2>&1; then
      base_all="$(cmd_junit "$job/baseline")"
      base_tot="${base_all%%$'\n'*}"
      base_fail=""; [ "$base_all" = "$base_tot" ] || base_fail="${base_all#*$'\n'}"
    else
      base_tot=$'-\t-\t-\t-'; base_fail=""
    fi
    new_fail="$(comm -23 <(printf '%s\n' "$pr_fail" | grep -v '^$' | sort) <(printf '%s\n' "$base_fail" | grep -v '^$' | sort) || true)"
    old_fail="$(comm -12 <(printf '%s\n' "$pr_fail" | grep -v '^$' | sort) <(printf '%s\n' "$base_fail" | grep -v '^$' | sort) || true)"
    tests_section="## Tests (scope: $(tr '\n' ';' < "$job/scope.txt"))

| run | tests | failures | errors | skipped |
|---|---|---|---|---|
| PR | ${pr_tot//$'\t'/ | } |
| base | ${base_tot//$'\t'/ | } |

**New on this PR:** ${new_fail:-none}

**Also failing on the base:** ${old_fail:-none}
"
    while IFS= read -r line; do
      [ -n "$line" ] && human="$human- $line fails on this PR and not on the base."$'\n'
    done <<< "$new_fail"
  fi

  local tree_section="" smoke_section="" checks_line
  if [ -s "$job/tree.txt" ]; then
    tree_section="$(awk -F'\t' '{ printf "- %s: `%s` (%s)\n", $1, $2, $3 }' "$job/tree.txt")"
    if grep -q 'unexpected$' "$job/tree.txt"; then
      human="$human- the tree has unexpected dirt after the run (see clean tree)."$'\n'
    fi
  else
    tree_section="clean"
  fi
  if [ -f "$job/screenshot.png" ]; then smoke_section="screenshot: \`screenshot.png\` (attached on Discord; in the bay at \`$job/screenshot.png\`)"
  else smoke_section="no screenshot; last lines of \`smoke.log\`:"$'\n\n```\n'"$(tail -n 5 "$job/smoke.log" 2>/dev/null || true)"$'\n```'; fi
  checks_line="$(grep -m1 '^Checks:' "$job/checks.txt" 2>/dev/null || echo 'Checks: not read')"
  human="$human- Run the game and play the change; the boots only prove it starts."$'\n'

  cat > "$job/report.md" <<EOF
# $repo#$number — ${head:0:7} onto $base, $bay

Bay \`$bay\` at \`$job\`. Diff:

\`\`\`
$(cat "$job/diff-stat.txt" 2>/dev/null || echo "(no diff recorded)")
\`\`\`

## Steps

| step | name | status | took |
|---|---|---|---|
$steps_rows
$tests_section
## Boots

- headless: $(awk -F'\t' '$2 == "headless" { print $3 }' "$job/steps.tsv")
- smoke: $(awk -F'\t' '$2 == "smoke" { print $3 }' "$job/steps.tsv"); $smoke_section

## Clean tree

$tree_section

## CI

$checks_line

## What needs a human

$human
EOF
  {
    printf '%s\n' "**$persona checked this PR in a bay** (head \`${head:0:7}\`, base \`$base\`)."
    printf '\n'
    sed -e '1d' -e '/^Bay `/d' -e "s|$job|<bay>|g" "$job/report.md"
    printf '\n_This is an automated report; it says what was observed and not whether the change should merge. A maintainer decides that._\n'
  } > "$job/comment.md"
}

case "${1:-}" in
  render) shift; cmd_render "$1" ;;
  junit)  shift; cmd_junit "$1" ;;
  *) echo "usage: report.sh {render <jobdir>|junit <dir>}" >&2; exit 2 ;;
esac

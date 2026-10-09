#!/usr/bin/env bash
# Run one pull request through one bay: the mechanical half of the
# terasology-review skill's six checks, in its order, through the bay's own ws.
# Every step records pass/fail/skipped in steps.tsv; the report says which.
#
#   job.sh <bay> <jobfile>
# shellcheck disable=SC2329   # the step functions are called by name through run_step
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
load_config
REPORT_SCRIPT="${NAUST_REPORT_SCRIPT:-$HERE/report.sh}"

BAY="$1"; JOBFILE="$2"
eval "$(bash "$HERE/bay.sh" env "$BAY")"
COMP="$(prof "$NAUST_PROFILE" .component)"

repo="$(kv_get "$JOBFILE" repo)"; number="$(kv_get "$JOBFILE" number)"
head="$(kv_get "$JOBFILE" head)"; base="$(kv_get "$JOBFILE" base)"
author="$(kv_get "$JOBFILE" author)"; head_repo="$(kv_get "$JOBFILE" head_repo)"
with="$(kv_get "$JOBFILE" with)"
JOBID="$(basename "$JOBFILE" .job)"
JOB="$NAUST_BAY_DIR/.outputs/naust/$JOBID"
STEPS="$JOB/steps.tsv"

# The tick runs with the machine account's token for its own gh calls and this
# job inherits it. Nothing the PR controls may see it, so it goes first thing;
# the report step hands it back to its two ws review calls only.
unset GH_TOKEN
token="$(env_value NAUST_GITHUB_TOKEN)"
with_token() { if [ -n "$token" ]; then GH_TOKEN="$token" "$@"; else "$@"; fi; }
export NAUST_JOB_DIR="$JOB" NAUST_PR_NUMBER="$number" NAUST_PR_HEAD="$head"

FAILED=0
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STEPS"; }
skip() { record "$1" "$2" skipped 0; }
skip_all() { local s; for s in "$@"; do skip "${s%% *}" "${s#* }"; done; }   # "<id> <name>" pairs
# run_step <id> <name> <function>: the function's output goes to <name>.log.
run_step() {
  local id="$1" name="$2" fn="$3" t0 status=pass
  t0="$(now)"
  log "step $id $name"
  if "$fn" >> "$JOB/$name.log" 2>&1; then :; else status=fail; FAILED=1; fi
  record "$id" "$name" "$status" "$(( $(now) - t0 ))"
  [ "$status" = pass ]
}
in_bay() { bay_ws "$BAY" "$@"; }
profile_cmd() { # <profile key>: run the command in the component dir; empty is a pass
  local c; c="$(prof "$NAUST_PROFILE" "$1")"
  [ -n "$c" ] || { echo "(no $1 in profile)"; return 0; }
  (cd "$NAUST_COMP_DIR" && bash -c "$c")
}

# The remote the base branch lives on: the adapter's provision.remote, else
# the component's one remote (a bay clones with one).
comp_remote() {
  local r; r="$(adapter "$COMP" .provision.remote)"
  [ -n "$r" ] || r="$(git -C "$NAUST_COMP_DIR" remote)"
  [ "$(printf '%s\n' "$r" | wc -l)" -eq 1 ] && [ -n "$r" ] || { echo "cannot tell the upstream remote of $NAUST_COMP_DIR: $r"; return 1; }
  printf '%s\n' "$r"
}

step_reset() { bash "$HERE/bay.sh" reset "$BAY" --keep "$JOBID" && bash "$HERE/bay.sh" set "$BAY" busy; }

step_checkout() {
  local w target n remote
  remote="$(comp_remote)" || return 1
  in_bay checkout "$COMP" --cr "$number"
  for w in ${with//,/ }; do
    target="${w%#*}"; n="${w##*#}"
    in_bay checkout "$target" --cr "$n"
  done
  git -C "$NAUST_COMP_DIR" fetch -q "$remote" "$base"
  HEAD_SHA="$(git -C "$NAUST_COMP_DIR" rev-parse HEAD)"
  MERGE_BASE="$(git -C "$NAUST_COMP_DIR" merge-base HEAD "$remote/$base")"
  {
    printf 'repo: %s\nnumber: %s\nhead: %s\nbase: %s\nmerge_base: %s\n' "$repo" "$number" "$head" "$base" "$MERGE_BASE"
    printf 'author: %s\nhead_repo: %s\nwith: %s\nbay: %s\nstarted: %s\n' "$author" "$head_repo" "$with" "$BAY" "$(now)"
    [ "$HEAD_SHA" = "$head" ] || printf 'head_fetched: %s\n' "$HEAD_SHA"
  } > "$JOB/job.yaml"
  if [ "$HEAD_SHA" != "$head" ]; then
    echo "head moved: the gate admitted $head, the fetch returned $HEAD_SHA; a new nod is needed for the new head"
    return 1
  fi
}

add_class() { # <path relative to the component>
  local name task=""
  name="$(basename "$1" .java)"
  if grep -qE '@Tag\("(MteTest|TteTest)"\)' "$NAUST_COMP_DIR/$1" 2>/dev/null; then task=integrationTest; fi
  printf 'class %s %s\n' "$name" "$task" >> "$JOB/scope.txt"
}
step_scope() {
  local f mod t default=no
  git -C "$NAUST_COMP_DIR" diff --name-only "$MERGE_BASE" HEAD > "$JOB/diff.txt"
  git -C "$NAUST_COMP_DIR" diff --stat "$MERGE_BASE" HEAD > "$JOB/diff-stat.txt"
  : > "$JOB/scope.txt"
  while IFS= read -r f; do
    case "$f" in
      */src/test/java/*Test.java) add_class "$f" ;;
      engine/src/main/*|engine-tests/src/main/*|build-logic/*|*.gradle.kts|gradle/*|facades/*) default=yes ;;
      modules/*/src/main/*)
        mod="${f#modules/}"; mod="${mod%%/*}"
        while IFS= read -r -d '' t; do add_class "${t#"$NAUST_COMP_DIR"/}"; done \
          < <(find "$NAUST_COMP_DIR/modules/$mod/src/test/java" -name '*Test.java' -print0 2>/dev/null) ;;
    esac
  done < "$JOB/diff.txt"
  [ "$default" = yes ] && echo default >> "$JOB/scope.txt"
  sort -u "$JOB/scope.txt" -o "$JOB/scope.txt"
  [ -s "$JOB/scope.txt" ] || echo default > "$JOB/scope.txt"
  cat "$JOB/scope.txt"
}

# Run every line of scope.txt and gather the JUnit XML it produced into <dest>.
run_scope() { # <dest>
  local dest="$1" marker kind name task x rel rc
  mkdir -p "$dest"
  marker="$(mktemp)"
  : > "$dest/runs.tsv"
  while read -r kind name task; do
    case "$kind" in
      default)
        in_bay test "$COMP" && rc=0 || rc=$?
        printf 'ws test %s\t%s\n' "$COMP" "$rc" >> "$dest/runs.tsv" ;;
      class)
        in_bay test "$COMP" "$name" ${task:+--task "$task"} && rc=0 || rc=$?
        printf 'ws test %s %s%s\t%s\n' "$COMP" "$name" "${task:+ --task $task}" "$rc" >> "$dest/runs.tsv" ;;
    esac
  done < "$JOB/scope.txt"
  while IFS= read -r -d '' x; do
    rel="${x#"$NAUST_COMP_DIR"/}"
    cp "$x" "$dest/$(printf '%s' "$rel" | tr '/' '_')"
  done < <(find "$NAUST_COMP_DIR" -path '*/build/test-results/*' -name '*.xml' -newer "$marker" -print0)
  rm -f "$marker"
}

step_baseline() {
  git -C "$NAUST_COMP_DIR" switch -q --detach "$MERGE_BASE"
  run_scope "$JOB/baseline"
  git -C "$NAUST_COMP_DIR" switch -q "cr/$number"
}
step_build() { in_bay build "$COMP"; }
step_compile_all() { profile_cmd .steps.compile_all; }
step_tests() { run_scope "$JOB/reports"; }
step_headless() { profile_cmd .steps.headless; }
step_smoke() { profile_cmd .steps.smoke; }

step_tree() {
  local r line known unknown=0 pat
  : > "$JOB/tree.txt"
  while IFS= read -r r; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      known=no
      while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        case "$line" in *"$pat"*) known=yes ;; esac
      done < <(adapter_list "$COMP" .provision.known_dirt)
      if [ "$known" = yes ]; then
        printf '%s\t%s\tknown\n' "${r#"$NAUST_BAY_DIR"/components/}" "$line" >> "$JOB/tree.txt"
      else
        printf '%s\t%s\tunexpected\n' "${r#"$NAUST_BAY_DIR"/components/}" "$line" >> "$JOB/tree.txt"
        unknown=1
      fi
    done < <(git -C "$r" status --porcelain --untracked-files=all)   # files, not collapsed directories, so known_dirt can match a path
  done < <(bash "$HERE/bay.sh" repos "$BAY")
  cat "$JOB/tree.txt"
  [ "$unknown" -eq 0 ]
}

step_report() {
  with_token in_bay review "$COMP" checks "$number" > "$JOB/checks.txt" 2>&1 || true
  bash "$REPORT_SCRIPT" render "$JOB"
  if [ "$(prof "$NAUST_PROFILE" .report.comment on)" = on ]; then
    with_token in_bay review "$COMP" comment "$number" ".outputs/naust/$JOBID/comment.md"
  fi
  if [ -f "$JOB/screenshot.png" ]; then
    bash "$HERE/notify.sh" say "$(head -c 1500 "$JOB/report.md")" --file "$JOB/screenshot.png" || true
  else
    bash "$HERE/notify.sh" say "$(head -c 1500 "$JOB/report.md")" || true
  fi
  rm -rf "$STATE_DIR/jobs/$JOBID"
  cp -r "$JOB" "$STATE_DIR/jobs/$JOBID"
}

mkdir -p "$JOB"
: > "$STEPS"
log "job $JOBID: $repo#$number by $author in $BAY"
if run_step 1 reset step_reset; then
  if run_step 2 checkout step_checkout; then
    run_step 3 scope step_scope || true
    run_step 4 baseline step_baseline || true
    if run_step 5 build step_build; then
      run_step 5b compile-all step_compile_all || true
      run_step 5c tests step_tests || true
      run_step 6 headless step_headless || true
      run_step 7 smoke step_smoke || true
    else
      skip 5b compile-all; skip 5c tests; skip 6 headless; skip 7 smoke
    fi
    run_step 8 tree step_tree || true
  else
    skip_all "3 scope" "4 baseline" "5 build" "5b compile-all" "5c tests" "6 headless" "7 smoke" "8 tree"
  fi
else
  skip_all "2 checkout" "3 scope" "4 baseline" "5 build" "5b compile-all" "5c tests" "6 headless" "7 smoke" "8 tree"
fi
run_step 9 report step_report || true
if [ "$(bash "$HERE/bay.sh" list | awk -F'\t' -v b="$BAY" '$1 == b { print $2 }')" != broken ]; then
  bash "$HERE/bay.sh" set "$BAY" ready
fi
log "job $JOBID: done, failed=$FAILED, outputs in $JOB"
exit "$FAILED"

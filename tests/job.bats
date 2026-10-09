#!/usr/bin/env bats
load helpers/stub

# The ws inside the bay (reached through the parent's `bay exec`) does real
# git for checkout --cr, the verb yggdrasil built, and fakes everything else,
# writing one JUnit file per test run so the collector has something to gather.
bay_ws_stub() {
cat > "$BAY_DIR/scripts/ws" <<'EOF'
#!/usr/bin/env bash
echo "bayws $*" >> "$STUB_LOG"
comp="$(cd "$(dirname "$0")/../components/terasology" && pwd)"
case "$1 $2" in
  "checkout terasology")
    [ "$3" = --cr ] || exit 1
    git -C "$comp" fetch -q origin "refs/pull/$4/head" && git -C "$comp" switch -q -C "cr/$4" FETCH_HEAD ;;
  "checkout terasology/modules/Cooking") ;;
  "build terasology") echo "build GH_TOKEN=${GH_TOKEN:-unset}" >> "$STUB_LOG"; exit "${WS_BUILD_EXIT:-0}" ;;
  "test terasology")
    [ -z "${WS_TEST_BROKEN:-}" ] || exit 1              # a run that produced nothing
    mkdir -p "$comp/engine-tests/build/test-results/unitTest"
    printf '<testsuite name="%s" tests="1" failures="0" errors="0" skipped="0"><testcase name="t" classname="%s"/></testsuite>\n' "${3:-all}" "${3:-all}" \
      > "$comp/engine-tests/build/test-results/unitTest/TEST-${3:-all}.xml" ;;
  "review terasology")
    echo "review GH_TOKEN=${GH_TOKEN:-unset}" >> "$STUB_LOG"
    case "$3" in checks) echo "Checks: 1 pass, 0 fail, 0 pending" ;; comment) ;; esac ;;
esac
EOF
chmod +x "$BAY_DIR/scripts/ws"
}

# A PR on the component's origin: one engine change, one plain test, one
# MTE-tagged test. Calling it again moves the PR.
publish_bay_pr() {
    local comp="$BAY_DIR/components/terasology"
    git -C "$comp" switch -q -c pr-work
    mkdir -p "$comp/engine/src/main/java/org/x" "$comp/engine-tests/src/test/java/org/x"
    printf 'class A { /* %s */ }\n' "$RANDOM" > "$comp/engine/src/main/java/org/x/A.java"
    printf 'class ATest {}\n' > "$comp/engine-tests/src/test/java/org/x/ATest.java"
    printf '@Tag("MteTest")\nclass BMteTest {}\n' > "$comp/engine-tests/src/test/java/org/x/BMteTest.java"
    git -C "$comp" add -A
    git -C "$comp" commit -qm "pr"
    PR_SHA="$(git -C "$comp" rev-parse HEAD)"
    git -C "$comp" push -q -f origin "HEAD:refs/pull/7/head"
    git -C "$comp" switch -q develop
    git -C "$comp" branch -q -D pr-work
}

write_jobfile() { # <head>
    mkdir -p "$NAUST_DIR/state/jobs"
    JOBFILE="$NAUST_DIR/state/jobs/MovingBlocks__Terasology-7-${1:0:7}.job"
    printf 'profile=terasology\nrepo=MovingBlocks/Terasology\nnumber=7\nhead=%s\nbase=develop\nauthor=Cervator\nhead_repo=Cervator/Terasology\npriority=0\nwith=\nbay=\nenqueued=1\n' "$1" > "$JOBFILE"
    JOB="$BAY_DIR/.outputs/naust/MovingBlocks__Terasology-7-${1:0:7}"
}

setup() {
    naust_setup
    make_stub compile-all-stub
    make_stub after-reset-stub
    make_stub headless-stub 'printf "Server started\n" > "$NAUST_JOB_DIR/headless.log"'
    make_stub smoke-stub 'touch "$NAUST_JOB_DIR/screenshot.png"; echo "smoke GH_TOKEN=${GH_TOKEN:-unset}" >> "$STUB_LOG"'
    make_stub curl
    printf 'NAUST_DISCORD_WEBHOOK=https://discord.invalid/hook\nNAUST_GITHUB_TOKEN=tok\n' > "$NAUST_ENV_FILE"
    export GH_TOKEN=leaked-from-the-tick             # what a real tick's environment carries into the job
    export NAUST_REPORT_SCRIPT="$BATS_TEST_TMPDIR/report-stub.sh"
    printf '#!/usr/bin/env bash\necho "report $*" >> "$STUB_LOG"\nprintf "# report\\n" > "$2/report.md"\nprintf "comment\\n" > "$2/comment.md"\n' > "$NAUST_REPORT_SCRIPT"
    make_bay bay-1 busy
    bay_ws_stub
    # The component's one remote, outside every tree a reset would clean.
    mkdir -p "$BATS_TEST_TMPDIR/remotes"
    git init -q --bare "$BATS_TEST_TMPDIR/remotes/terasology.git"
    git -C "$BAY_DIR/components/terasology" remote add origin "$BATS_TEST_TMPDIR/remotes/terasology.git"
    git -C "$BAY_DIR/components/terasology" push -q -u origin develop
    publish_bay_pr
    write_jobfile "$PR_SHA"
}

step_status() { awk -F'\t' -v id="$1" '$1 == id { print $3 }' "$JOB/steps.tsv"; }
bay_state() { sed -n 's/^state=//p' "$NAUST_DIR/state/bays/bay-1.state"; }

@test "the happy path runs every step in order and leaves the bay ready" {
    run_naust job bay-1 "$JOBFILE"
    [ "$status" -eq 0 ]
    for id in 1 2 3 4 5 5b 5c 6 7 8 9; do [ "$(step_status $id)" = pass ]; done
    comp="$BAY_DIR/components/terasology"
    [ "$(sed -n 's/^head: //p' "$JOB/job.yaml")" = "$PR_SHA" ]
    [ "$(sed -n 's/^merge_base: //p' "$JOB/job.yaml")" = "$(git -C "$comp" rev-parse origin/develop)" ]
    [ "$(git -C "$comp" rev-parse --abbrev-ref HEAD)" = "cr/7" ]
    grep -q '^class ATest $' "$JOB/scope.txt"
    grep -q '^class BMteTest integrationTest$' "$JOB/scope.txt"
    grep -q '^default$' "$JOB/scope.txt"
    ls "$JOB/baseline"/*.xml >/dev/null
    ls "$JOB/reports"/*.xml >/dev/null
    grep -q '^ws bay reset bay-1$' "$STUB_LOG"
    grep -q '^bayws checkout terasology --cr 7$' "$STUB_LOG"
    grep -q 'bayws test terasology BMteTest --task integrationTest' "$STUB_LOG"
    [ "$(grep -c '^bayws test terasology' "$STUB_LOG")" -eq 6 ]
    grep -q '^bayws build terasology' "$STUB_LOG"
    grep -q '^compile-all-stub' "$STUB_LOG"
    grep -q '^headless-stub' "$STUB_LOG"
    grep -q '^smoke-stub' "$STUB_LOG"
    grep -q '^bayws review terasology checks 7' "$STUB_LOG"
    grep -q "^bayws review terasology comment 7 .outputs/naust/MovingBlocks__Terasology-7-${PR_SHA:0:7}/comment.md" "$STUB_LOG"
    grep -q "^report render $JOB" "$STUB_LOG"
    grep -q "file=@$JOB/screenshot.png" "$STUB_LOG"
    [ -f "$NAUST_DIR/state/jobs/MovingBlocks__Terasology-7-${PR_SHA:0:7}/report.md" ]
    [ "$(bay_state)" = "ready" ]
    grep -q "Checks: 1 pass" "$JOB/checks.txt"
    # the machine account's token reaches the report's review calls and nothing the PR controls:
    # only those two calls ask ws bay exec to pass GH_TOKEN through its .env scrub
    grep -q '^build GH_TOKEN=unset$' "$STUB_LOG"
    grep -q '^smoke GH_TOKEN=unset$' "$STUB_LOG"
    [ "$(grep -c '^review GH_TOKEN=tok$' "$STUB_LOG")" -eq 2 ]
    [ "$(grep -c '^ws bay exec --pass GH_TOKEN bay-1 review terasology' "$STUB_LOG")" -eq 2 ]
    grep -q '^ws bay exec bay-1 build terasology$' "$STUB_LOG"
    ! grep -q 'leaked-from-the-tick' "$STUB_LOG"
}

@test "a PR that moved after the gate stops at checkout, says so, and frees the bay" {
    publish_bay_pr                                  # moves refs/pull/7/head past the gated head
    run_naust job bay-1 "$JOBFILE"
    [ "$status" -ne 0 ]
    [ "$(step_status 1)" = pass ]
    [ "$(step_status 2)" = fail ]
    for id in 3 4 5 5b 5c 6 7 8; do [ "$(step_status $id)" = skipped ]; done
    [ "$(step_status 9)" = pass ]
    grep -q 'head moved' "$JOB/checkout.log"
    [ "$(sed -n 's/^head_fetched: //p' "$JOB/job.yaml")" = "$PR_SHA" ]
    ! grep -q '^bayws build' "$STUB_LOG"
    [ "$(bay_state)" = "free" ]                     # nothing was built, so nothing waits for a human
}

@test "a base branch that cannot be fetched fails the checkout step" {
    sed -i 's/^base=develop$/base=nope/' "$JOBFILE"
    run_naust job bay-1 "$JOBFILE"
    [ "$status" -ne 0 ]
    [ "$(step_status 2)" = fail ]
    for id in 3 4 5 5b 5c 6 7 8; do [ "$(step_status $id)" = skipped ]; done
}

@test "a test run that produces no reports does not pass" {
    export WS_TEST_BROKEN=1
    run_naust job bay-1 "$JOBFILE"
    [ "$status" -ne 0 ]
    [ "$(step_status 4)" = fail ]
    [ "$(step_status 5c)" = fail ]
    [ "$(step_status 5)" = pass ]
}

@test "a failed build skips compile-all, tests and both boots but still reports" {
    export WS_BUILD_EXIT=1
    run_naust job bay-1 "$JOBFILE"
    [ "$status" -ne 0 ]
    [ "$(step_status 5)" = fail ]
    for id in 5b 5c 6 7; do [ "$(step_status $id)" = skipped ]; done
    [ "$(step_status 8)" = pass ]
    [ "$(step_status 9)" = pass ]
    grep -q '^bayws review terasology comment 7' "$STUB_LOG"
    [ "$(bay_state)" = "ready" ]
}

@test "a failed reset skips everything but the report and leaves the bay broken" {
    export WS_EXIT=1                                # the parent's ws bay reset fails
    run_naust job bay-1 "$JOBFILE"
    [ "$status" -ne 0 ]
    [ "$(step_status 1)" = fail ]
    for id in 2 3 4 5 5b 5c 6 7 8; do [ "$(step_status $id)" = skipped ]; done
    [ "$(step_status 9)" = pass ]
    [ "$(bay_state)" = "broken" ]
}

@test "report.comment off posts nothing on the PR" {
    yq -i '.report.comment = "off"' "$NAUST_WORKSPACE/realms/realm-test/naust/terasology.yaml"
    run_naust job bay-1 "$JOBFILE"
    ! grep -q '^bayws review terasology comment' "$STUB_LOG"
}

@test "with targets are checked out too and recorded" {
    printf 'with=terasology/modules/Cooking#3\n' >> "$JOBFILE"
    run_naust job bay-1 "$JOBFILE"
    grep -q '^bayws checkout terasology/modules/Cooking --cr 3' "$STUB_LOG"
    grep -q '^with: terasology/modules/Cooking#3$' "$JOB/job.yaml"
}

@test "known dirt from the adapter is named as known, anything else as unexpected" {
    mkdir -p "$BAY_DIR/components/terasology/modules/Cooking/src/test/resources"
    touch "$BAY_DIR/components/terasology/modules/Cooking/src/test/resources/logback-test.xml"
    make_stub smoke-stub 'touch "$NAUST_JOB_DIR/screenshot.png"; touch "$NAUST_COMP_DIR/stray.dll"'
    run_naust job bay-1 "$JOBFILE"
    grep -q $'modules/Cooking\t?? src/test/resources/logback-test.xml\tknown' "$JOB/tree.txt"
    grep -q $'?? stray.dll\tunexpected' "$JOB/tree.txt"
    [ "$(step_status 8)" = fail ]
}

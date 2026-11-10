#!/usr/bin/env bats
load helpers/stub

# The job stub records its call and leaves a report where the real job
# would, so dock has something to print.
setup() {
    naust_setup
    printf 'NAUST_GITHUB_TOKEN=tok\n' > "$NAUST_ENV_FILE"
    make_stub gh 'case "$*" in *"pr view"*) printf "%s\n" "$RUN_PR" ;; esac'
    export NAUST_JOB_SCRIPT="$BATS_TEST_TMPDIR/job-stub.sh"
    cat > "$NAUST_JOB_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "job $*" >> "$STUB_LOG"
d="$NAUST_WORKSPACE/bays/$1/.outputs/naust/$(basename "$2" .job)"
mkdir -p "$d"
printf '# the report\n' > "$d/report.md"
exit "${JOB_EXIT:-0}"
EOF
    export RUN_PR=$'abc123\tdevelop\tstranger\tstranger/Terasology'
}

jobfile() { printf '%s/state/jobs/MovingBlocks__Terasology-7-abc123.job\n' "$NAUST_DIR"; }

@test "dock runs a PR in a free bay now, prints its report, and posts nothing: the operator's command is the vouch" {
    make_bay bay-2 free
    run_naust dock terasology 7 --with terasology/modules/Health#12 --bay bay-2
    [ "$status" -eq 0 ]
    [[ "$output" == *"# the report"* ]]
    [[ "$output" == *"bay-2"* ]]
    grep -q "^job bay-2 $(jobfile)" "$STUB_LOG"
    f="$(jobfile)"
    grep -q '^priority=10$' "$f"
    grep -q '^head=abc123$' "$f"
    grep -q '^with=terasology/modules/Health#12$' "$f"
    grep -q '^bay=bay-2$' "$f"
    grep -q '^comment=off$' "$f"
    grep -q 'gh pr view 7 --repo MovingBlocks/Terasology --json headRefOid' "$STUB_LOG"
    grep -q "on the operator's word" "$NAUST_LOG"
    [ ! -e "$NAUST_DIR/state/lock" ]
    run ! grep -q -- '--json reviews' "$STUB_LOG"
}

@test "--comment lets a hand-docked PR post its report to GitHub after all" {
    make_bay bay-2 free
    run_naust dock terasology 7 --comment
    [ "$status" -eq 0 ]
    grep -q '^comment=on$' "$(jobfile)"
}

@test "a job that fails is still printed, and dock says so in its exit status" {
    make_bay bay-2 free
    JOB_EXIT=1 run_naust dock terasology 7
    [ "$status" -eq 1 ]
    [[ "$output" == *"# the report"* ]]
}

@test "with no free bay the PR is left queued for the tick" {
    make_bay bay-1 busy
    run_naust dock terasology 7
    [ "$status" -ne 0 ]
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    grep -q 'no free bay' "$NAUST_LOG"
    run ! grep -q '^job ' "$STUB_LOG"
}

@test "--queue only queues, for the tick to run" {
    make_bay bay-2 free
    run_naust dock terasology 7 --queue
    [ "$status" -eq 0 ]
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    run ! grep -q '^job ' "$STUB_LOG"
}

@test "while a tick holds the lock the PR is queued and left for it" {
    make_bay bay-2 free
    mkdir -p "$NAUST_DIR/state/lock"
    printf '1\n' > "$NAUST_DIR/state/lock/pid"
    run_naust dock terasology 7
    [ "$status" -ne 0 ]
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    grep -q 'lock' "$NAUST_LOG"
    run ! grep -q '^job ' "$STUB_LOG"
}

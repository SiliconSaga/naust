#!/usr/bin/env bats
load helpers/stub

# watch loops the tick. The tick here is a stub that records each run, so what
# is under test is the loop, its interval and what Ctrl-C leaves behind.
setup() {
    naust_setup
    export NAUST_TICK_SCRIPT="$BATS_TEST_TMPDIR/tick-stub.sh"
    printf '#!/usr/bin/env bash\necho "tick $*" >> "$STUB_LOG"\n' > "$NAUST_TICK_SCRIPT"
}

state_of() { sed -n 's/^state=//p' "$NAUST_DIR/state/bays/$1.state"; }

# Bounded wait for a line in a file.
wait_for() { # <pattern> <file>
    local i
    for i in $(seq 1 100); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done
    echo "never saw '$1' in $2" >&2
    return 1
}

# A watch in the background, its output in a file and bats's own fd 3 closed,
# so bats does not wait on it or on anything the killed tick stub leaves;
# returns once the tick stub has written <marker> to the stub log. The tests
# stop it with TERM: a job started with & has INT ignored on entry, which no
# trap can undo, while a Ctrl-C at a real terminal is INT into the same trap.
start_watch() { # <marker> [watch args]
    local marker="$1"; shift
    bash "$NAUST" watch "$@" > "$BATS_TEST_TMPDIR/watch.out" 2>&1 3>&- &
    WATCH_PID=$!
    wait_for "^$marker" "$STUB_LOG"
}

# TERM to the watch, then its exit status, within a bound: a watch still
# running after fifteen seconds is one whose stop did not end the tick's job,
# and it and the job are killed so the test ends with a failure, not a hang.
stop_watch() {
    local i
    kill -TERM "$WATCH_PID"
    for i in $(seq 1 150); do kill -0 "$WATCH_PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$WATCH_PID" 2>/dev/null; then
        { echo "--- watch.out"; cat "$BATS_TEST_TMPDIR/watch.out"; echo "--- naust.log"; cat "$NAUST_LOG"; echo "--- ps"; ps; } >&2
        kill -KILL "$WATCH_PID" 2>/dev/null || true
        [ ! -f "$BATS_TEST_TMPDIR/job.pid" ] || kill -KILL "$(cat "$BATS_TEST_TMPDIR/job.pid")" 2>/dev/null || true
        echo "the watch did not stop within 15 s" >&2
        return 1
    fi
    WATCH_RC=0; wait "$WATCH_PID" || WATCH_RC=$?
}

# A tick mid-job: it holds the lock, its bay is busy, and its job (a sleep far
# longer than any test, whose pid it records) is running under it.
mid_job_tick() { # [extra lines after the lock is taken]
    cat > "$NAUST_TICK_SCRIPT" <<EOF
#!/usr/bin/env bash
mkdir -p "$NAUST_DIR/state/lock"; echo \$\$ > "$NAUST_DIR/state/lock/pid"
${1:-}
printf 'state=busy\nprofile=terasology\njob=MovingBlocks__Terasology-7-abc123\nsince=1\n' > "$NAUST_DIR/state/bays/bay-1.state"
sleep 600 & echo \$! > "$BATS_TEST_TMPDIR/job.pid"
echo started >> "$STUB_LOG"
wait
EOF
}

@test "watch ticks, says when it looks again, and ticks again" {
    NAUST_WATCH_TICKS=2 run_naust watch --every 0s
    [ "$status" -eq 0 ]
    [ "$(grep -c '^tick' "$STUB_LOG")" -eq 2 ]
    grep -q 'watch: a tick every 0s; Ctrl-C stops it' "$NAUST_LOG"
    grep -q 'watch: next look in 0s' "$NAUST_LOG"
}

@test "watch looks every five minutes unless told otherwise" {
    NAUST_WATCH_TICKS=1 run_naust watch
    [ "$status" -eq 0 ]
    grep -q 'watch: a tick every 5m' "$NAUST_LOG"
}

@test "watch refuses an interval that is not a duration" {
    run_naust watch --every soon
    [ "$status" -eq 1 ]
    grep -q 'ERROR: --every wants a duration' "$NAUST_LOG"
    run ! grep -q '^tick' "$STUB_LOG"
}

@test "Ctrl-C during a job kills the job with the tick, releases the lock and frees the bay" {
    make_bay bay-1 free
    mid_job_tick
    start_watch started --every 1s
    stop_watch
    [ "$WATCH_RC" -eq 130 ]
    run ! kill -0 "$(cat "$BATS_TEST_TMPDIR/job.pid")"
    [ ! -d "$NAUST_DIR/state/lock" ]
    [ "$(state_of bay-1)" = free ]
    [ "$(sed -n 's/^job=//p' "$NAUST_DIR/state/bays/bay-1.state")" = "" ]
    grep -q 'watch: released the stopped tick' "$NAUST_LOG"
    grep -q 'watch: bay-1 was busy with MovingBlocks__Terasology-7-abc123' "$NAUST_LOG"
    grep -q 'watch: stopped' "$NAUST_LOG"
}

@test "a tick that let go of its lock as it died still has its bay freed" {
    make_bay bay-1 free
    mid_job_tick "trap 'rm -rf \"$NAUST_DIR/state/lock\"' EXIT"
    start_watch started --every 1s
    stop_watch
    [ ! -d "$NAUST_DIR/state/lock" ]
    [ "$(state_of bay-1)" = free ]
    run ! grep -q 'released the stopped tick' "$NAUST_LOG"
}

@test "Ctrl-C between ticks ends the watch at once and touches no bay" {
    make_bay bay-1 ready
    start_watch tick --every 30s
    wait_for 'watch: next look in 30s' "$NAUST_LOG"
    stop_watch
    [ "$WATCH_RC" -eq 130 ]
    [ "$(state_of bay-1)" = ready ]
    run ! grep -q 'was busy' "$NAUST_LOG"
    grep -q 'watch: stopped' "$NAUST_LOG"
}

@test "a lock held by a live process is not the stopped tick's and is left alone, bay and all" {
    make_bay bay-1 free
    # Someone else (a dock in another terminal) holds the lock and the bay.
    mkdir -p "$NAUST_DIR/state/lock"; echo $$ > "$NAUST_DIR/state/lock/pid"
    printf 'state=busy\nprofile=terasology\njob=theirs\nsince=1\n' > "$NAUST_DIR/state/bays/bay-1.state"
    printf '#!/usr/bin/env bash\nsleep 600 & echo $! > "$BATS_TEST_TMPDIR/job.pid"\necho started >> "$STUB_LOG"\nwait\n' > "$NAUST_TICK_SCRIPT"
    start_watch started --every 1s
    stop_watch
    [ -d "$NAUST_DIR/state/lock" ]
    [ "$(state_of bay-1)" = busy ]
    grep -q 'watch: the lock belongs to a running pid' "$NAUST_LOG"
}

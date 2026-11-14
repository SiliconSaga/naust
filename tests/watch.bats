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

# A watch in the background, its output in a file and bats's own fd 3 closed,
# so bats does not wait on it or on the sleep the killed tick stub leaves;
# returns once the tick stub has written <marker> to the stub log. The tests
# stop it with TERM: a job started with & has INT ignored on entry, which no
# trap can undo, while a Ctrl-C at a real terminal is INT into the same trap.
start_watch() { # <marker> [watch args]
    local marker="$1" i; shift
    bash "$NAUST" watch "$@" > "$BATS_TEST_TMPDIR/watch.out" 2>&1 3>&- &
    WATCH_PID=$!
    for i in $(seq 1 100); do grep -q "^$marker" "$STUB_LOG" 2>/dev/null && return 0; sleep 0.1; done
    echo "the tick stub never wrote $marker" >&2
    return 1
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

@test "Ctrl-C during a job kills the tick, releases its lock and frees its bay" {
    make_bay bay-1 free
    # A tick mid-job: it holds the lock, its bay is busy, and it runs for a while.
    cat > "$NAUST_TICK_SCRIPT" <<EOF
#!/usr/bin/env bash
mkdir -p "$NAUST_DIR/state/lock"; echo \$\$ > "$NAUST_DIR/state/lock/pid"
printf 'state=busy\nprofile=terasology\njob=MovingBlocks__Terasology-7-abc123\nsince=1\n' > "$NAUST_DIR/state/bays/bay-1.state"
echo started >> "$STUB_LOG"
sleep 30
EOF
    start_watch started --every 1s
    kill -TERM "$WATCH_PID"
    rc=0; wait "$WATCH_PID" || rc=$?
    [ "$rc" -eq 130 ]
    [ ! -d "$NAUST_DIR/state/lock" ]
    [ "$(state_of bay-1)" = free ]
    [ "$(sed -n 's/^job=//p' "$NAUST_DIR/state/bays/bay-1.state")" = "" ]
    grep -q 'watch: bay-1 was busy with MovingBlocks__Terasology-7-abc123' "$NAUST_LOG"
    grep -q 'watch: stopped' "$NAUST_LOG"
}

@test "Ctrl-C between ticks ends the watch and touches no bay" {
    make_bay bay-1 ready
    start_watch tick --every 30s
    kill -TERM "$WATCH_PID"
    rc=0; wait "$WATCH_PID" || rc=$?
    [ "$rc" -eq 130 ]
    [ "$(state_of bay-1)" = ready ]
    run ! grep -q 'was busy' "$NAUST_LOG"
    grep -q 'watch: stopped' "$NAUST_LOG"
}

@test "a lock held by a live process is not the stopped tick's and is left alone, bay and all" {
    make_bay bay-1 free
    # Someone else (a dock in another terminal) holds the lock and the bay.
    mkdir -p "$NAUST_DIR/state/lock"; echo $$ > "$NAUST_DIR/state/lock/pid"
    printf 'state=busy\nprofile=terasology\njob=theirs\nsince=1\n' > "$NAUST_DIR/state/bays/bay-1.state"
    printf '#!/usr/bin/env bash\necho started >> "$STUB_LOG"\nsleep 30\n' > "$NAUST_TICK_SCRIPT"
    start_watch started --every 1s
    kill -TERM "$WATCH_PID"
    wait "$WATCH_PID" || true
    [ -d "$NAUST_DIR/state/lock" ]
    [ "$(state_of bay-1)" = busy ]
    grep -q 'watch: the lock belongs to a running pid' "$NAUST_LOG"
}

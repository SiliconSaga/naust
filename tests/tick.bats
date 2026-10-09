#!/usr/bin/env bats
load helpers/stub

setup() {
    naust_setup
    export POLL_PRS="" GATE_REVIEWS=""
    make_stub gh 'case "$*" in
      *"pr list"*) printf "%s\n" "$POLL_PRS" ;;
      *"--json reviews"*) printf "%s\n" "$GATE_REVIEWS" ;;
    esac'
    make_stub curl
    printf 'NAUST_DISCORD_WEBHOOK=https://discord.invalid/hook\n' > "$NAUST_ENV_FILE"
    export NAUST_JOB_SCRIPT="$BATS_TEST_TMPDIR/job-stub.sh"
    printf '#!/usr/bin/env bash\necho "job $*" >> "$STUB_LOG"\n' > "$NAUST_JOB_SCRIPT"
}

pr_line() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" develop "$3" "$3/Terasology" false 2026-10-08T00:00:00Z; }
aged() { printf 'sha=%s\nfirst_seen=%s\n' "$2" $((NAUST_NOW - 3600)) > "$NAUST_DIR/state/seen/MovingBlocks__Terasology/$1"; }

@test "a maintainer's PR is queued and marked; a stranger's gets one notice" {
    mkdir -p "$NAUST_DIR/state/seen/MovingBlocks__Terasology"
    aged 7 abc123; aged 8 bbb222
    export POLL_PRS="$(pr_line 7 abc123 Cervator)
$(pr_line 8 bbb222 stranger)"
    run_naust tick
    [ "$status" -eq 0 ]
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ] || [ -f "$NAUST_DIR/state/jobs/MovingBlocks__Terasology-7-abc123.job" ]
    [ ! -e "$NAUST_DIR/state/queue/MovingBlocks__Terasology__8.job" ]
    [ "$(sed -n 's/^queued=//p' "$NAUST_DIR/state/seen/MovingBlocks__Terasology/7")" = "abc123" ]
    [ "$(sed -n 's/^notified=//p' "$NAUST_DIR/state/seen/MovingBlocks__Terasology/8")" = "bbb222" ]
    [ "$(grep -c '^curl ' "$STUB_LOG")" -eq 1 ]
    grep -q 'needs a nod' "$STUB_LOG"
    grep -q 'https://github.com/MovingBlocks/Terasology/pull/8' "$STUB_LOG"
    run_naust tick
    [ "$(grep -c '^curl ' "$STUB_LOG")" -eq 1 ]
}

@test "a queued job runs in a free bay and leaves the queue" {
    make_bay bay-1 free
    run_naust queue put terasology MovingBlocks/Terasology 7 abc1234 develop Cervator Cervator/Terasology
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q "^job bay-1 $NAUST_DIR/state/jobs/MovingBlocks__Terasology-7-abc1234.job" "$STUB_LOG"
    [ ! -e "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    [ "$(sed -n 's/^job=//p' "$NAUST_DIR/state/bays/bay-1.state")" = "MovingBlocks__Terasology-7-abc1234" ]
}

@test "no free bay: the job stays queued" {
    make_bay bay-1 busy
    run_naust queue put terasology MovingBlocks/Terasology 7 abc1234 develop Cervator Cervator/Terasology
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q "no free bay" "$NAUST_LOG"
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    ! grep -q '^job ' "$STUB_LOG"
}

@test "a pinned bay that is not free keeps the job queued" {
    make_bay bay-1 free
    make_bay bay-2 held
    run_naust queue put terasology MovingBlocks/Terasology 7 abc1234 develop Cervator Cervator/Terasology --bay bay-2
    run_naust tick
    [ "$status" -eq 0 ]
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    ! grep -q '^job ' "$STUB_LOG"
}

@test "a tick that finds the lock held does nothing" {
    mkdir -p "$NAUST_DIR/state/lock"
    printf '1\n' > "$NAUST_DIR/state/lock/pid"
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q "another tick" "$NAUST_LOG"
    ! grep -q '^gh ' "$STUB_LOG"
}

#!/usr/bin/env bats
load helpers/stub

# The gh stub answers the account check, the PR list, and the reviews of PR 7
# only; every other PR has none.
setup() {
    naust_setup
    export POLL_PRS="" GATE_REVIEWS="" GH_LOGIN=agent-refr
    make_stub gh 'case "$*" in
      "api user"*) printf "%s\n" "$GH_LOGIN" ;;
      *"pr list"*) printf "%s\n" "$POLL_PRS" ;;
      "pr view 7 "*"--json reviews"*) printf "%s\n" "$GATE_REVIEWS" ;;
    esac'
    make_stub curl
    printf 'NAUST_DISCORD_WEBHOOK=https://discord.invalid/hook\nNAUST_GITHUB_TOKEN=tok\n' > "$NAUST_ENV_FILE"
    export NAUST_JOB_SCRIPT="$BATS_TEST_TMPDIR/job-stub.sh"
    printf '#!/usr/bin/env bash\necho "job $*" >> "$STUB_LOG"\n' > "$NAUST_JOB_SCRIPT"
}

pr_line() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" develop "$3" "$3/Terasology" false "${4:-2026-10-08T00:00:00Z}"; }
review() { printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "${4:-false}"; }

@test "a called-in PR is queued to comment; one nobody called in waits, with no notice to anyone" {
    export POLL_PRS="$(pr_line 7 abc123 Cervator)
$(pr_line 8 bbb222 stranger)"
    export GATE_REVIEWS="$(review Cervator COMMENTED abc123 true)"
    run_naust tick
    [ "$status" -eq 0 ]
    f="$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job"
    [ -f "$f" ] || f="$NAUST_DIR/state/jobs/MovingBlocks__Terasology-7-abc123.job"
    grep -q '^comment=on$' "$f"
    [ ! -e "$NAUST_DIR/state/queue/MovingBlocks__Terasology__8.job" ]
    [ "$(sed -n 's/^queued=//p' "$NAUST_DIR/state/seen/MovingBlocks__Terasology/7")" = "abc123" ]
    [ "$(sed -n 's/^gated=//p' "$NAUST_DIR/state/seen/MovingBlocks__Terasology/8")" = "2026-10-08T00:00:00Z" ]
    run ! grep -q '^curl ' "$STUB_LOG"
    grep -q 'MovingBlocks/Terasology#8 waiting' "$NAUST_LOG"
    # nothing happened on PR 8 since: the next tick does not read its reviews again
    run_naust tick
    [ "$(grep -c 'gh pr view 8 ' "$STUB_LOG")" -eq 1 ]
}

@test "a PR the profile says not to comment on is queued quiet" {
    yq -i '.report.comment = "off"' "$NAUST_WORKSPACE/realms/realm-test/naust/terasology.yaml"
    export POLL_PRS="$(pr_line 7 abc123 Cervator)"
    export GATE_REVIEWS="$(review Cervator COMMENTED abc123 true)"
    run_naust tick
    f="$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job"
    [ -f "$f" ] || f="$NAUST_DIR/state/jobs/MovingBlocks__Terasology-7-abc123.job"
    grep -q '^comment=off$' "$f"
}

@test "a review read that fails leaves the PR for the next tick instead of gating it" {
    export POLL_PRS="$(pr_line 7 abc123 Cervator)"
    make_stub gh 'case "$*" in
      "api user"*) printf "%s\n" "$GH_LOGIN" ;;
      *"pr list"*) printf "%s\n" "$POLL_PRS" ;;
      *"--json reviews"*) exit 1 ;;
    esac'
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q 'could not read the reviews' "$NAUST_LOG"
    run ! grep -q '^gated=' "$NAUST_DIR/state/seen/MovingBlocks__Terasology/7"
    [ ! -e "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    run_naust tick
    [ "$(grep -c 'gh pr view 7 ' "$STUB_LOG")" -eq 2 ]
}

@test "the account check compares logins the way GitHub does, without regard to case" {
    export GH_LOGIN=Agent-Refr
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q 'pr list' "$STUB_LOG"
}

@test "a token that is not the configured account's stops the tick before it polls" {
    export GH_LOGIN=someone-else
    run_naust tick
    [ "$status" -ne 0 ]
    grep -q 'someone-else' "$NAUST_LOG"
    run ! grep -q 'pr list' "$STUB_LOG"
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
    run ! grep -q '^job ' "$STUB_LOG"
}

@test "a pinned bay that is not free keeps the job queued" {
    make_bay bay-1 free
    make_bay bay-2 held
    run_naust queue put terasology MovingBlocks/Terasology 7 abc1234 develop Cervator Cervator/Terasology --bay bay-2
    run_naust tick
    [ "$status" -eq 0 ]
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    run ! grep -q '^job ' "$STUB_LOG"
}

@test "a job pinned to a bay of another profile stays queued rather than running there" {
    make_bay bay-1 free
    make_bay bay-2 free
    sed -i 's/^profile=.*/profile=other/' "$NAUST_DIR/state/bays/bay-2.state"
    run_naust queue put terasology MovingBlocks/Terasology 7 abc1234 develop Cervator Cervator/Terasology --bay bay-2
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q "bay bay-2 belongs to other, not terasology" "$NAUST_LOG"
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    run ! grep -q '^job ' "$STUB_LOG"
    [ "$(sed -n 's/^state=//p' "$NAUST_DIR/state/bays/bay-2.state")" = "free" ]
}

@test "a job that cannot get its bay does not block the next job that can" {
    make_bay bay-1 free
    make_bay bay-2 held
    NAUST_NOW=100 run_naust queue put terasology MovingBlocks/Terasology 7 abc1234 develop Cervator Cervator/Terasology --priority 10 --bay bay-2
    NAUST_NOW=200 run_naust queue put terasology MovingBlocks/Terasology 8 bcd2345 develop Cervator Cervator/Terasology
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q "^job bay-1 $NAUST_DIR/state/jobs/MovingBlocks__Terasology-8-bcd2345.job" "$STUB_LOG"
    [ -f "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
    [ ! -e "$NAUST_DIR/state/queue/MovingBlocks__Terasology__8.job" ]
}

@test "a tick that finds the lock held does nothing" {
    mkdir -p "$NAUST_DIR/state/lock"
    printf '1\n' > "$NAUST_DIR/state/lock/pid"
    run_naust tick
    [ "$status" -eq 0 ]
    grep -q "another tick" "$NAUST_LOG"
    run ! grep -q '^gh ' "$STUB_LOG"
}

#!/usr/bin/env bats
load helpers/stub

# Both the PR lookup and the gate call `gh pr view`; the gate's carries
# `--json reviews`, so that case comes first.
setup() {
    naust_setup
    printf 'NAUST_GITHUB_TOKEN=tok\n' > "$NAUST_ENV_FILE"
    export GATE_REVIEWS=""
    make_stub gh 'case "$*" in
      *"--json reviews"*) printf "%s\n" "$GATE_REVIEWS" ;;
      *"pr view"*) printf "%s\n" "$RUN_PR" ;;
    esac'
}

@test "run queues a maintainer PR at priority 10 with its extras" {
    export RUN_PR=$'abc123\tdevelop\tCervator\tCervator/Terasology'
    run_naust run terasology 7 --with terasology/modules/Health#12 --bay bay-2
    [ "$status" -eq 0 ]
    f="$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job"
    grep -q '^priority=10$' "$f"
    grep -q '^head=abc123$' "$f"
    grep -q '^with=terasology/modules/Health#12$' "$f"
    grep -q '^bay=bay-2$' "$f"
    grep -q 'gh pr view 7 --repo MovingBlocks/Terasology --json headRefOid' "$STUB_LOG"
}

@test "run refuses a PR that needs a nod and says why" {
    export RUN_PR=$'abc123\tdevelop\tstranger\tstranger/Terasology'
    run_naust run terasology 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs a nod from a maintainer"* ]]   # die echoes to stderr even when NAUST_LOG is set
    [ ! -e "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
}

#!/usr/bin/env bats
load helpers/stub

setup() {
    naust_setup
    export POLL_PRS=""
    make_stub gh 'case "$*" in *"pr list"*) printf "%s\n" "$POLL_PRS" ;; esac'
}

pr_line() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" develop "$3" "$3/Terasology" "${4:-false}" 2026-10-08T00:00:00Z; }

@test "a new PR is remembered and waits out the debounce" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    f="$NAUST_DIR/state/seen/MovingBlocks__Terasology/7"
    [ "$(sed -n 's/^sha=//p' "$f")" = "abc123" ]
    [ "$(sed -n 's/^first_seen=//p' "$f")" = "$NAUST_NOW" ]
    grep -q 'gh pr list --repo MovingBlocks/Terasology --state open --limit 100 --json' "$STUB_LOG"
}

@test "after the debounce it is a candidate once, until marked queued" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    NAUST_NOW=$((NAUST_NOW + 11*60)) run_naust poll candidates terasology
    [ "$status" -eq 0 ]
    [ "$output" = $'terasology\tMovingBlocks/Terasology\t7\tabc123\tdevelop\tstranger\tstranger/Terasology' ]
    run_naust poll mark terasology 7 queued abc123
    NAUST_NOW=$((NAUST_NOW + 11*60)) run_naust poll candidates terasology
    [ -z "$output" ]
}

@test "a moved head restarts the debounce and becomes a candidate again" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    run_naust poll mark terasology 7 queued abc123
    export POLL_PRS="$(pr_line 7 def456 stranger)"
    NAUST_NOW=$((NAUST_NOW + 60)) run_naust poll candidates terasology
    [ -z "$output" ]
    NAUST_NOW=$((NAUST_NOW + 12*60)) run_naust poll candidates terasology
    [[ "$output" == *$'\t'def456$'\t'* ]]
}

@test "drafts are skipped while skip_drafts is on" {
    export POLL_PRS="$(pr_line 7 abc123 stranger true)
$(pr_line 8 bbb222 stranger)"
    run_naust poll candidates terasology
    NAUST_NOW=$((NAUST_NOW + 11*60)) run_naust poll candidates terasology
    [[ "$output" != *$'\t7\t'* ]]
    [[ "$output" == *$'\t8\t'* ]]
    yq -i '.poll.skip_drafts = false' "$NAUST_WORKSPACE/realms/realm-test/naust/terasology.yaml"
    NAUST_NOW=$((NAUST_NOW + 11*60)) run_naust poll candidates terasology
    [[ "$output" == *$'\t7\t'* ]]
}

@test "a closed PR is forgotten and its queued job dropped" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    run_naust queue put terasology MovingBlocks/Terasology 7 abc123 develop stranger stranger/Terasology
    export POLL_PRS=""
    run_naust poll candidates terasology
    [ "$status" -eq 0 ]
    [ ! -e "$NAUST_DIR/state/seen/MovingBlocks__Terasology/7" ]
    [ ! -e "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job" ]
}

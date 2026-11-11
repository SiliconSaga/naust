#!/usr/bin/env bats
load helpers/stub

setup() {
    naust_setup
    export POLL_PRS=""
    make_stub gh 'case "$*" in *"pr list"*) printf "%s\n" "$POLL_PRS" ;; esac'
}

pr_line() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" develop "$3" "$3/Terasology" "${4:-false}" "${5:-2026-10-08T00:00:00Z}"; }

@test "a new PR is remembered and is a candidate at once, with the time it was last touched" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    [ "$status" -eq 0 ]
    [ "$output" = $'terasology\tMovingBlocks/Terasology\t7\tabc123\tdevelop\tstranger\tstranger/Terasology\t2026-10-08T00:00:00Z' ]
    f="$NAUST_DIR/state/seen/MovingBlocks__Terasology/7"
    [ "$(sed -n 's/^sha=//p' "$f")" = "abc123" ]
    grep -q 'gh pr list --repo MovingBlocks/Terasology --state open --limit 500 --json' "$STUB_LOG"
}

@test "a PR gated at its last activity is not a candidate again until something happens on it" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    run_naust poll mark terasology 7 gated 2026-10-08T00:00:00Z
    run_naust poll candidates terasology
    [ -z "$output" ]
    export POLL_PRS="$(pr_line 7 abc123 stranger false 2026-10-09T00:00:00Z)"    # a review landed
    run_naust poll candidates terasology
    [ "$output" = $'terasology\tMovingBlocks/Terasology\t7\tabc123\tdevelop\tstranger\tstranger/Terasology\t2026-10-09T00:00:00Z' ]
}

@test "a head that is queued is not a candidate; a moved head is" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    run_naust poll mark terasology 7 queued abc123
    run_naust poll candidates terasology
    [ -z "$output" ]
    export POLL_PRS="$(pr_line 7 def456 stranger false 2026-10-09T00:00:00Z)"
    run_naust poll candidates terasology
    [[ "$output" == *$'\t'def456$'\t'* ]]
}

@test "a queued head whose PR was retargeted gets the new base in its queue file" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    run_naust queue put terasology MovingBlocks/Terasology 7 abc123 develop stranger stranger/Terasology
    run_naust poll mark terasology 7 queued abc123
    export POLL_PRS="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' 7 abc123 release stranger stranger/Terasology false 2026-10-09T00:00:00Z)"
    run_naust poll candidates terasology
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                 # still queued, so still not a candidate
    [ "$(sed -n 's/^base=//p' "$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job")" = "release" ]
}

@test "drafts are candidates like any other PR: a call is a call" {
    export POLL_PRS="$(pr_line 7 abc123 stranger true)"
    run_naust poll candidates terasology
    [[ "$output" == *$'\t7\t'* ]]
}

@test "a list as long as the limit forgets nothing, since it may be incomplete" {
    export POLL_PRS="$(pr_line 7 abc123 stranger)"
    run_naust poll candidates terasology
    export POLL_PRS="$(for n in $(seq 100 599); do pr_line "$n" "sha$n" stranger; printf '\n'; done)"
    run_naust poll candidates terasology
    [ "$status" -eq 0 ]
    [ -e "$NAUST_DIR/state/seen/MovingBlocks__Terasology/7" ]
    grep -q "not forgetting" "$NAUST_LOG"
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

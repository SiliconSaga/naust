#!/usr/bin/env bats
load helpers/stub

setup() { naust_setup; }

put() { run_naust queue put terasology MovingBlocks/Terasology "$@"; }

@test "put writes a job file and the same head is a no-op" {
    put 7 abc123 develop stranger stranger/Terasology
    [ "$status" -eq 0 ]
    f="$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job"
    [ -f "$f" ]
    grep -q '^head=abc123$' "$f"
    grep -q '^priority=0$' "$f"
    grep -q "^enqueued=$NAUST_NOW$" "$f"
    put 7 abc123 develop stranger stranger/Terasology
    grep -q "already queued" "$NAUST_LOG"
}

@test "put with a newer head replaces the entry" {
    put 7 abc123 develop stranger stranger/Terasology
    put 7 def456 develop stranger stranger/Terasology
    [ "$status" -eq 0 ]
    f="$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job"
    grep -q '^head=def456$' "$f"
    [ "$(ls "$NAUST_DIR/state/queue" | wc -l)" -eq 1 ]
}

@test "next prefers priority, then the oldest; drop removes" {
    NAUST_NOW=100 run_naust queue put terasology MovingBlocks/Terasology 1 a develop x x/y
    NAUST_NOW=200 run_naust queue put terasology MovingBlocks/Terasology 2 b develop x x/y
    NAUST_NOW=300 run_naust queue put terasology MovingBlocks/Terasology 3 c develop x x/y --priority 10 --with "terasology/modules/Health#12" --bay bay-2
    run_naust queue next
    [ "$status" -eq 0 ]
    [[ "$output" == *"__3.job" ]]
    grep -q '^with=terasology/modules/Health#12$' "$output"
    grep -q '^bay=bay-2$' "$output"
    run_naust queue drop "$output"
    run_naust queue next
    [[ "$output" == *"__1.job" ]]
    run_naust queue drop "$output"
    run_naust queue next
    [[ "$output" == *"__2.job" ]]
    run_naust queue drop "$output"
    run_naust queue next
    [ "$status" -ne 0 ]
}

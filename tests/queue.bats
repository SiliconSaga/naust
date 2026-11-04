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

@test "put at the same head keeps the entry but takes a higher priority and new extras" {
    NAUST_NOW=100 put 7 abc123 develop stranger stranger/Terasology
    NAUST_NOW=200 put 7 abc123 develop stranger stranger/Terasology --priority 10 --with "terasology/modules/Health#12" --bay bay-2
    [ "$status" -eq 0 ]
    f="$NAUST_DIR/state/queue/MovingBlocks__Terasology__7.job"
    grep -q '^priority=10$' "$f"
    grep -q '^with=terasology/modules/Health#12$' "$f"
    grep -q '^bay=bay-2$' "$f"
    grep -q '^enqueued=100$' "$f"
    NAUST_NOW=300 put 7 abc123 develop stranger stranger/Terasology
    grep -q '^priority=10$' "$f"                 # a polled re-put never lowers it
    grep -q '^with=terasology/modules/Health#12$' "$f"
}

@test "order lists every job the way next picks them; next is the first" {
    NAUST_NOW=100 put 1 a develop x x/y
    NAUST_NOW=200 put 2 b develop x x/y --priority 5
    NAUST_NOW=300 put 3 c develop x x/y --priority 5
    run_naust queue order
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"__2.job" ]]
    [[ "${lines[1]}" == *"__3.job" ]]
    [[ "${lines[2]}" == *"__1.job" ]]
    run_naust queue next
    [[ "$output" == *"__2.job" ]]
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

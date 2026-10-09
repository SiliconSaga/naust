#!/usr/bin/env bats
load helpers/stub

setup() {
    naust_setup
    make_stub compile-all-stub
    make_stub after-add-stub
    make_stub after-reset-stub
}

state_of() { sed -n 's/^state=//p' "$NAUST_DIR/state/bays/$1.state"; }

@test "add provisions through ws bay add, warms, hooks, resets, and leaves the bay free" {
    run_naust bay add bay-1 --profile terasology

    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$STUB_LOG")" = "ws bay add bay-1 --with terasology --realm realm-test" ]
    grep -q '^bayws build terasology$' "$STUB_LOG"
    grep -q '^compile-all-stub' "$STUB_LOG"
    grep -q '^after-add-stub' "$STUB_LOG"
    grep -q '^ws bay reset bay-1$' "$STUB_LOG"
    grep -q '^after-reset-stub' "$STUB_LOG"
    [ "$(state_of bay-1)" = "free" ]
    [ "$(sed -n 's/^profile=//p' "$NAUST_DIR/state/bays/bay-1.state")" = "terasology" ]
}

@test "add passes workspace_repo through as --from" {
    printf 'profiles: [terasology]\nworkspace_repo: https://example.invalid/ygg.git\n' > "$NAUST_CONFIG"
    run_naust bay add bay-1 --profile terasology
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$STUB_LOG")" = "ws bay add bay-1 --with terasology --realm realm-test --from https://example.invalid/ygg.git" ]
}

@test "add refuses a bay naust already knows" {
    make_bay bay-1 free
    run_naust bay add bay-1 --profile terasology
    [ "$status" -ne 0 ]
    [[ "$output" == *"already"* ]]
}

@test "reset runs ws bay reset, clears the old job outputs but keeps the current job's, runs the hook and frees the bay" {
    make_bay bay-1 ready
    mkdir -p "$BAY_DIR/.outputs/naust/old" "$BAY_DIR/.outputs/naust/current"
    touch "$BAY_DIR/.outputs/naust/old/report.md" "$BAY_DIR/.outputs/naust/current/reset.log"
    run_naust bay reset bay-1 --deep --keep current
    [ "$status" -eq 0 ]
    grep -q '^ws bay reset bay-1 --deep$' "$STUB_LOG"
    [ ! -e "$BAY_DIR/.outputs/naust/old" ]
    [ -f "$BAY_DIR/.outputs/naust/current/reset.log" ]
    grep -q '^after-reset-stub' "$STUB_LOG"
    [ "$(state_of bay-1)" = "free" ]
    run_naust bay reset bay-1
    [ ! -e "$BAY_DIR/.outputs/naust/current" ]
}

@test "a failed ws bay reset marks the bay broken and skips the hook" {
    make_bay bay-1 ready
    export WS_EXIT=1
    run_naust bay reset bay-1
    [ "$status" -ne 0 ]
    grep -q "reset bay-1: ws bay reset failed" "$NAUST_LOG"
    [ "$(state_of bay-1)" = "broken" ]
    ! grep -q '^after-reset-stub' "$STUB_LOG"
}

@test "claim takes a free bay once; release frees a ready or held bay" {
    make_bay bay-1 free
    run_naust bay claim bay-1 job-1
    [ "$status" -eq 0 ]
    [ "$(state_of bay-1)" = "busy" ]
    [ "$(sed -n 's/^job=//p' "$NAUST_DIR/state/bays/bay-1.state")" = "job-1" ]
    run_naust bay claim bay-1 job-2
    [ "$status" -ne 0 ]
    run_naust bay set bay-1 ready
    run_naust bay release bay-1
    [ "$status" -eq 0 ]
    [ "$(state_of bay-1)" = "free" ]
    run_naust bay set bay-1 busy
    run_naust bay release bay-1
    [ "$status" -ne 0 ]
}

@test "free-for finds a free bay of the profile and expires a stale ready one" {
    make_bay bay-1 ready
    make_bay bay-2 held
    run_naust bay free-for terasology
    [ "$status" -ne 0 ]
    printf 'state=ready\nprofile=terasology\njob=old\nsince=%s\n' $((NAUST_NOW - 8*86400)) > "$NAUST_DIR/state/bays/bay-1.state"
    run_naust bay free-for terasology
    [ "$status" -eq 0 ]
    [ "$output" = "bay-1" ]
    run_naust bay free-for other-profile
    [ "$status" -ne 0 ]
}

@test "list prints every bay with state, profile, job and age" {
    make_bay bay-1 free
    make_bay bay-2 busy
    run_naust bay list
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == bay-1$'\t'free$'\t'terasology$'\t'$'\t'0 ]]
    [[ "${lines[1]}" == bay-2$'\t'busy* ]]
}

@test "repos lists the component and the nested repos the adapter declares" {
    make_bay bay-1 free
    run_naust bay repos bay-1
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$BAY_DIR/components/terasology" ]
    [ "${lines[1]}" = "$BAY_DIR/components/terasology/modules/Cooking" ]
}

@test "env prints the bay environment as export lines" {
    make_bay bay-1 free
    run_naust bay env bay-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"export NAUST_BAY_DIR=$BAY_DIR"* ]]
    [[ "$output" == *"export NAUST_COMP_DIR=$BAY_DIR/components/terasology"* ]]
    [[ "$output" == *"export NAUST_REALM_DIR=$BAY_DIR/realms/realm-test"* ]]
    [[ "$output" == *"export GRADLE_USER_HOME=$NAUST_DIR/gradle-home"* ]]
}

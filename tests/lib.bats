#!/usr/bin/env bats
load helpers/stub

setup() { naust_setup; }

lib() { run bash -c "source '$(dirname "$NAUST")/lib.sh'; $*"; }

@test "naust --help lists the commands" {
    run_naust --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"tick"*"bay"*"run"* ]]
}

@test "load_config finds the workspace, the realm and the state under bays/.naust" {
    lib 'load_config; echo "$WORKSPACE|$REALM|$STATE_DIR|$PROFILE_DIR|$ADAPTER_DIR"'
    [ "$status" -eq 0 ]
    [ "$output" = "$NAUST_WORKSPACE|realm-test|$NAUST_DIR/state|$NAUST_WORKSPACE/realms/realm-test/naust|$NAUST_WORKSPACE/realms/realm-test/adapters" ]
    for d in queue seen jobs bays; do [ -d "$NAUST_DIR/state/$d" ]; done
}

@test "load_config takes the realm from naust.yaml over the workspace's active one" {
    mkdir -p "$NAUST_WORKSPACE/realms/other/naust"
    printf 'realm: other\nprofiles: []\n' > "$NAUST_CONFIG"
    lib 'load_config; echo "$REALM"'
    [ "$output" = "other" ]
}

@test "load_config fails without a workspace ws or a realm" {
    rm "$NAUST_WORKSPACE/scripts/ws"
    lib 'load_config'
    [ "$status" -ne 0 ]
    grep -q "no scripts/ws" "$NAUST_LOG"
    naust_setup
    printf '{}\n' > "$NAUST_WORKSPACE/ecosystem.local.yaml"
    lib 'load_config'
    [ "$status" -ne 0 ]
    grep -q "realm is required" "$NAUST_LOG"
}

@test "prof, trust and adapter read the realm files with defaults" {
    lib 'load_config; prof terasology .repo; prof terasology .missing fallback; trust terasology .nod_phrase; adapter terasology .provision.init; adapter_list terasology .provision.runtime_dirs'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "MovingBlocks/Terasology" ]
    [ "${lines[1]}" = "fallback" ]
    [ "${lines[2]}" = "ok to test" ]
    [ "${lines[3]}" = "groovyw-stub module init omega" ]
    [ "${lines[4]}" = "logs" ]
    [ "${lines[6]}" = "terasology-server" ]
}

@test "env_value reads the workspace .env literally and never evaluates it" {
    printf 'export NAUST_DISCORD_WEBHOOK="https://example.invalid/$(touch %s/boom)"\n' "$BATS_TEST_TMPDIR" > "$NAUST_ENV_FILE"
    lib 'env_value NAUST_DISCORD_WEBHOOK'
    [ "$status" -eq 0 ]
    [[ "$output" == 'https://example.invalid/$(touch '* ]]
    [ ! -e "$BATS_TEST_TMPDIR/boom" ]
}

@test "bay_ws goes through the parent's ws bay exec" {
    lib 'load_config; bay_ws bay-9 build terasology'
    [ "$status" -eq 0 ]
    grep -q '^ws bay exec bay-9 build terasology$' "$STUB_LOG"
}

@test "kv_set and kv_get round-trip and overwrite" {
    f="$BATS_TEST_TMPDIR/kv"
    lib "kv_set '$f' state free; kv_set '$f' job none; kv_set '$f' state busy; kv_get '$f' state; kv_get '$f' job; kv_get '$f' absent"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "busy" ]
    [ "${lines[1]}" = "none" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "with_lock is exclusive and a stale lock is reclaimed" {
    lib 'load_config; with_lock && echo first'
    [ "$status" -eq 0 ]
    [[ "$output" == *"first"* ]]
    mkdir -p "$NAUST_DIR/state/lock"
    printf '%s\n' 1 > "$NAUST_DIR/state/lock/pid"
    lib 'load_config; if with_lock; then echo got; else echo busy; fi'
    [[ "$output" == *"busy"* ]]
    touch -d '@1759970000' "$NAUST_DIR/state/lock"
    lib 'load_config; if with_lock; then echo got; else echo busy; fi'
    [[ "$output" == *"got"* ]]
}

@test "with_lock treats a lock whose age cannot be read as fresh" {
    make_stub stat 'exit 1'
    mkdir -p "$NAUST_DIR/state/lock"
    printf '%s\n' 1 > "$NAUST_DIR/state/lock/pid"
    lib 'load_config; if with_lock; then echo got; else echo busy; fi'
    [[ "$output" == *"busy"* ]]
}

@test "json_escape handles quotes, backslashes and newlines" {
    lib "json_escape \$'a \"b\" \\\\ c\nd'"
    [ "$status" -eq 0 ]
    [ "$output" = 'a \"b\" \\ c\nd' ]
}

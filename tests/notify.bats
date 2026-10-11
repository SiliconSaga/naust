#!/usr/bin/env bats
load helpers/stub

setup() {
    naust_setup
    make_stub curl 'exit 0'
}

@test "say posts the text as payload_json to the webhook" {
    printf 'NAUST_DISCORD_WEBHOOK=https://discord.invalid/hook\n' > "$NAUST_ENV_FILE"
    run_naust notify say 'PR #7 by @x needs a "nod"'
    [ "$status" -eq 0 ]
    # --form-string: curl would otherwise read `;type=` inside the text as a form option
    grep -q -- '--form-string payload_json={"content":"PR #7 by @x needs a \\"nod\\""} https://discord.invalid/hook' "$STUB_LOG"
}

@test "say attaches a file when asked" {
    printf 'NAUST_DISCORD_WEBHOOK=https://discord.invalid/hook\n' > "$NAUST_ENV_FILE"
    touch "$BATS_TEST_TMPDIR/shot.png"
    run_naust notify say 'done' --file "$BATS_TEST_TMPDIR/shot.png"
    [ "$status" -eq 0 ]
    grep -q -- "-F file=@$BATS_TEST_TMPDIR/shot.png" "$STUB_LOG"
}

@test "say without a webhook is a no-op that says so" {
    run_naust notify say 'hello'
    [ "$status" -eq 0 ]
    grep -q "no NAUST_DISCORD_WEBHOOK" "$NAUST_LOG"
    [ ! -s "$STUB_LOG" ]
}

@test "say fails when curl fails" {
    printf 'NAUST_DISCORD_WEBHOOK=https://discord.invalid/hook\n' > "$NAUST_ENV_FILE"
    make_stub curl 'exit 22'
    run_naust notify say 'hello'
    [ "$status" -ne 0 ]
}

@test "say truncates long text" {
    printf 'NAUST_DISCORD_WEBHOOK=https://discord.invalid/hook\n' > "$NAUST_ENV_FILE"
    long="$(printf 'x%.0s' $(seq 1 2500))"
    run_naust notify say "$long"
    [ "$status" -eq 0 ]
    grep -q -- 'xxx …"}' "$STUB_LOG"
    [ "$(grep -o 'x' "$STUB_LOG" | wc -l)" -le 1901 ]
}

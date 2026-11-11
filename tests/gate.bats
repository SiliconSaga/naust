#!/usr/bin/env bats
load helpers/stub

# GATE_REVIEWS: one review per line, tab-separated login, state, commit, and
# whether the body carries the call (the phrase and this naust's @account,
# true/false), the shape the gate's --jq produces.
setup() {
    naust_setup
    export GATE_REVIEWS=""
    make_stub gh 'case "$*" in *"--json reviews"*) printf "%s\n" "$GATE_REVIEWS" ;; esac'
}

decide() { run_naust gate decide terasology MovingBlocks/Terasology 7 "$@"; }
review() { printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "${4:-false}"; }

@test "a PR with no reviews waits; nothing runs unasked" {
    decide abc1234abc
    [ "$status" -eq 0 ]
    [ "$output" = $'wait\tno one listed has called abc1234 in' ]
}

@test "a listed login calling this naust in admits exactly the commit the review was given on" {
    export GATE_REVIEWS="$(review Cervator COMMENTED abc1234abc true)"
    decide abc1234abc
    [ "$output" = $'run\tcalled in by Cervator at abc1234' ]
    decide def5678def
    [ "$output" = $'wait\tno one listed has called def5678 in (stale: Cervator called abc1234 in)' ]
}

@test "a login listed without a machine account of its own may still call this one in" {
    export GATE_REVIEWS="$(review jdrueckert COMMENTED abc1234abc true)"
    decide abc1234abc
    [ "$output" = $'run\tcalled in by jdrueckert at abc1234' ]
}

@test "an approval, a dismissed review and a review without the call do not admit" {
    export GATE_REVIEWS="$(review Cervator APPROVED abc1234abc)
$(review Cervator DISMISSED abc1234abc true)
$(review Cervator CHANGES_REQUESTED abc1234abc)"
    decide abc1234abc
    [ "$output" = $'wait\tno one listed has called abc1234 in' ]
}

@test "a call from a login that is not listed never admits, and is named" {
    export GATE_REVIEWS="$(review stranger COMMENTED abc1234abc true)
$(review someoneelse APPROVED abc1234abc true)"
    decide abc1234abc
    [ "$output" = $'wait\tno one listed has called abc1234 in (ignored: a call from stranger; a call from someoneelse)' ]
}

@test "the gate reads the reviews of the right PR and matches the phrase addressed to this naust's account" {
    decide abc1234abc
    grep -q 'gh pr view 7 --repo MovingBlocks/Terasology --json reviews' "$STUB_LOG"
    grep -qF 'contains("haul it in")' "$STUB_LOG"
    grep -qF 'test("@agent-refr([^a-z0-9-]|$)")' "$STUB_LOG"
}

@test "a nod phrase with a quote or a backslash reaches jq escaped" {
    yq -i '.terasology.nod_phrase = "say \"go\" \\ now"' "$NAUST_WORKSPACE/realms/realm-test/naust/trust.yaml"
    decide abc1234abc
    [ "$status" -eq 0 ]
    grep -qF 'contains("say \"go\" \\ now")' "$STUB_LOG"
}

# The real filter against real reviews: the gh stub hands its --jq to jq over a
# canned reviews document, so what the gate asks GitHub for is what is tested.
with_real_jq() {
    export GATE_JSON="$BATS_TEST_TMPDIR/reviews.json"
    make_stub gh 'while [ $# -gt 0 ]; do [ "$1" = --jq ] && { jq -r "$2" "$GATE_JSON"; exit; }; shift; done; exit 1'
}
reviews_json() { # <login> <body> [<login> <body>]...
    local out="" login body
    while [ $# -gt 0 ]; do
        login="$1"; body="$2"; shift 2
        out="$out${out:+,}{\"author\":{\"login\":\"$login\"},\"state\":\"COMMENTED\",\"commit\":{\"oid\":\"abc1234abc\"},\"body\":\"$body\"}"
    done
    printf '{"reviews":[%s]}\n' "$out" > "$GATE_JSON"
}

@test "the call must name this naust's whole account: a login that merely starts with it is another naust" {
    with_real_jq
    reviews_json Cervator "@agent-refr-extra haul it in"
    decide abc1234abc
    [ "$output" = $'wait\tno one listed has called abc1234 in' ]
    reviews_json Cervator "Looks fine. @Agent-Refr, haul it in!"
    decide abc1234abc
    [ "$output" = $'run\tcalled in by Cervator at abc1234' ]
}

@test "a review read that fails is an error the tick can retry, not a wait that gates the PR" {
    make_stub gh 'exit 1'
    decide abc1234abc
    [ "$status" -eq 0 ]
    [ "$output" = $'error\tcould not read the reviews of MovingBlocks/Terasology#7' ]
}

@test "a nod phrase holding a control character is refused, not silently matched by nothing" {
    yq -i '.terasology.nod_phrase = "haul\nit in"' "$NAUST_WORKSPACE/realms/realm-test/naust/trust.yaml"
    decide abc1234abc
    [ "$status" -ne 0 ]
    grep -q 'nod_phrase' "$NAUST_LOG"
}

@test "a naust without an account cannot be called in" {
    yq -i 'del(.account)' "$NAUST_CONFIG"
    decide abc1234abc
    [ "$status" -ne 0 ]
    grep -q 'account' "$NAUST_LOG"
}

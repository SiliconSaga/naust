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
    grep -qF 'contains("@agent-refr")' "$STUB_LOG"
}

@test "a nod phrase with a quote or a backslash reaches jq escaped" {
    yq -i '.terasology.nod_phrase = "say \"go\" \\ now"' "$NAUST_WORKSPACE/realms/realm-test/naust/trust.yaml"
    decide abc1234abc
    [ "$status" -eq 0 ]
    grep -qF 'contains("say \"go\" \\ now")' "$STUB_LOG"
}

@test "a naust without an account cannot be called in" {
    yq -i 'del(.account)' "$NAUST_CONFIG"
    decide abc1234abc
    [ "$status" -ne 0 ]
    grep -q 'account' "$NAUST_LOG"
}

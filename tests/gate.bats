#!/usr/bin/env bats
load helpers/stub

# GATE_REVIEWS: one review per line, tab-separated login, state, commit, and
# whether the body carries the phrase (true/false), the shape the gate's --jq
# produces.
setup() {
    naust_setup
    export GATE_REVIEWS=""
    make_stub gh 'case "$*" in *"--json reviews"*) printf "%s\n" "$GATE_REVIEWS" ;; esac'
}

decide() { run_naust gate decide terasology MovingBlocks/Terasology 7 "$@"; }
review() { printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "${4:-false}"; }

@test "a maintainer's own PR runs" {
    decide Cervator Cervator/Terasology abc1234abc
    [ "$status" -eq 0 ]
    [ "$output" = $'run\tauthor Cervator is a maintainer' ]
}

@test "a trusted login or a trusted head repository runs" {
    decide trustedbot trustedbot/Terasology abc1234abc
    [ "$output" = $'run\tauthor trustedbot is trusted' ]
    decide stranger siliconsaga/terasology abc1234abc
    [ "$output" = $'run\thead repository siliconsaga/terasology is trusted' ]
}

@test "an unknown author with no reviews needs a nod" {
    decide stranger stranger/Terasology abc1234abc
    [ "$output" = $'nod\tneeds a nod from a maintainer' ]
}

@test "a maintainer's approval admits exactly the commit it was given on" {
    export GATE_REVIEWS="$(review jdrueckert APPROVED abc1234abc)"
    decide stranger stranger/Terasology abc1234abc
    [ "$output" = $'run\tapproved at abc1234 by maintainer jdrueckert' ]
    decide stranger stranger/Terasology def5678def
    [ "$output" = $'nod\tneeds a nod from a maintainer (stale: jdrueckert approved abc1234, head is def5678)' ]
}

@test "the phrase in a maintainer's review counts; a dismissed review and a bare request for changes do not" {
    export GATE_REVIEWS="$(review Cervator COMMENTED abc1234abc true)"
    decide stranger stranger/Terasology abc1234abc
    [ "$output" = $'run\t"ok to test" at abc1234 from maintainer Cervator' ]
    export GATE_REVIEWS="$(review Cervator DISMISSED abc1234abc)
$(review Cervator CHANGES_REQUESTED abc1234abc)"
    decide stranger stranger/Terasology abc1234abc
    [ "$output" = $'nod\tneeds a nod from a maintainer' ]
}

@test "a review from outside maintainers never admits, and is named" {
    export GATE_REVIEWS="$(review stranger APPROVED abc1234abc)
$(review someoneelse COMMENTED abc1234abc true)"
    decide stranger stranger/Terasology abc1234abc
    [ "$output" = $'nod\tneeds a nod from a maintainer (ignored: nod from stranger; nod from someoneelse)' ]
}

@test "the gate asks GitHub for the reviews of the right PR" {
    decide stranger stranger/Terasology abc1234abc
    grep -q 'gh pr view 7 --repo MovingBlocks/Terasology --json reviews' "$STUB_LOG"
}

@test "a nod phrase with a quote or a backslash reaches jq escaped" {
    yq -i '.terasology.nod_phrase = "say \"go\" \\ now"' "$NAUST_WORKSPACE/realms/realm-test/naust/trust.yaml"
    decide stranger stranger/Terasology abc1234abc
    [ "$status" -eq 0 ]
    grep -qF 'contains("say \"go\" \\ now")' "$STUB_LOG"
}

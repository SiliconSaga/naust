#!/usr/bin/env bats
load helpers/stub

setup() {
    naust_setup
    FIX="$BATS_TEST_DIRNAME/fixtures"
    JOB="$BATS_TEST_TMPDIR/job"
    mkdir -p "$JOB/baseline" "$JOB/reports"
    cat > "$JOB/job.yaml" <<'YAML'
repo: MovingBlocks/Terasology
number: 7
head: abc1234abc
base: develop
merge_base: 0000000aaa
author: Cervator
head_repo: Cervator/Terasology
with:
bay: bay-1
started: 1760000000
YAML
    printf '1\treset\tpass\t30\n2\tcheckout\tpass\t5\n3\tscope\tpass\t1\n4\tbaseline\tpass\t200\n5\tbuild\tpass\t300\n5b\tcompile-all\tpass\t400\n5c\ttests\tpass\t250\n6\theadless\tpass\t90\n7\tsmoke\tfail\t120\n8\ttree\tfail\t2\n9\treport\tpass\t1\n' > "$JOB/steps.tsv"
    printf 'class ATest \nclass BTest \ndefault\n' > "$JOB/scope.txt"
    printf ' engine/src/main/java/org/x/A.java | 2 +-\n 1 file changed\n' > "$JOB/diff-stat.txt"
    cp "$FIX/pass.xml" "$JOB/baseline/"; cp "$FIX/fail-old.xml" "$JOB/baseline/"
    cp "$FIX/pass.xml" "$JOB/reports/"; cp "$FIX/fail-old.xml" "$JOB/reports/"; cp "$FIX/fail-new.xml" "$JOB/reports/"
    printf 'terasology/modules/Health\t?? src/test/resources/logback-test.xml\tknown\nterasology\t?? natives/stray.dll\tunexpected\n' > "$JOB/tree.txt"
    printf 'Checks: 1 pass, 0 fail, 0 pending\n' > "$JOB/checks.txt"
    printf 'last line of smoke\n' > "$JOB/smoke.log"
    export NAUST_PROFILE=terasology
}

@test "junit sums a directory and lists failing cases" {
    run_naust report junit "$JOB/reports"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'6\t1\t1\t1' ]
    [ "${lines[1]}" = "org.x.BTest.broken" ]
    [ "${lines[2]}" = "org.x.CTest.flaky" ]
}

@test "render writes report.md with the verdicts a human needs first" {
    run_naust report render "$JOB"
    [ "$status" -eq 0 ]
    r="$JOB/report.md"
    grep -q '^# MovingBlocks/Terasology#7 — abc1234 onto develop, bay-1' "$r"
    grep -q '| 7 | smoke | fail |' "$r"
    grep -q '| PR | 6 | 1 | 1 | 1 |' "$r"
    grep -q '| base | 4 | 0 | 1 | 1 |' "$r"
    grep -q 'New on this PR' "$r"
    grep -q 'org.x.BTest.broken' "$r"
    grep -q 'Also failing on the base' "$r"
    grep -q 'org.x.CTest.flaky' "$r"
    grep -q 'natives/stray.dll' "$r"
    grep -q 'Checks: 1 pass, 0 fail, 0 pending' "$r"
    grep -q '## What needs a human' "$r"
    grep -q 'smoke boot failed' "$r"
    grep -q 'org.x.BTest.broken' "$r"
}

@test "comment.md is signed by the persona and names no bay path" {
    run_naust report render "$JOB"
    c="$JOB/comment.md"
    grep -q 'Gooey' "$c"
    ! grep -q "$BATS_TEST_TMPDIR" "$c"
    grep -q 'What needs a human' "$c"
}

@test "a skipped step reads as not run, never as passed" {
    printf '1\treset\tfail\t3\n2\tcheckout\tskipped\t0\n9\treport\tpass\t1\n' > "$JOB/steps.tsv"
    rm -f "$JOB/reports"/* "$JOB/baseline"/*
    run_naust report render "$JOB"
    grep -q '| 2 | checkout | not run |' "$JOB/report.md"
    grep -q 'reset failed' "$JOB/report.md"
    ! grep -q '| PR |' "$JOB/report.md"
}

@test "a moved head is the first thing a human reads" {
    printf '1\treset\tpass\t3\n2\tcheckout\tfail\t2\n9\treport\tpass\t1\n' > "$JOB/steps.tsv"
    printf 'head moved: the gate admitted abc1234abc, the fetch returned def5678def; a new nod is needed for the new head\n' > "$JOB/checkout.log"
    rm -f "$JOB/reports"/* "$JOB/baseline"/*
    run_naust report render "$JOB"
    grep -q 'head moved' "$JOB/report.md"
    grep -q 'new nod' "$JOB/comment.md"
}

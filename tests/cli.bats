#!/usr/bin/env bats

load helpers

setup() {
    common_setup
}

@test "--help lists the commands" {
    run -0 mot --help
    [[ "$output" == *"optimize"* ]]
    [[ "$output" == *"stats"* ]]
}

@test "--version prints the version" {
    run -0 mot --version
    [[ "$output" =~ ^mot\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "no command prints usage and fails" {
    run -1 mot
    [[ "$output" == *"Usage: mot"* ]]
}

@test "unknown command fails" {
    run -1 mot compress "$SRC"
    [[ "$output" == *"unknown command 'compress'"* ]]
}

@test "run.sh forwards to bin/mot" {
    run -0 "$ROOT/run.sh" --version
    [[ "$output" == "mot "* ]]
}

@test "optimize --help and stats --help print their options" {
    run -0 mot optimize --help
    [[ "$output" == *"--dry-run"* ]]
    run -0 mot stats --help
    [[ "$output" == *"--dupes"* ]]
}

@test "optimize rejects a missing source directory" {
    run -1 mot optimize "$BATS_TEST_TMPDIR/missing"
    [[ "$output" == *"does not exist"* ]]
}

@test "optimize rejects an existing destination" {
    mkdir -p "$OUT"
    run -1 mot optimize "$SRC" "$OUT"
    [[ "$output" == *"already exists"* ]]
}

@test "optimize rejects an unknown level" {
    run -1 mot optimize --level extreme "$SRC"
    [[ "$output" == *"--level must be"* ]]
}

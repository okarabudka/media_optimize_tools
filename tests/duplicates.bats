#!/usr/bin/env bats

load helpers

setup() {
    common_setup
    make_jpeg "$SRC/a.jpg"
    mkdir "$SRC/copy"
    cp "$SRC/a.jpg" "$SRC/copy/a.jpg"
    cp "$SRC/a.jpg" "$SRC/z.jpg"
    make_jpeg "$SRC/unique.jpg" 96x96
}

@test "stats --dupes reports redundant files and keeps the first one" {
    run -0 mot stats --dupes "$SRC"

    [[ "$output" == *"Duplicate groups : 1"* ]]
    [[ "$output" == *"Redundant files  : 2"* ]]
    [[ "$output" == *"[dup]  $SRC/copy/a.jpg"* ]]
    [[ "$output" == *"[dup]  $SRC/z.jpg"* ]]
    [[ "$output" != *"[dup]  $SRC/a.jpg"* ]]
}

@test "--copy-dupes copies redundant files and keeps the source" {
    local review="$BATS_TEST_TMPDIR/review"

    run -0 mot optimize --copy-dupes "$review" "$SRC"

    [[ -f "$review/copy/a.jpg" && -f "$review/z.jpg" ]]
    [[ ! -e "$review/a.jpg" && ! -e "$review/unique.jpg" ]]
    [[ -f "$SRC/copy/a.jpg" && -f "$SRC/z.jpg" ]]
}

@test "--delete-dupes without a terminal deletes nothing" {
    run mot optimize --delete-dupes "$SRC"

    [[ "$output" == *"Aborted."* ]]
    [[ -f "$SRC/copy/a.jpg" && -f "$SRC/z.jpg" ]]
}

@test "--delete-dupes --yes deletes redundant files only" {
    run -0 mot optimize --delete-dupes --yes "$SRC"

    [[ -f "$SRC/a.jpg" && -f "$SRC/unique.jpg" ]]
    [[ ! -e "$SRC/copy/a.jpg" && ! -e "$SRC/z.jpg" ]]
}

@test "no duplicates is reported as such" {
    rm "$SRC/copy/a.jpg" "$SRC/z.jpg"

    run -0 mot stats --dupes "$SRC"

    [[ "$output" == *"No duplicate files found."* ]]
}

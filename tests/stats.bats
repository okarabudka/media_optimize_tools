#!/usr/bin/env bats

load helpers

setup() {
    common_setup
    mkdir "$SRC/2021" "$SRC/2022"
    make_jpeg "$SRC/2021/a.jpg"
    make_video "$SRC/2022/clip.mov"
}

@test "stats lists usage, largest files and MOV files" {
    run -0 mot stats "$SRC"

    [[ "$output" == *"Directory usage (depth 2):"* ]]
    [[ "$output" == *"Top 50 largest files"* ]]
    [[ "$output" == *"[MOV "*"$SRC/2022/clip.mov"* ]]
}

@test "stats --subdirs counts files per subdirectory" {
    run -0 mot stats --subdirs "$SRC"

    [[ "$output" == *"Directories: 2   Total files: 2"* ]]
}

@test "stats does not modify anything" {
    local before
    before=$(find "$SRC" -type f -printf '%p %s %T@\n' | sort)

    run -0 mot stats --dupes --subdirs "$SRC"

    [[ "$(find "$SRC" -type f -printf '%p %s %T@\n' | sort)" == "$before" ]]
}

@test "stats rejects a non-integer depth" {
    run -1 mot stats --depth x "$SRC"
    [[ "$output" == *"--depth must be an integer"* ]]
}

@test "stats handles more files than fit the top list" {
    mkdir "$SRC/many"
    (cd "$SRC/many" && touch file{1..30000}.txt)

    run -0 mot stats --top-files 1 "$SRC"

    [[ "$output" == *"Elapsed:"* ]]
}

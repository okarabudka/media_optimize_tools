#!/usr/bin/env bats

load helpers

setup() {
    common_setup
}

@test "dry-run changes nothing and creates no destination" {
    make_jpeg "$SRC/photo.jpg"
    make_video "$SRC/clip.mov"
    local before
    before=$(checksum "$SRC/photo.jpg")

    run -0 mot optimize --dry-run "$SRC" "$OUT"

    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"Photos"*"1 files"* ]]
    [[ ! -e "$OUT" ]]
    [[ "$(checksum "$SRC/photo.jpg")" == "$before" ]]
    [[ -f "$SRC/clip.mov" ]]
}

@test "optimize shrinks the copy and leaves the source untouched" {
    make_jpeg "$SRC/photo.jpg"
    mkdir "$SRC/2020"
    make_video "$SRC/2020/clip.mov"
    local before
    before=$(checksum "$SRC/photo.jpg")

    run -0 mot optimize "$SRC" "$OUT"

    [[ "$output" == *"Done."* ]]
    [[ "$(checksum "$SRC/photo.jpg")" == "$before" ]]
    [[ -f "$SRC/2020/clip.mov" ]]
    (($(stat -c %s "$OUT/photo.jpg") < $(stat -c %s "$SRC/photo.jpg")))
    [[ -f "$OUT/2020/clip.mp4" && ! -e "$OUT/2020/clip.mov" ]]
    [[ ! -e "$OUT/.optimize_progress" ]]
}

@test "default destination is SOURCE_<level>" {
    make_jpeg "$SRC/photo.jpg"

    run -0 mot optimize --level aggressive "$SRC"

    [[ -f "${SRC}_aggressive/photo.jpg" ]]
}

@test "resume skips files recorded as done" {
    make_jpeg "$SRC/done.jpg"
    make_jpeg "$SRC/todo.jpg" 160x160
    cp -a "$SRC" "$OUT"
    echo "done.jpg" >"$OUT/.optimize_progress"
    local done_before
    done_before=$(checksum "$OUT/done.jpg")

    run -0 mot optimize --resume "$OUT"

    [[ "$output" == *"[SKIP] done.jpg"* ]]
    [[ "$(checksum "$OUT/done.jpg")" == "$done_before" ]]
    (($(stat -c %s "$OUT/todo.jpg") < $(stat -c %s "$SRC/todo.jpg")))
    [[ ! -e "$OUT/.optimize_progress" ]]
}

@test "parallel jobs process every file" {
    local i
    for i in 1 2 3 4; do
        make_jpeg "$SRC/p$i.jpg"
    done

    run -0 mot optimize --jobs 3 --only-exts jpg "$SRC" "$OUT"

    for i in 1 2 3 4; do
        (($(stat -c %s "$OUT/p$i.jpg") < $(stat -c %s "$SRC/p$i.jpg")))
    done
}

@test "--only-exts limits the processed types" {
    make_jpeg "$SRC/photo.jpg"
    make_video "$SRC/clip.mov"

    run -0 mot optimize --only-exts jpg "$SRC" "$OUT"

    [[ -f "$OUT/clip.mov" && ! -e "$OUT/clip.mp4" ]]
}

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

@test "PNG to JPEG never overwrites an existing JPEG with the same name" {
    make_jpeg "$SRC/shot.jpg" 128x128
    make_png_opaque "$SRC/shot.png" 64x48

    run -0 mot optimize --only-exts png "$SRC" "$OUT"

    [[ "$(checksum "$OUT/shot.jpg")" == "$(checksum "$SRC/shot.jpg")" ]]
    [[ "$(magick identify -format '%m %wx%h' "$OUT/shot-1.jpg")" == "JPEG 64x48" ]]
    [[ ! -e "$OUT/shot.png" ]]
}

@test "MOV to MP4 never overwrites an existing MP4 with the same name" {
    make_video "$SRC/clip.mp4"
    make_video "$SRC/clip.mov" -t 0.5

    run -0 mot optimize --only-exts mov "$SRC" "$OUT"

    [[ "$(checksum "$OUT/clip.mp4")" == "$(checksum "$SRC/clip.mp4")" ]]
    [[ -f "$OUT/clip-1.mp4" && ! -e "$OUT/clip.mov" ]]
}

@test "no temp files are left behind" {
    make_jpeg "$SRC/photo.jpg"
    make_png_opaque "$SRC/shot.png"
    make_video "$SRC/clip.mov"

    run -0 mot optimize "$SRC" "$OUT"

    [[ -z "$(find "$OUT" -name '.mot-tmp.*')" ]]
}

@test "PNG with transparency stays PNG and keeps its alpha channel" {
    make_png_alpha "$SRC/logo.png"

    run -0 mot optimize "$SRC" "$OUT"

    [[ ! -e "$OUT/logo.jpg" ]]
    [[ "$(checksum "$OUT/logo.png")" == "$(checksum "$SRC/logo.png")" ]]
}

@test "opaque PNG is converted to JPEG" {
    make_png_opaque "$SRC/photo.png"

    run -0 mot optimize "$SRC" "$OUT"

    [[ "$(magick identify -format '%m' "$OUT/photo.jpg")" == JPEG ]]
    [[ ! -e "$OUT/photo.png" ]]
}

@test "--keep-png keeps opaque PNGs as PNG" {
    make_png_opaque "$SRC/screen.png"

    run -0 mot optimize --keep-png "$SRC" "$OUT"

    [[ -f "$OUT/screen.png" && ! -e "$OUT/screen.jpg" ]]
}

@test "--optimize-png recompresses PNGs losslessly" {
    make_png_alpha "$SRC/logo.png"
    # Re-save without compression so there is something to gain
    magick "$SRC/logo.png" -define png:compression-level=0 PNG32:"$SRC/logo.png"

    run -0 mot optimize --optimize-png "$SRC" "$OUT"

    (($(stat -c %s "$OUT/logo.png") < $(stat -c %s "$SRC/logo.png")))
    [[ "$(magick compare -metric AE "$SRC/logo.png" "$OUT/logo.png" null: 2>&1)" == 0* ]]
    [[ "$(magick identify -format '%[opaque]' "$OUT/logo.png")" == False ]]
}

@test "video is not replaced when the re-encode is larger" {
    make_video "$SRC/small.mov" -crf 45 -b:a 32k
    make_video "$SRC/small.mp4" -crf 45 -b:a 32k

    run -0 mot optimize --crf 0 --preset ultrafast "$SRC" "$OUT"

    [[ "$(checksum "$OUT/small.mov")" == "$(checksum "$SRC/small.mov")" ]]
    [[ "$(checksum "$OUT/small.mp4")" == "$(checksum "$SRC/small.mp4")" ]]
    [[ ! -e "$OUT/small-1.mp4" ]]
}

@test "modification time is preserved for optimized and converted files" {
    make_jpeg "$SRC/photo.jpg"
    make_png_opaque "$SRC/shot.png"
    make_video "$SRC/clip.mov"
    touch -d '2019-07-14 10:20:30' "$SRC/photo.jpg" "$SRC/shot.png" "$SRC/clip.mov"
    local expected
    expected=$(mtime "$SRC/photo.jpg")

    run -0 mot optimize "$SRC" "$OUT"

    (($(stat -c %s "$OUT/photo.jpg") < $(stat -c %s "$SRC/photo.jpg")))
    [[ "$(mtime "$OUT/photo.jpg")" == "$expected" ]]
    [[ "$(mtime "$OUT/shot.jpg")" == "$expected" ]]
    [[ "$(mtime "$OUT/clip.mp4")" == "$expected" ]]
}

@test "EXIF of photos is preserved" {
    make_jpeg_with_exif "$SRC/photo.jpg" "2019:07:14 10:20:30"

    run -0 mot optimize --level maximum "$SRC" "$OUT"

    (($(stat -c %s "$OUT/photo.jpg") < $(stat -c %s "$SRC/photo.jpg")))
    [[ "$(magick identify -format '%[EXIF:DateTimeOriginal]|%[EXIF:Make]' "$OUT/photo.jpg")" == "2019:07:14 10:20:30|TestCam" ]]
}

@test "video metadata and creation time are preserved, moov atom first" {
    make_video "$SRC/clip.mov" -movflags use_metadata_tags \
        -metadata creation_time=2019-07-14T10:20:30Z \
        -metadata com.apple.quicktime.location.ISO6709=+52.5200+013.4050/

    run -0 mot optimize "$SRC" "$OUT"

    run -0 ffprobe -v error -show_entries format_tags -of default=nw=1 "$OUT/clip.mp4"
    [[ "$output" == *"creation_time=2019-07-14T10:20:30"* ]]
    [[ "$output" == *"location.ISO6709=+52.5200+013.4050/"* ]]
    run -0 python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(not d.find(b"moov") < d.find(b"mdat"))' "$OUT/clip.mp4"
}

@test "HEIC is left alone without --heic-to-jpeg" {
    heic_encoder_available || skip "no HEIC encoder in this image"
    make_heic "$SRC/IMG_0001.heic"

    run -0 mot optimize "$SRC" "$OUT"

    [[ "$(checksum "$OUT/IMG_0001.heic")" == "$(checksum "$SRC/IMG_0001.heic")" ]]
    [[ ! -e "$OUT/IMG_0001.jpg" ]]
}

@test "--heic-to-jpeg converts HEIC to JPEG with EXIF and mtime" {
    heic_encoder_available || skip "no HEIC encoder in this image"
    make_jpeg_with_exif "$BATS_TEST_TMPDIR/exif.jpg" "2019:07:14 10:20:30"
    magick "$BATS_TEST_TMPDIR/exif.jpg" -quality 90 "$SRC/IMG_0001.HEIC"
    touch -d '2019-07-14 10:20:30' "$SRC/IMG_0001.HEIC"

    run -0 mot optimize --heic-to-jpeg "$SRC" "$OUT"

    [[ ! -e "$OUT/IMG_0001.HEIC" ]]
    [[ "$(magick identify -format '%m %[EXIF:DateTimeOriginal]' "$OUT/IMG_0001.jpg")" == "JPEG 2019:07:14 10:20:30" ]]
    [[ "$(mtime "$OUT/IMG_0001.jpg")" == "$(mtime "$SRC/IMG_0001.HEIC")" ]]
}

@test "dry-run shows the HEIC conversion" {
    heic_encoder_available || skip "no HEIC encoder in this image"
    make_heic "$SRC/IMG_0001.heic"

    run -0 mot optimize --dry-run --heic-to-jpeg "$SRC" "$OUT"

    [[ "$output" == *"HEIC→JPEG"*"1 files"* ]]
}

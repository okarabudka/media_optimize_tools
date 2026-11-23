# shellcheck shell=bash
# Shared setup and fixture generators. Fixtures are generated per test in BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

# shellcheck disable=SC2034 # the variables are used by the test files
common_setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MOT="$ROOT/bin/mot"
    SRC="$BATS_TEST_TMPDIR/src"
    OUT="$BATS_TEST_TMPDIR/out"
    mkdir -p "$SRC"
}

# Runs mot without a terminal on stdin, so confirmations are never answered.
mot() {
    "$MOT" "$@" </dev/null
}

# Noisy high-quality JPEG: shrinks noticeably when recompressed.
make_jpeg() {
    magick -seed 7 -size "${2:-128x128}" plasma:fractal -quality 100 "$1"
}

make_jpeg_with_exif() {
    make_jpeg "$1"
    python3 "$BATS_TEST_DIRNAME/add_exif.py" "$1" "$2"
}

make_png_opaque() {
    magick -seed 7 -size "${2:-64x48}" plasma:fractal PNG24:"$1"
}

# Noisy content with a transparent border: as JPEG it would be much smaller, but lose the alpha.
make_png_alpha() {
    magick -seed 7 -size 64x64 plasma:fractal \
        \( -size 64x64 xc:black -fill white -draw 'circle 32,32 32,8' \) \
        -alpha off -compose CopyOpacity -composite PNG32:"$1"
}

# One-second H.264/AAC clip; extra ffmpeg output options may follow the path.
make_video() {
    local path="$1"
    shift
    ffmpeg -nostdin -loglevel error -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
        -f lavfi -i sine=duration=1 -c:v libx264 -crf 18 -c:a aac -shortest "$@" "$path"
}

# HEIC fixtures need a libheif encoder plugin, which only the test image installs.
make_heic() {
    magick -seed 7 -size 128x128 plasma:fractal -quality 90 "$1"
}

heic_encoder_available() {
    make_heic "$BATS_TEST_TMPDIR/probe.heic" 2>/dev/null
}

mtime() { stat -c %Y -- "$1"; }

checksum() { sha256sum -- "$1" | cut -d' ' -f1; }

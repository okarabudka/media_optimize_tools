# shellcheck shell=bash
# mot optimize: copy a media archive and optimize the copy. Sourced by bin/mot.
#
# Originals are never modified. The command:
#   1. Copies SOURCE_DIR to DESTINATION_DIR with rsync
#   2. Optimizes the copy based on the chosen level
#   3. Prints a savings report with top files

# ── Level presets ────────────────────────────────────────────────────────────
# archive: convert formats only, near-lossless quality
readonly ARC_JPEG_QUALITY=95   ARC_IMG_MAX_DIM=99999
readonly ARC_VIDEO_CRF=20      ARC_VIDEO_PRESET="slow"
readonly ARC_VIDEO_MAX_W=3840  ARC_VIDEO_MAX_H=2160   ARC_AUDIO_BITRATE="256k"
readonly ARC_REENCODE_ALL_VIDEO=0

# moderate: safe everyday optimization, loss barely noticeable
readonly MOD_JPEG_QUALITY=88   MOD_IMG_MAX_DIM=8000
readonly MOD_VIDEO_CRF=25      MOD_VIDEO_PRESET="medium"
readonly MOD_VIDEO_MAX_W=3840  MOD_VIDEO_MAX_H=2160   MOD_AUDIO_BITRATE="192k"
readonly MOD_REENCODE_ALL_VIDEO=1

# aggressive: visible savings, quality still acceptable
readonly AGG_JPEG_QUALITY=80   AGG_IMG_MAX_DIM=3840
readonly AGG_VIDEO_CRF=28      AGG_VIDEO_PRESET="medium"
readonly AGG_VIDEO_MAX_W=1920  AGG_VIDEO_MAX_H=1080   AGG_AUDIO_BITRATE="192k"
readonly AGG_REENCODE_ALL_VIDEO=1

# maximum: max space savings, noticeable quality loss
readonly MAX_JPEG_QUALITY=70   MAX_IMG_MAX_DIM=2560
readonly MAX_VIDEO_CRF=32      MAX_VIDEO_PRESET="medium"
readonly MAX_VIDEO_MAX_W=1280  MAX_VIDEO_MAX_H=720    MAX_AUDIO_BITRATE="128k"
readonly MAX_REENCODE_ALL_VIDEO=1

# ── Helpers ───────────────────────────────────────────────────────────────────
optimize_usage() {
    cat <<'EOF'
Usage: mot optimize [OPTIONS] SOURCE_DIR [DESTINATION_DIR]

Creates an optimized copy of SOURCE_DIR. Originals are never modified.
Default destination: SOURCE_DIR_<level>  (e.g. Photos_aggressive)

Options:
  --level LEVEL                Level of optimization (default: moderate)
  --only-exts EXT[,EXT,...]   Process only these extensions, e.g. mov,jpg,png
  --skip-exts EXT[,EXT,...]   Skip these extensions, e.g. mp4,mkv
  --dry-run                   Show estimated savings per type, make no changes
  --skip-copy                 Skip rsync step; optimize an already-copied directory
  --resume                    Resume interrupted optimization of DEST_DIR
                              (implies --skip-copy; use the same --level as the original run)
  --copy-dupes DIR            Find duplicate files and copy redundant ones to DIR
  --delete-dupes              Find duplicate files and delete redundant ones (asks confirmation)
  -y, --yes                   Answer yes to confirmations (duplicate deletion, low disk space)
  --heic-to-jpeg              Convert HEIC/HEIF photos to JPEG for compatibility, even when
                              the JPEG is larger (EXIF kept). Without it HEIC is not touched.
  --keep-png                  Keep all PNGs as PNG (PNGs with transparency always stay PNG)
  --optimize-png              Recompress PNGs that stay PNG losslessly (default: leave them as is)
  --log FILE                  Append all output to FILE and terminal
  --jobs N                    Parallel workers for photo/video processing (default: 1)
  -h, --help                  Show this help

Levels (--level):
  archive    Near-lossless. Only converts formats (MOV/VOB→MP4).
             JPEG 95, no resize, CRF 20 slow 4K. Good for precious originals.

  moderate   Safe optimization. Loss barely noticeable. (default)
             JPEG 88, max 8000px, CRF 25 medium 4K. Re-encodes all video.

  aggressive Strong compression. Quality still acceptable for everyday use.
             JPEG 80, max 3840px, CRF 28 medium 1080p. Re-encodes all video.

  maximum    Maximum space savings. Noticeable quality loss.
             JPEG 70, max 2560px, CRF 32 medium 720p. Re-encodes all video.

Extension filters:
  --only-exts and --skip-exts are mutually exclusive.
  Examples:
    --only-exts mov              only convert videos
    --only-exts jpg,jpeg,png     only optimize photos
    --skip-exts mp4,mkv,avi      skip all video re-encoding
    --skip-exts mov              skip MOV conversion

Quality overrides (applied on top of --level, for fine-tuning):
  --jpeg-quality N     JPEG/WEBP quality 1-100, also for PNGs converted to JPEG
  --max-image-dim N    Resize if longest side > N pixels
  --crf N              Video CRF 0-51 (lower = better quality)
  --preset NAME        ffmpeg preset: ultrafast fast medium slow veryslow
  --max-width N        Downscale video if wider than N px
  --max-height N       Downscale video if taller than N px
  --audio-bitrate VAL  AAC bitrate e.g. 128k 192k 256k
  --min-photo-mb N     Skip photos already smaller than N MB
  --min-video-mb N     Skip videos/MOV/VOB already smaller than N MB

Examples:
  mot optimize /media/usb/Photos
  mot optimize --level aggressive /media/usb/Photos /media/usb/Photos_opt
  mot optimize --dry-run --level aggressive /media/usb/Photos
  mot optimize --only-exts mov,jpg,jpeg /media/usb/Photos
  mot optimize --skip-exts mp4,mkv /media/usb/Photos
  mot optimize --log ~/opt.log --jobs 4 /media/usb/Photos
  mot optimize --skip-copy --level aggressive /media/usb/Photos_aggressive
  mot optimize --resume --level aggressive /media/usb/Photos_aggressive
  mot optimize --copy-dupes /tmp/dupes_review /media/usb/Photos
  mot optimize --delete-dupes /media/usb/Photos
EOF
}

check_free_space() {
    local src="$1" dest_parent="$2" level="${3:-moderate}"
    local src_bytes free_bytes
    src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1) || return 0
    free_bytes=$(df -B1 --output=avail "$dest_parent" 2>/dev/null | tail -1 | tr -d ' ') || return 0

    # Estimate output size based on level (conservative but realistic)
    local ratio
    case "$level" in
        archive)    ratio=100 ;;
        moderate)   ratio=85  ;;
        aggressive) ratio=60  ;;
        maximum)    ratio=45  ;;
        *)          ratio=85  ;;
    esac
    local est_bytes
    est_bytes=$(awk -v s="$src_bytes" -v r="$ratio" 'BEGIN{ printf "%d\n", s*r/100 }')

    if (( est_bytes > free_bytes )); then
        echo "WARNING: Estimated output ~$(format_bytes "$est_bytes") but only $(format_bytes "$free_bytes") free on destination." >&2
        if ! confirm "Continue anyway?"; then
            echo "Aborted." >&2
            exit 1
        fi
    fi
}

# ── Extension filter ──────────────────────────────────────────────────────────
FILTER_EXTS=""   # --only-exts: empty = allow all
SKIP_EXTS=""     # --skip-exts: empty = skip nothing
MIN_PHOTO_BYTES=0  # --min-photo-mb: skip photos smaller than this (0 = process all)
MIN_VIDEO_BYTES=0  # --min-video-mb: skip videos smaller than this (0 = process all)

ext_allowed() {
    local ext="${1,,}"
    local IFS=',' e
    if [[ -n "$SKIP_EXTS" ]]; then
        for e in $SKIP_EXTS; do [[ "${e,,}" == "$ext" ]] && return 1; done
        return 0
    fi
    if [[ -z "$FILTER_EXTS" ]]; then
        return 0
    fi
    for e in $FILTER_EXTS; do [[ "${e,,}" == "$ext" ]] && return 0; done
    return 1
}

# ── Image tool ────────────────────────────────────────────────────────────────
# Stored as array to avoid word-split issues with paths containing spaces
IMGCMD=()
init_image_tool() {
    if command -v magick >/dev/null 2>&1; then
        IMGCMD=(magick)
    elif command -v convert >/dev/null 2>&1 && convert --version 2>&1 | grep -qi imagemagick; then
        IMGCMD=(convert)
    else
        fail "ImageMagick (magick or convert) is required for photo processing."
    fi
}
run_convert() { "${IMGCMD[@]}" "$@"; }

# HEIC decoder: ImageMagick built with libheif, else heif-convert from libheif-examples.
HEIC_DECODER=""
init_heic_decoder() {
    if "${IMGCMD[@]}" -list format 2>/dev/null | grep -Eq '^ *HEIC\*? +HEIC +r'; then
        HEIC_DECODER=imagemagick
    elif command -v heif-convert >/dev/null 2>&1; then
        HEIC_DECODER=heif-convert
    else
        fail "--heic-to-jpeg needs ImageMagick with HEIC support (libheif) or heif-convert."
    fi
}
run_identify() {
    if [[ "${IMGCMD[0]}" == magick ]]; then
        magick identify "$@"
    else
        identify "$@"
    fi
}

# ── Temp file cleanup ─────────────────────────────────────────────────────────
STATS_DIR=""
cleanup() {
    # Kill any still-running background jobs before exiting
    jobs -rp 2>/dev/null | xargs -r kill 2>/dev/null || true
    if [[ -n "$STATS_DIR" ]]; then
        rm -rf "$STATS_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ── Parallel pool ─────────────────────────────────────────────────────────────
PARALLEL_JOBS=1
PROGRESS_FILE=""   # path to resume progress file; empty = no tracking
OPT_ROOT=""        # directory being optimized; progress entries are relative to it
KEEP_PNG=0         # --keep-png: never convert PNG to JPEG
HEIC_TO_JPEG=0     # --heic-to-jpeg: convert HEIC/HEIF photos to JPEG
OPTIMIZE_PNG=0     # --optimize-png: recompress PNGs that stay PNG losslessly
RESUME=0           # 1 when --resume was passed
wait_for_slot() {
    while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
        wait -n 2>/dev/null || sleep 0.05
    done
}

# ── File collection ───────────────────────────────────────────────────────────
# Single find pass — avoids re-reading the directory tree multiple times.
# Sets globals (must be declared local -a by the caller):
#   img_files  img_sizes   heic_files  heic_sizes
#   video_primary  video_primary_sizes   video_other  video_other_sizes
#   skipped_vid  skipped_vid_sizes
#
# Sizes are collected in the same pass, so no separate stat calls are needed.
# with_skipped=1 → populate skipped_vid (videos not re-encoded at this level)
collect_media_files() {
    local dir="$1" with_skipped="${2:-0}"
    local _sz _path _ext

    printf 'Scanning %s ...\n' "$dir"

    while IFS= read -r -d '' _sz && IFS= read -r -d '' _path; do
        _ext="${_path##*.}"; _ext="${_ext,,}"
        ext_allowed "$_ext" || continue
        case "$_ext" in
            jpg|jpeg|png|webp)
                if (( MIN_PHOTO_BYTES > 0 && _sz < MIN_PHOTO_BYTES )); then
                    continue
                fi
                img_files+=("$_path"); img_sizes+=("$_sz") ;;
            heic|heif)
                if ((!HEIC_TO_JPEG)) || ((MIN_PHOTO_BYTES > 0 && _sz < MIN_PHOTO_BYTES)); then
                    continue
                fi
                heic_files+=("$_path"); heic_sizes+=("$_sz") ;;
            mov|vob)
                if (( MIN_VIDEO_BYTES > 0 && _sz < MIN_VIDEO_BYTES )); then
                    continue
                fi
                video_primary+=("$_path"); video_primary_sizes+=("$_sz") ;;
            mp4|mkv|avi|m4v|webm|mpg|mpeg)
                if (( MIN_VIDEO_BYTES > 0 && _sz < MIN_VIDEO_BYTES )); then
                    continue
                fi
                if (( REENCODE_ALL_VIDEO )); then
                    video_other+=("$_path"); video_other_sizes+=("$_sz")
                elif (( with_skipped )); then
                    skipped_vid+=("$_path"); skipped_vid_sizes+=("$_sz")
                fi
                ;;
        esac
    done < <(find "$dir" -type f -size +0 ! -name "${TMP_PREFIX}*" -printf '%s\0%p\0')
}

# ── Output placement ──────────────────────────────────────────────────────────
readonly TMP_PREFIX=".mot-tmp."

# Sets the variable named $1 to a temp path next to $2 with extension $3. The name is
# hidden from the media scan and unique per worker process and source file.
set_tmp_path() {
    local -n _tmp_ref="$1"
    _tmp_ref="${2%/*}/${TMP_PREFIX}${BASHPID}.${2##*/}.$3"
}

# Reserves a file name that does not exist yet: STEM.EXT, else STEM-1.EXT, STEM-2.EXT, ...
# The empty placeholder is created with noclobber (O_EXCL), so parallel workers and
# existing files are never overwritten. Prints the reserved path.
reserve_free_path() {
    local stem="$1" ext="$2" candidate="$1.$2" n=0
    until (set -o noclobber && : >"$candidate") 2>/dev/null; do
        n=$((n + 1))
        if ((n > 999)); then
            echo "Cannot find a free name for $stem.$ext" >&2
            return 1
        fi
        candidate="$stem-$n.$ext"
    done
    printf '%s\n' "$candidate"
}

# Moves the finished temp file $1 into place for the source $2, with the source's
# modification time and permissions. Same extension: replaces the source. New
# extension $3: reserves a free name and removes the source afterwards.
# Prints the final path.
install_result() {
    local tmp="$1" src="$2" new_ext="${3:-}" dst
    touch -r "$src" -- "$tmp"
    chmod --reference="$src" -- "$tmp"
    if [[ -z "$new_ext" ]]; then
        mv -f -- "$tmp" "$src"
        printf '%s\n' "$src"
        return
    fi
    dst=$(reserve_free_path "${src%.*}" "$new_ext") || return 1
    mv -f -- "$tmp" "$dst"
    rm -f -- "$src"
    printf '%s\n' "$dst"
}

# Records processed paths (relative to the optimized directory) for --resume.
mark_done() {
    if [[ -n "$PROGRESS_FILE" ]]; then
        printf '%s\n' "$@" >>"$PROGRESS_FILE"
    fi
}

# ── Per-file processors ───────────────────────────────────────────────────────

# True when the image has transparent pixels; a PNG with only opaque alpha is opaque.
has_transparency() {
    [[ "$(run_identify -format '%[opaque]' "$1" 2>/dev/null)" == False ]]
}

# Optimizes JPEG/WEBP in place and converts opaque PNG to JPEG; keeps the result only
# if smaller. PNGs with transparency (or all PNGs with --keep-png) stay PNG and are only
# recompressed losslessly with --optimize-png.
# Writes "photo|rel|bytes_before|bytes_after[|fail]" to $stats_file.
optimize_photo() {
    local file="$1" rel="$2" stats_file="$3"
    local ext="${file##*.}" new_ext=""
    ext="${ext,,}"

    local tmp sz_before sz_after out
    local -a ops=(-auto-orient +profile "!exif,!icc,!xmp,*" -resize "${IMG_MAX_DIM}x${IMG_MAX_DIM}>" -quality "$JPEG_QUALITY")
    sz_before=$(stat -c%s -- "$file")

    local input="$file" keep_larger=0
    if [[ "$ext" == heic || "$ext" == heif ]]; then
        # Converted for compatibility even when the JPEG is larger
        new_ext=jpg
        keep_larger=1
        if [[ "$HEIC_DECODER" == heif-convert ]]; then
            set_tmp_path input "$file" decoded.jpg
            if ! heif-convert -q 100 "$file" "$input" >/dev/null 2>&1; then
                rm -f -- "$input"
                printf 'photo|%s|%d|%d|fail\n' "$rel" "$sz_before" "$sz_before" >"$stats_file"
                return
            fi
        fi
    elif [[ "$ext" == png ]]; then
        if ((KEEP_PNG)) || has_transparency "$file"; then
            if ((!OPTIMIZE_PNG)); then
                printf 'photo|%s|%d|%d\n' "$rel" "$sz_before" "$sz_before" >"$stats_file"
                mark_done "$rel"
                return
            fi
            # Lossless: maximum zlib effort, no resize, metadata kept
            ops=(-quality 95 -define png:compression-level=9 -define "png:exclude-chunks=date,time")
        else
            new_ext=jpg
        fi
    fi
    set_tmp_path tmp "$file" "${new_ext:-$ext}"

    local converted=1
    run_convert "$input" "${ops[@]}" "$tmp" 2>/dev/null || converted=0
    if [[ "$input" != "$file" ]]; then
        rm -f -- "$input"
    fi
    if ((!converted)); then
        rm -f -- "$tmp"
        printf 'photo|%s|%d|%d|fail\n' "$rel" "$sz_before" "$sz_before" >"$stats_file"
        return
    fi

    sz_after=$(stat -c%s -- "$tmp")
    if ((sz_after == 0 || (sz_after >= sz_before && !keep_larger))); then
        rm -f -- "$tmp"
        printf 'photo|%s|%d|%d\n' "$rel" "$sz_before" "$sz_before" >"$stats_file"
        mark_done "$rel"
        return
    fi

    if ! out=$(install_result "$tmp" "$file" "$new_ext"); then
        rm -f -- "$tmp"
        printf 'photo|%s|%d|%d|fail\n' "$rel" "$sz_before" "$sz_before" >"$stats_file"
        return
    fi
    printf 'photo|%s|%d|%d\n' "$rel" "$sz_before" "$sz_after" >"$stats_file"
    mark_done "$rel" "${out#"$OPT_ROOT"/}"
}

# Re-encodes a video to H.264/AAC MP4 and keeps the result only if smaller; otherwise the
# original stays, also as MOV/VOB. Writes "video|rel|bytes_before|bytes_after[|fail]".
# Failed videos are not marked done, so --resume retries them.
convert_video() {
    local file="$1" rel="$2" stats_file="$3"
    local ext="${file##*.}" new_ext=""
    ext="${ext,,}"
    if [[ "$ext" != mp4 ]]; then
        new_ext=mp4
    fi

    local tmp
    set_tmp_path tmp "$file" mp4
    local scale="scale='if(gt(iw,${VIDEO_MAX_W}),${VIDEO_MAX_W},iw)':'if(gt(ih,${VIDEO_MAX_H}),${VIDEO_MAX_H},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    # Per-second progress would interleave when several videos run in parallel
    local stats_flag="-stats"
    if ((PARALLEL_JOBS > 1)); then
        stats_flag="-nostats"
    fi

    local sz_before sz_after out
    sz_before=$(stat -c%s -- "$file")

    if ffmpeg -nostdin -hide_banner -loglevel warning "$stats_flag" -y \
        -i "$file" -vf "$scale" \
        -c:v libx264 -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" \
        -level:v 5.2 -fps_mode vfr \
        -pix_fmt yuv420p \
        -map_metadata 0 -movflags +faststart+use_metadata_tags \
        -max_muxing_queue_size 4096 \
        -c:a aac -b:a "$AUDIO_BITRATE" "$tmp"; then
        sz_after=$(stat -c%s -- "$tmp")
        if ((sz_after > 0 && sz_after >= sz_before)); then
            rm -f -- "$tmp"
            printf 'video|%s|%d|%d\n' "$rel" "$sz_before" "$sz_before" >"$stats_file"
            mark_done "$rel"
            return
        fi
        if ((sz_after > 0)) && out=$(install_result "$tmp" "$file" "$new_ext"); then
            printf 'video|%s|%d|%d\n' "$rel" "$sz_before" "$sz_after" >"$stats_file"
            mark_done "$rel" "${out#"$OPT_ROOT"/}"
            return
        fi
    fi
    rm -f -- "$tmp"
    printf 'video|%s|%d|%d|fail\n' "$rel" "$sz_before" "$sz_before" >"$stats_file"
}

# ── Top-savings report ────────────────────────────────────────────────────────
print_top_savings() {
    local stats_dir="$1"
    local top=20
    local tmp_all
    tmp_all=$(mktemp)

    cat "$stats_dir"/*.result 2>/dev/null > "$tmp_all" || true
    if [[ ! -s "$tmp_all" ]]; then
        rm -f "$tmp_all"
        return
    fi

    echo
    echo "Top $top files by bytes saved:"
    local printed=0
    while IFS='|' read -r type rel before after rest; do
        if [[ "${rest:-}" == "skip" || "${rest:-}" == "fail" ]]; then
            continue
        fi
        local saved=$(( before - after ))
        if (( saved <= 0 )); then
            continue
        fi
        (( ++printed ))
        printf '  #%-3d [%-5s] %s\n        %s → %s  saved %s (%s)\n' \
            "$printed" "$type" "$rel" \
            "$(format_bytes "$before")" "$(format_bytes "$after")" \
            "$(format_bytes "$saved")" "$(format_percent "$before" "$after")"
        if (( printed >= top )); then
            break
        fi
    done < <(awk -F'|' '{saved=$3-$4; print saved"|"$0}' "$tmp_all" | sort -t'|' -k1,1nr | cut -d'|' -f2-)
    if (( printed == 0 )); then
        echo "  No files were reduced in size."
    fi
    rm -f "$tmp_all"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    local stats_dir="$1" elapsed="$2"
    local photo_ok=0 photo_before=0 photo_after=0 photo_fail=0
    local video_ok=0 video_before=0 video_after=0 video_fail=0

    while IFS='|' read -r type rel before after rest; do
        case "$type" in
            photo)
                case "${rest:-}" in
                    fail) (( ++photo_fail )) ;;
                    *) photo_before=$(( photo_before+before )); photo_after=$(( photo_after+after )); (( ++photo_ok )) ;;
                esac ;;
            video)
                case "${rest:-}" in
                    fail) (( ++video_fail )) ;;
                    *) video_before=$(( video_before+before )); video_after=$(( video_after+after )); (( ++video_ok )) ;;
                esac ;;
        esac
    done < <(cat "$stats_dir"/*.result 2>/dev/null || true)

    local total_before=$(( photo_before+video_before ))
    local total_after=$(( photo_after+video_after ))
    local total_fail=$(( photo_fail+video_fail ))

    echo
    echo "=== Optimization Summary ==="
    if (( photo_ok > 0 || photo_fail > 0 )); then
        printf '%-8s  %5d files  %12s → %12s  %s\n' \
            "Photos" "$photo_ok" "$(format_bytes "$photo_before")" "$(format_bytes "$photo_after")" "$(format_percent "$photo_before" "$photo_after")"
    fi
    if (( video_ok > 0 || video_fail > 0 )); then
        printf '%-8s  %5d files  %12s → %12s  %s\n' \
            "Videos" "$video_ok" "$(format_bytes "$video_before")" "$(format_bytes "$video_after")" "$(format_percent "$video_before" "$video_after")"
    fi
    echo "──────────────────────────────────────────────────────────────────"
    printf '%-8s  %5d files  %12s → %12s  %s\n' \
        "Total" "$(( photo_ok+video_ok ))" \
        "$(format_bytes "$total_before")" "$(format_bytes "$total_after")" \
        "$(format_percent "$total_before" "$total_after")"
    printf 'Elapsed : %s\n' "$(format_elapsed "$elapsed")"
    if (( total_fail > 0 )); then
        printf 'Failed  : %d file(s) — originals preserved in copy\n' "$total_fail" >&2
    fi
}

# ── Main optimizer (runs on the copy) ─────────────────────────────────────────
run_optimization() {
    local dest="$1"
    local idx

    local -a img_files=() img_sizes=() heic_files=() heic_sizes=()
    local -a video_primary=() video_primary_sizes=()
    local -a video_other=() video_other_sizes=()
    local -a skipped_vid=() skipped_vid_sizes=()
    OPT_ROOT="$dest"
    # Temp files of an interrupted run are never complete results
    find "$dest" -type f -name "${TMP_PREFIX}*" -delete
    collect_media_files "$dest"

    # Set up progress tracking for resume support
    PROGRESS_FILE="$dest/.optimize_progress"
    declare -A _done_files=()
    if (( RESUME )) && [[ -f "$PROGRESS_FILE" ]]; then
        local _line
        while IFS= read -r _line; do
            if [[ -n "$_line" ]]; then
                _done_files["$_line"]=1
            fi
        done < "$PROGRESS_FILE"
        printf 'Resuming: skipping %d already-processed files.\n' "${#_done_files[@]}"
        echo
    fi

    img_files+=("${heic_files[@]+"${heic_files[@]}"}")
    printf 'Found: %d photos, %d videos to process\n' \
        "${#img_files[@]}" "$(( ${#video_primary[@]} + ${#video_other[@]} ))"
    echo

    # Photos
    if (( ${#img_files[@]} > 0 )); then
        printf -- '--- Photos  (quality=%d, max=%dpx) ---\n' "$JPEG_QUALITY" "$IMG_MAX_DIM"
        idx=0
        for file in "${img_files[@]}"; do
            (( ++idx ))
            local rel="${file#"$dest"/}"
            if [[ -n "${_done_files[$rel]+x}" ]]; then
                printf '[%d/%d] [SKIP] %s\n' "$idx" "${#img_files[@]}" "$rel"
                continue
            fi
            printf '[%d/%d] %s\n' "$idx" "${#img_files[@]}" "$rel"
            local sf="$STATS_DIR/photo_${idx}.result"
            wait_for_slot
            local _f="$file" _r="$rel" _sf="$sf"
            { optimize_photo "$_f" "$_r" "$_sf"; } &
        done
        wait; echo
    fi

    # Videos
    local -a all_videos=("${video_primary[@]+"${video_primary[@]}"}" "${video_other[@]+"${video_other[@]}"}")
    if (( ${#all_videos[@]} > 0 )); then
        printf -- '--- Videos  (CRF=%d, preset=%s, max %dx%d, audio=%s) ---\n' \
            "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H" "$AUDIO_BITRATE"
        idx=0
        for file in "${all_videos[@]}"; do
            (( ++idx ))
            local rel="${file#"$dest"/}"
            if [[ -n "${_done_files[$rel]+x}" ]]; then
                printf '[%d/%d] [SKIP] %s\n' "$idx" "${#all_videos[@]}" "$rel"
                continue
            fi
            local sz; sz=$(stat -c%s -- "$file")
            printf '[%d/%d] %s  (%s)\n' "$idx" "${#all_videos[@]}" "$rel" "$(format_bytes "$sz")"
            local sf="$STATS_DIR/video_${idx}.result"
            wait_for_slot
            local _f="$file" _r="$rel" _sf="$sf"
            { convert_video "$_f" "$_r" "$_sf"; } &
        done
        wait; echo
    fi
}

# Size after removing ratio percent.
estimate_size() {
    awk -v s="$1" -v r="$2" 'BEGIN{ printf "%d\n", s * (1 - r / 100) }'
}

# ── Dry-run with estimated savings ────────────────────────────────────────────
run_dry_run() {
    local src="$1"
    echo "DRY RUN — no files will be copied or modified."
    echo "Savings estimates are approximate (typical values, actual depends on content)."
    echo

    local -a img_files=() img_sizes=() heic_files=() heic_sizes=()
    local -a video_primary=() video_primary_sizes=()
    local -a video_other=() video_other_sizes=()
    local -a skipped_vid=() skipped_vid_sizes=()
    collect_media_files "$src" 1
    echo

    # Estimated savings ratios (%) by level.
    local img_ratio vid_ratio other_ratio
    case "$LEVEL" in
        archive)    img_ratio=-5;  vid_ratio=15; other_ratio=0  ;;
        moderate)   img_ratio=12;  vid_ratio=30; other_ratio=0  ;;
        aggressive) img_ratio=22;  vid_ratio=50; other_ratio=35 ;;
        maximum)    img_ratio=35;  vid_ratio=65; other_ratio=55 ;;
    esac

    # Sum sizes from arrays collected during scan — no stat calls needed
    local img_sz=0 vid_sz=0 other_sz=0 skipped_sz=0 heic_sz=0
    local _s
    for _s in "${img_sizes[@]+"${img_sizes[@]}"}";            do (( img_sz     += _s )); done
    for _s in "${video_primary_sizes[@]+"${video_primary_sizes[@]}"}"; do (( vid_sz += _s )); done
    for _s in "${video_other_sizes[@]+"${video_other_sizes[@]}"}";  do (( other_sz  += _s )); done
    for _s in "${skipped_vid_sizes[@]+"${skipped_vid_sizes[@]}"}";  do (( skipped_sz += _s )); done
    for _s in "${heic_sizes[@]+"${heic_sizes[@]}"}"; do ((heic_sz += _s)); done

    local img_est vid_est other_est
    img_est=$(estimate_size "$img_sz" "$img_ratio")
    vid_est=$(estimate_size "$vid_sz" "$vid_ratio")
    other_est=$(estimate_size "$other_sz" "$other_ratio")
    # JPEG needs about 1.5x the bytes of HEIC at similar quality
    local heic_est
    heic_est=$(estimate_size "$heic_sz" -50)

    local total_before=$((img_sz + vid_sz + other_sz + heic_sz))
    local total_after=$((img_est + vid_est + other_est + heic_est))

    printf 'Level       : %s\n' "$LEVEL"
    if [[ -n "$FILTER_EXTS" ]]; then
        printf 'Only exts   : %s\n' "$FILTER_EXTS"
    fi
    if [[ -n "$SKIP_EXTS"   ]]; then
        printf 'Skip exts   : %s\n' "$SKIP_EXTS"
    fi
    echo
    printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
        "Photos" "${#img_files[@]}" \
        "$(format_bytes "$img_sz")" "$(format_bytes "$img_est")" \
        "$(format_percent "$img_sz" "$img_est")"
    if ((${#heic_files[@]} > 0)); then
        printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
            "HEIC→JPEG" "${#heic_files[@]}" \
            "$(format_bytes "$heic_sz")" "$(format_bytes "$heic_est")" \
            "$(format_percent "$heic_sz" "$heic_est")"
    fi
    printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
        "MOV/VOB→MP4" "${#video_primary[@]}" \
        "$(format_bytes "$vid_sz")" "$(format_bytes "$vid_est")" \
        "$(format_percent "$vid_sz" "$vid_est")"
    if (( REENCODE_ALL_VIDEO && other_sz > 0 )); then
        printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
            "MP4/MKV" "${#video_other[@]}" \
            "$(format_bytes "$other_sz")" "$(format_bytes "$other_est")" \
            "$(format_percent "$other_sz" "$other_est")"
    fi
    echo "──────────────────────────────────────────────────────────────────"
    printf '%-10s  %5s files  %12s → %12s  ~%s\n' \
        "Total" "$((${#img_files[@]} + ${#heic_files[@]} + ${#video_primary[@]} + ${#video_other[@]}))" \
        "$(format_bytes "$total_before")" "$(format_bytes "$total_after")" \
        "$(format_percent "$total_before" "$total_after")"

    if (( ${#skipped_vid[@]} > 0 )); then
        echo
        printf 'Skipped (not re-encoded at this level): %d MP4/MKV/AVI  ~%s\n' \
            "${#skipped_vid[@]}" "$(format_bytes "$skipped_sz")"
        printf '  → use --level aggressive or maximum to include them\n'
    fi
}

# ── Duplicate management ──────────────────────────────────────────────────────
run_copy_dupes() {
    local target="$1" dest="$2"
    local tmp_dupes; tmp_dupes=$(mktemp)
    printf 'Scanning for duplicates in %s ...\n' "$target"
    find_duplicates "$target" "$tmp_dupes"

    local stats_line groups dup_count dup_bytes
    stats_line=$(head -1 "$tmp_dupes")
    IFS=$'\t' read -r _ groups dup_count dup_bytes <<< "$stats_line"

    if [[ -z "$groups" || "$groups" == "0" ]]; then
        rm -f "$tmp_dupes"
        echo "No duplicate files found."
        return
    fi

    printf 'Found: %d groups, %d redundant files (%s)\n' \
        "$groups" "$dup_count" "$(format_bytes "$dup_bytes")"
    echo

    if [[ -e "$dest" ]]; then
        fail "Destination '$dest' already exists. Remove it first."
    fi
    mkdir -p "$dest"

    local copied=0
    local target_abs; target_abs=$(abs_path "$target")
    while IFS= read -r path; do
        if [[ -z "$path" ]]; then
            continue
        fi
        local rel="${path#"$target_abs"/}"
        local dst_path="$dest/$rel"
        mkdir -p "$(dirname "$dst_path")"
        cp -p -- "$path" "$dst_path"
        printf '  [copy]  %s\n' "$rel"
        (( ++copied ))
    done < <(tail -n +2 "$tmp_dupes")

    rm -f "$tmp_dupes"
    echo
    printf 'Copied %d redundant files to: %s\n' "$copied" "$dest"
    echo "Review them manually, then use --delete-dupes to remove from the original."
}

run_delete_dupes() {
    local target="$1"
    local tmp_dupes; tmp_dupes=$(mktemp)
    printf 'Scanning for duplicates in %s ...\n' "$target"
    find_duplicates "$target" "$tmp_dupes"

    local stats_line groups dup_count dup_bytes
    stats_line=$(head -1 "$tmp_dupes")
    IFS=$'\t' read -r _ groups dup_count dup_bytes <<< "$stats_line"

    if [[ -z "$groups" || "$groups" == "0" ]]; then
        rm -f "$tmp_dupes"
        echo "No duplicate files found."
        return
    fi

    printf 'Found: %d groups, %d redundant files (%s)\n' \
        "$groups" "$dup_count" "$(format_bytes "$dup_bytes")"
    echo "Files to be deleted:"
    local target_abs; target_abs=$(abs_path "$target")
    while IFS= read -r path; do
        if [[ -z "$path" ]]; then
            continue
        fi
        local sz; sz=$(stat -c%s -- "$path" 2>/dev/null || echo 0)
        printf '  [del]  %s  (%s)\n' "${path#"$target_abs"/}" "$(format_bytes "$sz")"
    done < <(tail -n +2 "$tmp_dupes")

    echo
    if ! confirm "Delete $dup_count files and free $(format_bytes "$dup_bytes")?"; then
        rm -f "$tmp_dupes"
        echo "Aborted."
        return
    fi

    local deleted=0
    while IFS= read -r path; do
        if [[ -z "$path" ]]; then
            continue
        fi
        rm -f -- "$path"
        (( ++deleted ))
    done < <(tail -n +2 "$tmp_dupes")

    rm -f "$tmp_dupes"
    echo
    printf 'Deleted %d files, freed %s.\n' "$deleted" "$(format_bytes "$dup_bytes")"
}

# ── main ──────────────────────────────────────────────────────────────────────
optimize_main() {
    local level="moderate"
    local dry_run=0
    local skip_copy=0
    local resume=0
    local log_file=""
    local positional=()
    local ov_jpeg_quality="" ov_img_max_dim=""
    local ov_crf="" ov_preset="" ov_max_w="" ov_max_h="" ov_audio=""
    local ov_min_photo_mb="" ov_min_video_mb=""
    local copy_dupes_dir="" delete_dupes=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)           optimize_usage; exit 0 ;;
            --dry-run)           dry_run=1; shift ;;
            --skip-copy)         skip_copy=1; shift ;;
            --resume)            resume=1; shift ;;
            --copy-dupes)        [[ $# -ge 2 ]] || fail "--copy-dupes requires a directory"; copy_dupes_dir="$2"; shift 2 ;;
            --copy-dupes=*)      copy_dupes_dir="${1#--copy-dupes=}"; shift ;;
            --delete-dupes)      delete_dupes=1; shift ;;
            -y|--yes)            assume_yes; shift ;;
            --keep-png)          KEEP_PNG=1; shift ;;
            --heic-to-jpeg)      HEIC_TO_JPEG=1; shift ;;
            --optimize-png)      OPTIMIZE_PNG=1; shift ;;
            --level)             [[ $# -ge 2 ]] || fail "--level requires a value"; level="$2"; shift 2 ;;
            --level=*)           level="${1#--level=}"; shift ;;
            --only-exts)         [[ $# -ge 2 ]] || fail "--only-exts requires a value"; FILTER_EXTS="$2"; shift 2 ;;
            --only-exts=*)       FILTER_EXTS="${1#--only-exts=}"; shift ;;
            --skip-exts)         [[ $# -ge 2 ]] || fail "--skip-exts requires a value"; SKIP_EXTS="$2"; shift 2 ;;
            --skip-exts=*)       SKIP_EXTS="${1#--skip-exts=}"; shift ;;
            --jobs)              [[ $# -ge 2 ]] || fail "--jobs requires a value"; PARALLEL_JOBS="$2"; shift 2 ;;
            --jobs=*)            PARALLEL_JOBS="${1#--jobs=}"; shift ;;
            --log)               [[ $# -ge 2 ]] || fail "--log requires a value"; log_file="$2"; shift 2 ;;
            --log=*)             log_file="${1#--log=}"; shift ;;
            --jpeg-quality)      [[ $# -ge 2 ]] || fail "--jpeg-quality requires a value"; ov_jpeg_quality="$2"; shift 2 ;;
            --jpeg-quality=*)    ov_jpeg_quality="${1#--jpeg-quality=}"; shift ;;
            --max-image-dim)     [[ $# -ge 2 ]] || fail "--max-image-dim requires a value"; ov_img_max_dim="$2"; shift 2 ;;
            --max-image-dim=*)   ov_img_max_dim="${1#--max-image-dim=}"; shift ;;
            --crf)               [[ $# -ge 2 ]] || fail "--crf requires a value"; ov_crf="$2"; shift 2 ;;
            --crf=*)             ov_crf="${1#--crf=}"; shift ;;
            --preset)            [[ $# -ge 2 ]] || fail "--preset requires a value"; ov_preset="$2"; shift 2 ;;
            --preset=*)          ov_preset="${1#--preset=}"; shift ;;
            --max-width)         [[ $# -ge 2 ]] || fail "--max-width requires a value"; ov_max_w="$2"; shift 2 ;;
            --max-width=*)       ov_max_w="${1#--max-width=}"; shift ;;
            --max-height)        [[ $# -ge 2 ]] || fail "--max-height requires a value"; ov_max_h="$2"; shift 2 ;;
            --max-height=*)      ov_max_h="${1#--max-height=}"; shift ;;
            --audio-bitrate)     [[ $# -ge 2 ]] || fail "--audio-bitrate requires a value"; ov_audio="$2"; shift 2 ;;
            --audio-bitrate=*)   ov_audio="${1#--audio-bitrate=}"; shift ;;
            --min-photo-mb)      [[ $# -ge 2 ]] || fail "--min-photo-mb requires a value"; ov_min_photo_mb="$2"; shift 2 ;;
            --min-photo-mb=*)    ov_min_photo_mb="${1#--min-photo-mb=}"; shift ;;
            --min-video-mb)      [[ $# -ge 2 ]] || fail "--min-video-mb requires a value"; ov_min_video_mb="$2"; shift 2 ;;
            --min-video-mb=*)    ov_min_video_mb="${1#--min-video-mb=}"; shift ;;
            --)                  shift; positional+=("$@"); break ;;
            -*)                  fail "Unknown option: $1" ;;
            *)                   positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -ge 1 ]] || { optimize_usage >&2; exit 1; }

    # ── Duplicate management mode (mutually exclusive with optimization) ────────
    if [[ -n "$copy_dupes_dir" || "$delete_dupes" -eq 1 ]]; then
        local target_abs; target_abs=$(abs_path "${positional[0]}")
        [[ -d "$target_abs" ]] || fail "Directory '$target_abs' does not exist"
        if [[ -n "$log_file" ]]; then
            exec > >(tee -a "$log_file") 2>&1
            echo "Logging to: $log_file"
        fi
        echo "============================================"
        printf 'Directory : %s\n' "$target_abs"
        echo "============================================"
        echo
        if [[ -n "$copy_dupes_dir" ]]; then
            local dupes_abs; dupes_abs=$(abs_path "$copy_dupes_dir")
            run_copy_dupes "$target_abs" "$dupes_abs"
            echo
        fi
        if (( delete_dupes )); then
            run_delete_dupes "$target_abs"
        fi
        exit 0
    fi

    if [[ -n "$FILTER_EXTS" && -n "$SKIP_EXTS" ]]; then
        fail "--only-exts and --skip-exts are mutually exclusive"
    fi
    case "$level" in
        archive|moderate|aggressive|maximum) ;;
        *) fail "--level must be: archive, moderate, aggressive, or maximum" ;;
    esac
    if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || ((PARALLEL_JOBS < 1)); then
        fail "--jobs must be a positive integer"
    fi

    # Apply level preset
    LEVEL="$level"
    case "$level" in
        archive)
            JPEG_QUALITY=$ARC_JPEG_QUALITY  IMG_MAX_DIM=$ARC_IMG_MAX_DIM
            VIDEO_CRF=$ARC_VIDEO_CRF        VIDEO_PRESET=$ARC_VIDEO_PRESET
            VIDEO_MAX_W=$ARC_VIDEO_MAX_W    VIDEO_MAX_H=$ARC_VIDEO_MAX_H
            AUDIO_BITRATE=$ARC_AUDIO_BITRATE REENCODE_ALL_VIDEO=$ARC_REENCODE_ALL_VIDEO ;;
        moderate)
            JPEG_QUALITY=$MOD_JPEG_QUALITY  IMG_MAX_DIM=$MOD_IMG_MAX_DIM
            VIDEO_CRF=$MOD_VIDEO_CRF        VIDEO_PRESET=$MOD_VIDEO_PRESET
            VIDEO_MAX_W=$MOD_VIDEO_MAX_W    VIDEO_MAX_H=$MOD_VIDEO_MAX_H
            AUDIO_BITRATE=$MOD_AUDIO_BITRATE REENCODE_ALL_VIDEO=$MOD_REENCODE_ALL_VIDEO ;;
        aggressive)
            JPEG_QUALITY=$AGG_JPEG_QUALITY  IMG_MAX_DIM=$AGG_IMG_MAX_DIM
            VIDEO_CRF=$AGG_VIDEO_CRF        VIDEO_PRESET=$AGG_VIDEO_PRESET
            VIDEO_MAX_W=$AGG_VIDEO_MAX_W    VIDEO_MAX_H=$AGG_VIDEO_MAX_H
            AUDIO_BITRATE=$AGG_AUDIO_BITRATE REENCODE_ALL_VIDEO=$AGG_REENCODE_ALL_VIDEO ;;
        maximum)
            JPEG_QUALITY=$MAX_JPEG_QUALITY  IMG_MAX_DIM=$MAX_IMG_MAX_DIM
            VIDEO_CRF=$MAX_VIDEO_CRF        VIDEO_PRESET=$MAX_VIDEO_PRESET
            VIDEO_MAX_W=$MAX_VIDEO_MAX_W    VIDEO_MAX_H=$MAX_VIDEO_MAX_H
            AUDIO_BITRATE=$MAX_AUDIO_BITRATE REENCODE_ALL_VIDEO=$MAX_REENCODE_ALL_VIDEO ;;
    esac

    # Apply individual overrides
    if [[ -n "$ov_jpeg_quality" ]]; then
        JPEG_QUALITY="$ov_jpeg_quality"
    fi
    if [[ -n "$ov_img_max_dim"  ]]; then
        IMG_MAX_DIM="$ov_img_max_dim"
    fi
    if [[ -n "$ov_crf"          ]]; then
        VIDEO_CRF="$ov_crf"
    fi
    if [[ -n "$ov_preset"       ]]; then
        VIDEO_PRESET="$ov_preset"
    fi
    if [[ -n "$ov_max_w"        ]]; then
        VIDEO_MAX_W="$ov_max_w"
    fi
    if [[ -n "$ov_max_h"        ]]; then
        VIDEO_MAX_H="$ov_max_h"
    fi
    if [[ -n "$ov_audio"        ]]; then
        AUDIO_BITRATE="$ov_audio"
    fi
    if [[ -n "$ov_min_photo_mb" ]]; then
        [[ "$ov_min_photo_mb" =~ ^[0-9]+$ ]] || fail "--min-photo-mb must be an integer"
        MIN_PHOTO_BYTES=$(( ov_min_photo_mb * 1024 * 1024 ))
    fi
    if [[ -n "$ov_min_video_mb" ]]; then
        [[ "$ov_min_video_mb" =~ ^[0-9]+$ ]] || fail "--min-video-mb must be an integer"
        MIN_VIDEO_BYTES=$(( ov_min_video_mb * 1024 * 1024 ))
    fi

    # Validate
    [[ "$JPEG_QUALITY"    =~ ^[0-9]+$ ]] || fail "--jpeg-quality must be an integer"
    [[ "$IMG_MAX_DIM"     =~ ^[0-9]+$ ]] || fail "--max-image-dim must be an integer"
    [[ "$VIDEO_CRF"       =~ ^[0-9]+$ ]] || fail "--crf must be an integer"
    [[ "$VIDEO_MAX_W"     =~ ^[0-9]+$ ]] || fail "--max-width must be an integer"
    [[ "$VIDEO_MAX_H"     =~ ^[0-9]+$ ]] || fail "--max-height must be an integer"
    [[ "$AUDIO_BITRATE"   =~ ^[0-9]+[kKmM]?$ ]] || fail "--audio-bitrate must be like 192k"
    case "$VIDEO_PRESET" in
        ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
        *) fail "--preset must be: ultrafast superfast veryfast faster fast medium slow slower veryslow" ;;
    esac

    # --resume implies --skip-copy
    if (( resume )); then
        skip_copy=1
    fi
    RESUME="$resume"

    local source_dir dest_dir
    if (( skip_copy )) && [[ ${#positional[@]} -eq 1 ]]; then
        # --skip-copy with one arg: that arg IS the directory to optimize in-place
        source_dir="${positional[0]}"
        dest_dir="${positional[0]}"
    else
        source_dir="${positional[0]}"
        dest_dir="${positional[1]:-}"
        if [[ -z "$dest_dir" ]]; then
            dest_dir="${source_dir%/}_${level}"
        fi
    fi
    [[ -d "$source_dir" ]] || fail "Source directory '$source_dir' does not exist"

    if [[ -n "$log_file" ]]; then
        exec > >(tee -a "$log_file") 2>&1
        echo "Logging to: $log_file"
    fi

    local src_abs dest_abs
    src_abs="$(abs_path "$source_dir")"
    dest_abs="$(abs_path "$dest_dir")"

    if [[ -f "$dest_abs/.optimize_progress" ]] && (( ! resume )); then
        echo "Warning: '$dest_abs/.optimize_progress' found — a previous run may have been interrupted."
        echo "         Run with --resume to continue from where it stopped."
        echo
    fi

    if (( ! skip_copy )); then
        require_command rsync
        if [[ -e "$dest_abs"              ]]; then
            fail "Destination '$dest_abs' already exists. Delete it or use --skip-copy."
        fi
        if [[ "$dest_abs" == "$src_abs"   ]]; then
            fail "Destination must differ from source."
        fi
        if [[ "$dest_abs" == "$src_abs"/* ]]; then
            fail "Destination may not be inside source."
        fi
        if [[ "$src_abs"  == "$dest_abs"/* ]]; then
            fail "Source may not be inside destination."
        fi
    else
        [[ -d "$dest_abs" ]] || fail "--skip-copy: destination '$dest_abs' does not exist"
    fi

    echo "============================================"
    if (( skip_copy )); then
        printf 'Directory   : %s\n' "$dest_abs"
    else
        printf 'Source      : %s\n' "$src_abs"
        printf 'Destination : %s\n' "$dest_abs"
    fi
    printf 'Level       : %s\n' "$level"
    if [[ -n "$FILTER_EXTS" ]]; then
        printf 'Only exts   : %s\n' "$FILTER_EXTS"
    fi
    if [[ -n "$SKIP_EXTS"   ]]; then
        printf 'Skip exts   : %s\n' "$SKIP_EXTS"
    fi
    if (( MIN_PHOTO_BYTES > 0 )); then
        printf 'Min photo   : %d MB (skip smaller)\n' "$(( MIN_PHOTO_BYTES / 1024 / 1024 ))"
    fi
    if (( MIN_VIDEO_BYTES > 0 )); then
        printf 'Min video   : %d MB (skip smaller)\n' "$(( MIN_VIDEO_BYTES / 1024 / 1024 ))"
    fi
    printf 'Settings    : JPEG/PNG %d  max-dim %dpx  CRF %d  preset %s  %dx%d  audio %s\n' \
        "$JPEG_QUALITY" "$IMG_MAX_DIM" \
        "$VIDEO_CRF" "$VIDEO_PRESET" "$VIDEO_MAX_W" "$VIDEO_MAX_H" "$AUDIO_BITRATE"
    echo "============================================"
    echo

    if [[ "$dry_run" -eq 1 ]]; then
        run_dry_run "$src_abs"
        exit 0
    fi

    if (( ! skip_copy )); then
        check_free_space "$src_abs" "$(dirname "$dest_abs")" "$level"
    fi
    init_image_tool
    if ((HEIC_TO_JPEG)); then
        init_heic_decoder
    fi
    require_command ffmpeg

    STATS_DIR=$(mktemp -d)
    local START_TIME=$SECONDS

    if (( ! skip_copy )); then
        echo "Step 1/2: Copying '$src_abs' → '$dest_abs' ..."
        mkdir -p "$dest_abs"
        rsync -a --info=progress2 --human-readable "$src_abs"/ "$dest_abs"/
        echo
        echo "Step 2/2: Optimizing copy ..."
    else
        echo "Skipping copy (--skip-copy). Optimizing '$dest_abs' in place ..."
    fi
    echo
    run_optimization "$dest_abs"

    local elapsed=$(( SECONDS - START_TIME ))
    print_summary "$STATS_DIR" "$elapsed"
    print_top_savings "$STATS_DIR"

    # Remove progress file — all files processed successfully
    if [[ -n "$PROGRESS_FILE" && -f "$PROGRESS_FILE" ]]; then
        rm -f "$PROGRESS_FILE"
    fi

    echo
    echo "Done."
    echo "  Optimized copy : $dest_abs"
    if (( ! skip_copy )); then
        echo "  Original       : $src_abs  (untouched)"
    fi

    # Final folder statistics
    local stats_script="$MOT_LIB/../bin/mot"
    if [[ -x "$stats_script" ]]; then
        if (( ! skip_copy )); then
            echo
            echo "============================================"
            echo "Folder stats: original"
            echo "============================================"
            "$stats_script" stats "$src_abs"
            echo
            echo "============================================"
            echo "Folder stats: optimized copy"
            echo "============================================"
            "$stats_script" stats "$dest_abs"
        else
            echo
            echo "============================================"
            echo "Folder stats"
            echo "============================================"
            "$stats_script" stats "$dest_abs"
        fi
    fi
}

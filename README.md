# Media Optimize Tools

Bash tools for shrinking personal photo and video archives safely: analyse disk usage, create an optimized copy, and
find duplicate files.

## Context

A personal utility project built between December 2025 and April 2026 to reduce the size of large family photo and
video archives (for example phone backups on a USB drive) without risking the originals. It grew from separate
conversion scripts into one entry point with optimization presets, dry-run estimates, resumable runs, size filters,
duplicate detection and per-folder statistics.

## Features

- **Non-destructive optimization**: rsync copy of the source folder, only the copy is changed; the destination is
  named `SOURCE_DIR_<level>` unless given explicitly
- **Formats**:
  - MOV and VOB are always converted to MP4 (H.264 + AAC)
  - JPEG and WEBP are recompressed with EXIF preserved (date, GPS, camera)
  - PNG is converted to JPEG with EXIF preserved
  - MP4, MKV and AVI are re-encoded at the `moderate`, `aggressive` and `maximum` levels
- **Presets**:

  |                  | `archive`       | `moderate` (default) | `aggressive`            | `maximum`              |
  |------------------|-----------------|----------------------|-------------------------|------------------------|
  | JPEG/PNG quality | 95              | 88                   | 80                      | 70                     |
  | Max photo size   | no limit        | 8000px               | 3840px                  | 2560px                 |
  | MOV/VOB to MP4   | CRF 20, 4K slow | CRF 25, 4K           | CRF 28, 1080p           | CRF 32, 720p           |
  | MP4/MKV/AVI      | skip            | re-encode CRF 25, 4K | re-encode CRF 28, 1080p | re-encode CRF 32, 720p |

- Quality overrides on top of a preset: JPEG quality, max image dimension, CRF, ffmpeg preset, max video size, audio
  bitrate
- `--dry-run` estimate of savings per file type, without changes
- `--resume` after an interruption (progress is tracked in `.optimize_progress` in the destination)
- `--skip-copy` to re-optimize an existing copy, `--min-photo-mb` / `--min-video-mb` to touch only large files
- `--only-exts` / `--skip-exts` to limit file types, `--jobs N` for parallel workers, `--log FILE`
- Statistics for the original and the optimized copy are printed automatically after a run, plus elapsed time
- **Disk statistics** (`stats`): folder sizes, largest files, files that need compression, per-subdirectory summary
- **Duplicates**: detection by content (size first, then MD5), report only (`stats --dupes`), copy redundant files for
  review (`optimize --copy-dupes DIR`) or delete them after a `[y/N]` confirmation (`optimize --delete-dupes`); the
  alphabetically first file of each group is kept

## Tech stack

- Bash
- rsync, ImageMagick, ffmpeg
- Python 3 (dry-run estimates and duplicate detection)

## Architecture

- `run.sh`: single entry point that dispatches `optimize` and `stats` to the scripts below
- `personal/media_optimize.sh`: copy + optimize, presets, overrides, resume, duplicate management
- `statistics/folder_stats.sh`: read-only disk statistics and duplicate report; defaults can be overridden with
  `FOLDER_STATS_DEPTH`, `FOLDER_STATS_TOP_FILES`, `FOLDER_STATS_PHOTO_MB`, `FOLDER_STATS_VIDEO_MB`

Key decision: the original archive is never modified by optimization; deleting originals is left as a manual step
after verifying the copy.

## Getting started

Install the dependencies (Debian/Ubuntu):

```bash
sudo apt install rsync python3 imagemagick ffmpeg
```

`ffmpeg` is only needed for video files. Run `./run.sh --help` or `./run.sh <command> --help` for all options.

Typical workflow:

```bash
# 1. See what takes space and what needs compression
./run.sh stats /media/usb/Photos

# 2. Preview savings
./run.sh optimize --dry-run --level aggressive /media/usb/Photos

# 3. Create the optimized copy (/media/usb/Photos_aggressive), stats comparison is printed at the end
./run.sh optimize --level aggressive /media/usb/Photos

# 4. Re-compress only files that are still large
./run.sh optimize --skip-copy --level aggressive \
    --min-photo-mb 4 --min-video-mb 80 /media/usb/Photos_aggressive
```

More examples:

```bash
# Only convert MOV, keep everything else
./run.sh optimize --only-exts mov --level aggressive /media/usb/Photos

# Convert DVD VOB files at near-lossless quality
./run.sh optimize --level archive --only-exts vob /media/usb/DVD_backup

# Continue an interrupted run (use the same level as before)
./run.sh optimize --resume --level aggressive /media/usb/Photos_aggressive

# Fine-tune a preset, run in parallel and log to a file
./run.sh optimize --level moderate --crf 22 --preset slow --jobs 4 --log ./optimize.log /media/usb/Photos

# Statistics with deeper breakdown and per-subdirectory summary
./run.sh stats --depth 3 --top-files 100 /media/usb/Photos
./run.sh stats --subdirs /media/usb/Photos

# Duplicates: report, copy for review, then delete from the original
./run.sh stats --dupes /media/usb/Photos
./run.sh optimize --copy-dupes /tmp/dupes_review /media/usb/Photos
./run.sh optimize --delete-dupes /media/usb/Photos
```

Before deleting originals, compare file counts (PNG files become JPEG), open some photos and videos, check that EXIF
dates are preserved, and keep the copy on a different drive or in a backup.

## Testing

There are no automated tests.

## Status

Working personal tool, last changes in April 2026.

## License

MIT, see [LICENSE](LICENSE).

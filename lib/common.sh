# shellcheck shell=bash
# Helpers shared by all subcommands. Sourced by bin/mot.

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found in PATH"
}

abs_path() { realpath -m "$1"; }

format_bytes() {
    awk -v v="$1" 'BEGIN{
        s = (v < 0) ? "-" : ""; v = (v < 0) ? -v : v
        u = "B"
        if (v >= 1024) { v /= 1024; u = "KB" }
        if (v >= 1024) { v /= 1024; u = "MB" }
        if (v >= 1024) { v /= 1024; u = "GB" }
        if (v >= 1024) { v /= 1024; u = "TB" }
        if (u == "B") printf "%s%d %s\n", s, v, u
        else          printf "%s%.1f %s\n", s, v, u
    }'
}

# Savings in percent: positive when the file got smaller.
format_percent() {
    local before="$1" after="$2"
    if ((before == 0)); then
        echo "n/a"
        return
    fi
    awk -v b="$before" -v a="$after" 'BEGIN{ printf "%+.1f%%\n", (b-a)/b*100 }'
}

format_elapsed() {
    local s="$1"
    local h=$((s / 3600)) m=$(((s % 3600) / 60)) sec=$((s % 60))
    if ((h > 0)); then
        printf '%dh %dm %ds' "$h" "$m" "$sec"
    elif ((m > 0)); then
        printf '%dm %ds' "$m" "$sec"
    else
        printf '%ds' "$sec"
    fi
}

# Prints the duplicate report of find_dupes.py into the file $2.
find_duplicates() {
    local target="$1" out_file="$2"
    require_command python3
    python3 "$MOT_LIB/find_dupes.py" "$target" >"$out_file"
}

MOT_ASSUME_YES=0
assume_yes() { MOT_ASSUME_YES=1; }

# Reads a yes/no answer from the terminal; anything but y/Y (or no terminal) means no.
confirm() {
    local prompt="$1" reply=""
    if ((MOT_ASSUME_YES)); then
        return 0
    fi
    printf '%s [y/N] ' "$prompt" >&2
    { read -r reply </dev/tty; } 2>/dev/null || reply=n
    [[ "$reply" =~ ^[Yy]$ ]]
}

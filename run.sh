#!/usr/bin/env bash
# Kept for existing scripts and habits; bin/mot is the entry point.
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bin/mot" "$@"

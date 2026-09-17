#!/usr/bin/env bash
# Downloads the time series data (too large for GitHub / Git LFS on this fork) from the
# Google Drive folder linked in the README. Requires `gdown` (pip install gdown).
set -euo pipefail

DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v gdown &> /dev/null; then
    echo "gdown is required: pip install gdown" >&2
    exit 1
fi

# name:drive_id -- a plain list, not `declare -A`, so this runs on macOS's bash 3.2.
for entry in \
    "HourlyProduction2019.csv:1CxLlcwAEUy-JvJQdAfVydJ1p9Ecot-4d" \
    "Load_Agg_Post_Assignment_v3_latest.csv:1Sz8st7g4Us6oijy1UYMPUvkA1XeZlIr8"
do
    name="${entry%%:*}"
    id="${entry##*:}"
    dest="$DATA_DIR/$name"
    if [[ -f "$dest" ]]; then
        echo "$name already present, skipping (delete it first to re-download)"
        continue
    fi
    gdown "$id" -O "$dest"
done

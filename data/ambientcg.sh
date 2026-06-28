#!/usr/bin/env bash
#
# ambientcg.sh — download CC0 PBR material assets from ambientCG.
#
# Usage:
#   ./ambientcg.sh Grass005            download Grass005 at 1K JPG
#   ./ambientcg.sh Grass005 2K         download Grass005 at 2K JPG
#   ./ambientcg.sh Grass005 1K PNG     download Grass005 at 1K PNG
#   ./ambientcg.sh Bricks023 4K        download Bricks023 at 4K JPG
#
# Asset and resolution names are as shown on https://ambientcg.com.
# Files are written under ./ambientcg and skipped if they already exist.
# Each zip is unpacked into ./ambientcg/<asset>_<res>-<fmt>/.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="https://ambientcg.com/get?file="
OUT="$DIR/ambientcg"

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# fetch URL DEST — download only if DEST is missing.
fetch() {
  local url="$1" dest="$2"
  if [ -e "$dest" ]; then
    echo "skip  $(basename "$dest") (exists)"
    return 0
  fi
  echo "get   $(basename "$dest")"
  if ! curl -fL --progress-bar -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    echo "fail  $url" >&2
    return 1
  fi
  mv "$dest.part" "$dest"
}

# grab ASSET RES FMT — download <asset>_<res>-<fmt>.zip and unpack it.
grab() {
  local asset="$1" res="$2" fmt="$3"
  local name="${asset}_${res}-${fmt}.zip"
  local zip="$OUT/$name"
  local into="$OUT/${asset}_${res}-${fmt}"
  mkdir -p "$OUT"
  fetch "$BASE$name" "$zip" || return 1
  echo "unzip $name"
  unzip -oq "$zip" -d "$into"
}

[ $# -ge 1 ] || usage 1

case "$1" in
  -h|--help) usage 0 ;;
esac

ASSET="$1"
RES="${2:-1K}"
FMT="${3:-JPG}"
grab "$ASSET" "$RES" "$FMT"

#!/usr/bin/env bash
#
# geonames.sh — download GeoNames geographical datasets.
#
# Usage:
#   ./geonames.sh -meta              download support files (countryInfo, codes, readme)
#   ./geonames.sh -export NL         download a country place dump (dump/NL.zip)
#   ./geonames.sh -export allCountries   download the whole-planet dump
#   ./geonames.sh -postal NL         download a country's postal codes (zip/NL.zip)
#   ./geonames.sh -postal NL_full    download full postal codes (zip/NL_full.csv.zip)
#
# Files are written next to this script and skipped if they already exist.
# Zip archives are unpacked into ./dump and ./postal.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="https://download.geonames.org/export"
DUMP="$DIR/dump"
POSTAL="$DIR/postal"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# grab URL DIR — fetch into DIR, unzipping archives in place.
grab() {
  local url="$1" into="$2" name
  name="$(basename "$url")"
  mkdir -p "$into"
  fetch "$url" "$into/$name" || return 1
  case "$name" in
    *.zip) echo "unzip $name"; unzip -oq "$into/$name" -d "$into" ;;
  esac
}

meta() {
  mkdir -p "$DUMP"
  local f
  for f in readme.txt countryInfo.txt featureCodes_en.txt \
           admin1CodesASCII.txt admin2Codes.txt timeZones.txt; do
    fetch "$BASE/dump/$f" "$DUMP/$f"
  done
}

# export NAME — place dump for a country code (NL) or allCountries.
export_dump() {
  grab "$BASE/dump/$1.zip" "$DUMP"
}

# postal NAME — postal codes; NAME ending in _full uses the .csv.zip variant.
postal() {
  case "$1" in
    *_full) grab "$BASE/zip/$1.csv.zip" "$POSTAL" ;;
    *)      grab "$BASE/zip/$1.zip"     "$POSTAL" ;;
  esac
}

[ $# -eq 0 ] && usage 1

case "$1" in
  -meta) meta ;;
  -export)
    [ $# -ge 2 ] || { echo "-export needs a country code" >&2; usage 1; }
    export_dump "$2" ;;
  -postal)
    [ $# -ge 2 ] || { echo "-postal needs a name" >&2; usage 1; }
    postal "$2" ;;
  -h|--help) usage 0 ;;
  *) echo "unknown option: $1" >&2; usage 1 ;;
esac

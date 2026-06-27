#!/usr/bin/env bash
#
# taxi.sh — download the NYC TLC taxi dataset.
#
# Usage:
#   ./taxi.sh -meta              download zone lookup CSV + taxi zone map
#   ./taxi.sh -trip 2026         download all months of a year
#   ./taxi.sh -trip 2026-03      download a single month
#   ./taxi.sh -trip 2024 green   pick the cab type (yellow|green|fhv|fhvhv)
#
# Files are written next to this script and skipped if they already exist.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="https://d37ci6vzurychx.cloudfront.net"
TRIPS="$DIR/trips"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

meta() {
  fetch "$BASE/misc/taxi_zone_lookup.csv" "$DIR/taxi_zone_lookup.csv"
  fetch "$BASE/misc/taxi_zones.zip"       "$DIR/taxi_zones.zip"
}

# trip TYPE YYYY[-MM]
trip() {
  local type="$1" when="$2"
  case "$type" in
    yellow|green|fhv|fhvhv) ;;
    *) echo "unknown cab type: $type" >&2; exit 1 ;;
  esac
  mkdir -p "$TRIPS"
  local months
  if [[ "$when" =~ ^[0-9]{4}$ ]]; then
    months=$(seq -w 1 12)
  elif [[ "$when" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    months="${when#*-}"; when="${when%-*}"
  else
    echo "bad date: $when (want YYYY or YYYY-MM)" >&2; exit 1
  fi
  local rc=0 m name
  for m in $months; do
    name="${type}_tripdata_${when}-${m}.parquet"
    fetch "$BASE/trip-data/$name" "$TRIPS/$name" || rc=1
  done
  return $rc
}

[ $# -eq 0 ] && usage 1

case "$1" in
  -meta) meta ;;
  -trip)
    [ $# -ge 2 ] || { echo "-trip needs a date" >&2; usage 1; }
    trip "${3:-yellow}" "$2" ;;
  -h|--help) usage 0 ;;
  *) echo "unknown option: $1" >&2; usage 1 ;;
esac

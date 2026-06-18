#!/usr/bin/env bash
# Downloads fonts to DESTDIR (defaults to the directory containing this script).
# Usage: ./fonts.sh [DESTDIR]
set -euo pipefail

DESTDIR="${1:-$(dirname "$(realpath "$0")")}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DESTDIR"

_api() {
    curl -sL -H "Accept: application/vnd.github+json" -H "User-Agent: font-fetcher" "$1"
}

# Print the browser_download_url of the first asset matching PAT in the latest release of REPO.
_latest_url() {
    local repo="$1" pat="$2"
    _api "https://api.github.com/repos/$repo/releases/latest" |
    python3 -c '
import sys, json, re
pat = sys.argv[1]
for a in json.load(sys.stdin).get("assets", []):
    if re.search(pat, a["name"]):
        print(a["browser_download_url"]); break
' "$pat"
}

# Find the first release whose tag matches TAG_PAT, then print the URL of the first asset matching ASSET_PAT.
_release_url() {
    local repo="$1" tag_pat="$2" asset_pat="$3"
    _api "https://api.github.com/repos/$repo/releases?per_page=20" |
    python3 -c '
import sys, json, re
tag_pat, asset_pat = sys.argv[1], sys.argv[2]
for r in json.load(sys.stdin):
    if re.search(tag_pat, r["tag_name"]):
        for a in r.get("assets", []):
            if re.search(asset_pat, a["name"]):
                print(a["browser_download_url"]); sys.exit()
' "$tag_pat" "$asset_pat"
}

# Extract .ttf/.otf/.ttc files from ZIP into DEST, optionally filtered by path pattern PAT.
_unzip() {
    local zip="$1" dest="$2" pat="${3:-}"
    python3 -c '
import sys, re, os, zipfile, shutil
zp, dest, pat = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(zp) as z:
    for name in z.namelist():
        bn = os.path.basename(name)
        if not bn or not bn.lower().endswith((".ttf", ".otf", ".ttc")): continue
        if pat and not re.search(pat, name, re.I): continue
        with z.open(name) as s, open(os.path.join(dest, bn), "wb") as d:
            shutil.copyfileobj(s, d)
        print("   ", bn)
' "$zip" "$dest" "$pat"
}

_dl() {
    echo "  $(basename "$1") ..."
    curl -sL -o "$2" "$1"
}

echo "Noto Sans (variable)"
_dl "$(_release_url notofonts/latin-greek-cyrillic '^NotoSans-' 'NotoSans-v.*\.zip$')" "$TMP/NotoSans.zip"
_unzip "$TMP/NotoSans.zip" "$DESTDIR" 'NotoSans\['

echo "Noto Serif (variable)"
_dl "$(_release_url notofonts/latin-greek-cyrillic '^NotoSerif-' 'NotoSerif-v.*\.zip$')" "$TMP/NotoSerif.zip"
_unzip "$TMP/NotoSerif.zip" "$DESTDIR" 'NotoSerif\['

echo "Inter (variable)"
_dl "$(_latest_url rsms/inter '^Inter-.*\.zip$')" "$TMP/Inter.zip"
_unzip "$TMP/Inter.zip" "$DESTDIR" 'Variable|variable|InterVariable'

echo "JetBrains Mono (variable)"
_dl "$(_latest_url JetBrains/JetBrainsMono 'JetBrainsMono-.*\.zip$')" "$TMP/JetBrainsMono.zip"
_unzip "$TMP/JetBrainsMono.zip" "$DESTDIR" 'fonts/variable'

echo "Fira Code"
_dl "$(_latest_url tonsky/FiraCode 'Fira_Code.*\.zip$')" "$TMP/FiraCode.zip"
_unzip "$TMP/FiraCode.zip" "$DESTDIR" 'ttf/'

echo "Noto Color Emoji"
_dl "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" "$DESTDIR/NotoColorEmoji.ttf"
echo "    NotoColorEmoji.ttf"

echo "Noto Sans CJK (OTC, all languages)"
_dl "$(_release_url googlefonts/noto-cjk 'Sans' 'NotoSansCJK.*OTC.*\.zip$')" "$TMP/NotoSansCJK-OTC.zip"
_unzip "$TMP/NotoSansCJK-OTC.zip" "$DESTDIR"

echo "Amiri"
_dl "$(_latest_url aliftype/amiri 'amiri-[0-9.]+\.zip$')" "$TMP/Amiri.zip"
_unzip "$TMP/Amiri.zip" "$DESTDIR"

echo "Roboto Flex (variable)"
_dl "$(_latest_url googlefonts/roboto-flex 'roboto-flex.*\.zip$')" "$TMP/RobotoFlex.zip"
_unzip "$TMP/RobotoFlex.zip" "$DESTDIR" 'fonts/'

echo "Iosevka (SuperTTC)"
_dl "$(_latest_url be5invis/Iosevka '^SuperTTC-Iosevka-[0-9].*\.zip$')" "$TMP/Iosevka.zip"
_unzip "$TMP/Iosevka.zip" "$DESTDIR"

n=$(find "$DESTDIR" -maxdepth 1 \( -name "*.ttf" -o -name "*.otf" -o -name "*.ttc" \) | wc -l | tr -d ' ')
echo ""
echo "Done — $n font files in $DESTDIR"

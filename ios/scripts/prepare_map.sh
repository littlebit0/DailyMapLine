#!/bin/sh
# Prepares the bundled Korea map for local builds. Needs curl, unzip and Node.
# korea.pmtiles (392 MB) is too large for Git, so it is generated here and ignored.
set -eu

BUILD="${1:-20261101}"
PMTILES_VERSION=1.31.2
BASEMAPS_VERSION=5.7.2
ASSETS=https://raw.githubusercontent.com/protomaps/basemaps-assets/main
RES="$(cd "$(dirname "$0")/../DailyMapLine/Resources" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/pmtiles.zip" "https://github.com/protomaps/go-pmtiles/releases/download/v$PMTILES_VERSION/go-pmtiles-${PMTILES_VERSION}_Darwin_arm64.zip"
unzip -qo "$WORK/pmtiles.zip" -d "$WORK"
"$WORK/pmtiles" extract "https://build.protomaps.com/$BUILD.pmtiles" "$WORK/korea.pmtiles" --bbox=124.5,33,132,38.7 --maxzoom=14
mv "$WORK/korea.pmtiles" "$RES/korea.pmtiles"

(cd "$WORK" && npm init -y >/dev/null && npm install --silent "@protomaps/basemaps@$BASEMAPS_VERSION")
(cd "$WORK" && node --input-type=module -e "
import { layers, namedFlavor } from '@protomaps/basemaps';
import { writeFileSync } from 'node:fs';
writeFileSync(process.argv[1], JSON.stringify(layers('protomaps', namedFlavor('light'), { lang: 'ko' })));
" "$RES/basemap-layers.json")

# Snapshots fail on any missing resource, so every glyph range is bundled.
for font in "Noto Sans Regular" "Noto Sans Medium" "Noto Sans Italic"; do
  mkdir -p "$RES/Glyphs.bundle/$font"
  encoded="$(printf %s "$font" | sed 's/ /%20/g')"
  seq 0 256 65280 | xargs -P 8 -I{} sh -c 'r="{}-$(({} + 255))"; curl -fsSL -o "$1/$r.pbf" "$2/$r.pbf"' _ "$RES/Glyphs.bundle/$font" "$ASSETS/fonts/$encoded"
done
for file in light.json light.png light@2x.json light@2x.png; do
  curl -fsSL -o "$RES/$file" "$ASSETS/sprites/v4/$file"
done

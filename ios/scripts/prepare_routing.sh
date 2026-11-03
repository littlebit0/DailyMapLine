#!/bin/sh
# Builds Valhalla routing tiles for South Korea into DailyMapLine/Resources/valhalla_tiles.tar.
# Needs curl and a few GB of free space. The tar is too large for Git, so it is ignored.
set -eu

RES="$(cd "$(dirname "$0")/../DailyMapLine/Resources" && pwd)"
WORK="${WORK:-$(mktemp -d)}"
cd "$WORK"

[ -x uv ] || { curl -fsSL https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz | tar xz --strip-components 1; }
UV_PYTHON_INSTALL_DIR="$WORK/python" ./uv venv --quiet --allow-existing --python 3.12 env
./uv pip install --quiet --python env/bin/python pyvalhalla==3.9.1
[ -f south-korea.osm.pbf ] || curl -fL -C - -o south-korea.osm.pbf https://download.geofabrik.de/asia/south-korea-latest.osm.pbf

PKG="$(env/bin/python -c 'import os, valhalla; print(os.path.dirname(valhalla.__file__))')"
mkdir -p tiles
env/bin/python "$PKG/valhalla_build_config.py" --mjolnir-tile-dir "$WORK/tiles" --mjolnir-tile-extract "$WORK/valhalla_tiles.tar" > valhalla.json
"$PKG/bin/valhalla_build_tiles" -c valhalla.json south-korea.osm.pbf
env/bin/python "$PKG/valhalla_build_extract.py" -c valhalla.json -v
mv valhalla_tiles.tar "$RES/valhalla_tiles.tar"

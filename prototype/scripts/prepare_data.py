"""Download one small public OSM extract; retain geometry, not contributor metadata."""
import hashlib
import json
import pathlib
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
BBOX = [126.9735, 37.563, 126.986, 37.574]
URL = "https://api.openstreetmap.org/api/0.6/map?bbox=" + ",".join(map(str, BBOX))


def prepare():
    request = urllib.request.Request(URL, headers={"User-Agent": "DailyMapLinePrototype/0.1 (local evaluation; one small extract)"})
    with urllib.request.urlopen(request, timeout=90) as response:
        raw = response.read()
    tree = ET.fromstring(raw)
    nodes = {n.attrib["id"]: [float(n.attrib["lon"]), float(n.attrib["lat"])] for n in tree.findall("node")}
    features = []
    graph_ways = []
    allowed = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "service", "living_street", "pedestrian", "footway", "path", "steps", "cycleway", "primary_link", "secondary_link", "tertiary_link", "trunk_link", "motorway_link"}
    for way in tree.findall("way"):
        tags = {t.attrib["k"]: t.attrib["v"] for t in way.findall("tag")}
        refs = [n.attrib["ref"] for n in way.findall("nd")]
        if len(refs) < 2 or any(ref not in nodes for ref in refs):
            continue
        coords = [nodes[ref] for ref in refs]
        props = {k: tags[k] for k in ("name", "highway", "building", "landuse", "leisure", "natural", "waterway") if k in tags}
        props["osmWay"] = way.attrib["id"]
        closed = refs[0] == refs[-1] and len(refs) >= 4
        polygon = closed and ("building" in tags or "landuse" in tags or "leisure" in tags or tags.get("natural") == "water")
        if polygon or "highway" in tags or "waterway" in tags:
            features.append({"type": "Feature", "properties": props, "geometry": {"type": "Polygon" if polygon else "LineString", "coordinates": [coords] if polygon else coords}})
        if tags.get("highway") in allowed and tags.get("access") not in {"private", "no"} and tags.get("area") != "yes":
            graph_ways.append({"id": way.attrib["id"], "nodes": refs})
    used = {ref for way in graph_ways for ref in way["nodes"]}
    metadata = {
        "source": URL, "sourceName": "OpenStreetMap contributors", "license": "ODbL-1.0",
        "licenseUrl": "https://www.openstreetmap.org/copyright", "bbox": BBOX,
        "downloadedAt": datetime.now(timezone.utc).isoformat(), "sourceSha256": hashlib.sha256(raw).hexdigest(),
        "note": "공개 장소의 소규모 시험 데이터. 도로 방향·이동수단·통행 가능성 판단은 구현하지 않음. 노드 기록은 별도의 합성 입력.",
    }
    public = ROOT / "public" / "data"
    public.mkdir(parents=True, exist_ok=True)
    (public / "map.geojson").write_text(json.dumps({"type": "FeatureCollection", "features": features}, ensure_ascii=False))
    (public / "roads.json").write_text(json.dumps({"nodes": {ref: nodes[ref] for ref in used}, "ways": graph_ways}))
    (public / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
    print(json.dumps({"mapFeatures": len(features), "graphWays": len(graph_ways), "graphNodes": len(used), "sourceBytes": len(raw)}))


if __name__ == "__main__":
    prepare()

export const VIDEO_SECONDS_PER_KM = 1;

export function distanceMeters(a, b) {
  const rad = Math.PI / 180;
  const lat = (b[1] - a[1]) * rad;
  const lon = (b[0] - a[0]) * rad;
  const h = Math.sin(lat / 2) ** 2 + Math.cos(a[1] * rad) * Math.cos(b[1] * rad) * Math.sin(lon / 2) ** 2;
  return 6371008.8 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

export function buildGraph(data) {
  const graph = new Map(Object.keys(data.nodes).map(id => [id, []]));
  for (const way of data.ways) {
    for (let i = 1; i < way.nodes.length; i++) {
      const a = way.nodes[i - 1];
      const b = way.nodes[i];
      if (a === b || !data.nodes[a] || !data.nodes[b]) continue;
      const cost = distanceMeters(data.nodes[a], data.nodes[b]);
      graph.get(a).push({ id: b, cost, way: way.id });
      graph.get(b).push({ id: a, cost, way: way.id });
    }
  }
  return graph;
}

export function nearestNode(point, nodes, limit = 80) {
  let nearest = null;
  let distance = Infinity;
  for (const [id, coordinate] of Object.entries(nodes)) {
    const candidate = distanceMeters(point, coordinate);
    if (candidate < distance) { nearest = id; distance = candidate; }
  }
  if (distance > limit) throw new Error('시험 노드 주변에 연결할 길 데이터가 없습니다. 직접 연결로 대체하지 않았습니다.');
  return { id: nearest, distance };
}

// A small local road-network route estimate, not reconstruction of an observed trip.
// Bidirectional public road geometry only; no vehicle/access profile is inferred.
export function findPath(graph, nodes, start, end) {
  const costs = new Map([[start, 0]]);
  const parents = new Map();
  const pending = [{ id: start, cost: 0, rank: distanceMeters(nodes[start], nodes[end]) }];
  while (pending.length) {
    pending.sort((a, b) => b.rank - a.rank);
    const current = pending.pop();
    if (current.cost > costs.get(current.id)) continue;
    if (current.id === end) {
      const ids = [end];
      while (ids[0] !== start) ids.unshift(parents.get(ids[0]));
      return ids;
    }
    for (const edge of graph.get(current.id) ?? []) {
      const cost = current.cost + edge.cost;
      if (cost >= (costs.get(edge.id) ?? Infinity)) continue;
      costs.set(edge.id, cost);
      parents.set(edge.id, current.id);
      pending.push({ id: edge.id, cost, rank: cost + distanceMeters(nodes[edge.id], nodes[end]) });
    }
  }
  throw new Error('시험 노드 사이의 연결 경로를 찾지 못했습니다. 노드는 유지됩니다.');
}

export function createRecording(input, data) {
  const graph = buildGraph(data);
  const nodes = input.nodes.map((node, index) => {
    const snapped = nearestNode(node.coordinate, data.nodes);
    return { id: node.id, order: index, coordinate: node.coordinate, roadNode: snapped.id, snapDistance: snapped.distance };
  });
  const branches = [];
  for (let i = 1; i < nodes.length; i++) {
    const roadNodes = findPath(graph, data.nodes, nodes[i - 1].roadNode, nodes[i].roadNode);
    const coordinates = roadNodes.map(id => data.nodes[id]);
    branches.push({ id: `B${i}`, from: nodes[i - 1].id, to: nodes[i].id, state: 'road-estimate', roadNodes, coordinates, length: pathMetrics(coordinates).length });
  }
  return { version: 1, date: input.date, synthetic: true, nodes, branches };
}

export function pathMetrics(coordinates) {
  const cumulative = [0];
  for (let i = 1; i < coordinates.length; i++) cumulative.push(cumulative.at(-1) + distanceMeters(coordinates[i - 1], coordinates[i]));
  return { cumulative, length: cumulative.at(-1) ?? 0 };
}

export function joinBranches(branches) {
  return branches.flatMap((branch, index) => index ? branch.coordinates.slice(1) : branch.coordinates);
}

export function pointAt(coordinates, cumulative, position) {
  const at = Math.max(0, Math.min(position, cumulative.at(-1)));
  let index = 1;
  while (index < cumulative.length - 1 && cumulative[index] < at) index++;
  const ratio = (at - cumulative[index - 1]) / (cumulative[index] - cumulative[index - 1] || 1);
  return {
    coordinate: coordinates[index - 1].map((v, i) => v + (coordinates[index][i] - v) * ratio),
    trace: [...coordinates.slice(0, index), coordinates[index - 1].map((v, i) => v + (coordinates[index][i] - v) * ratio)],
  };
}

export function directionChanges(coordinates, threshold = 25) {
  const metrics = pathMetrics(coordinates);
  const turns = [];
  for (let i = 1; i < coordinates.length - 1; i++) {
    const p = coordinates[i];
    const scale = Math.cos(p[1] * Math.PI / 180);
    const a = [(p[0] - coordinates[i - 1][0]) * scale, p[1] - coordinates[i - 1][1]];
    const b = [(coordinates[i + 1][0] - p[0]) * scale, coordinates[i + 1][1] - p[1]];
    if (Math.hypot(...a) < 1e-10 || Math.hypot(...b) < 1e-10) continue;
    const cosine = (a[0] * b[0] + a[1] * b[1]) / (Math.hypot(...a) * Math.hypot(...b));
    const angle = Math.acos(Math.max(-1, Math.min(1, cosine))) * 180 / Math.PI;
    if (angle >= threshold) turns.push({ coordinate: p, angle, distance: metrics.cumulative[i] });
  }
  return turns;
}

export function scaleKm(lengthMeters) {
  const steps = [1, 1.5, 2, 3, 4, 5, 8, 12, 20, 30];
  return steps.find(km => lengthMeters <= km * 1000) ?? 30;
}

export function recordingInterval(speed) {
  if (speed < 7) return 300;
  if (speed < 25) return 180;
  if (speed < 60) return 120;
  if (speed < 80) return 90;
  return 60;
}

export function exportMime() {
  return ['video/mp4;codecs=avc1.42001E', 'video/mp4', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm']
    .find(type => globalThis.MediaRecorder?.isTypeSupported(type));
}

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import buffer from '@turf/buffer';
import { buildGraph, createRecording, directionChanges, findPath, joinBranches, nearestNode, pathMetrics, pointAt, recordingInterval, scaleKm } from '../src/core.js';
import { createFogMask } from '../src/visited.js';

const roads = JSON.parse(fs.readFileSync(new URL('../public/data/roads.json', import.meta.url)));
const input = JSON.parse(fs.readFileSync(new URL('../public/sample.json', import.meta.url)));

test('시험 기록은 실제 도로 그래프의 연속 간선으로 연결되고 왕복 순서를 보존한다', () => {
  const recording = createRecording(input, roads);
  assert.equal(recording.nodes.length, 5);
  assert.equal(recording.branches.length, 4);
  assert.deepEqual(recording.nodes[0].coordinate, recording.nodes.at(-1).coordinate);
  const graph = buildGraph(roads);
  for (const branch of recording.branches) {
    assert.ok(branch.length > 0);
    for (let i = 1; i < branch.roadNodes.length; i++) {
      assert.ok(graph.get(branch.roadNodes[i - 1]).some(edge => edge.id === branch.roadNodes[i]));
    }
  }
  assert.ok(!JSON.stringify(recording).includes('timestamp'));
  assert.ok(recording.nodes.every(node => !('time' in node)));
});

test('연결 실패와 데이터 부재를 임의 직선으로 대체하지 않는다', () => {
  const data = { a: [0, 0], b: [0.1, 0] };
  assert.throws(() => nearestNode([1, 1], data), /길 데이터/);
  assert.throws(() => findPath(new Map([['a', []], ['b', []]]), data, 'a', 'b'), /찾지 못/);
});

test('속도 경계와 30km 최대 축척을 적용한다', () => {
  assert.deepEqual([0, 6.9, 7, 25, 60, 80].map(recordingInterval), [300, 300, 180, 120, 90, 60]);
  assert.deepEqual([1000, 1001, 1500, 1501, 30000, 40000].map(scaleKm), [1, 1.5, 1.5, 2, 30, 30]);
});

test('방향 표시: 직진을 제외하고 25도 이상과 왕복 반전을 표시한다', () => {
  assert.equal(directionChanges([[0, 0], [.001, 0], [.002, 0]]).length, 0);
  assert.equal(directionChanges([[0, 0], [.001, 0], [.001, .001]]).length, 1);
  assert.equal(directionChanges([[0, 0], [.001, 0], [0, 0]]).length, 1);
});

test('선 길이 기준 재생의 시작·끝과 방문 버퍼의 100m 폭', () => {
  const coords = [[126.978, 37.566], [126.982, 37.566]];
  const metrics = pathMetrics(coords);
  assert.deepEqual(pointAt(coords, metrics.cumulative, 0).coordinate, coords[0]);
  assert.deepEqual(pointAt(coords, metrics.cumulative, metrics.length).coordinate, coords[1]);
  const region = buffer({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: coords } }, 50, { units: 'meters' });
  const latitudes = region.geometry.coordinates[0].map(p => p[1]);
  const width = (Math.max(...latitudes) - Math.min(...latitudes)) * 111195;
  assert.ok(Math.abs(width - 100) < 1);
  const recording = createRecording(input, roads);
  assert.ok(pathMetrics(joinBranches(recording.branches)).length > 1000);
});

// Check polygon containment independently of the mask construction.
function insideRing(point, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i], b = ring[j];
    if ((a[1] > point[1]) !== (b[1] > point[1]) &&
        point[0] < (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
  }
  return inside;
}

function covered(mask, point) {
  return mask.features.some(({ geometry: { coordinates: rings } }) =>
    insideRing(point, rings[0]) && !rings.slice(1).some(ring => insideRing(point, ring)));
}

test('폐회로 내부는 덮고 브랜치 양옆 50m만 드러낸다', () => {
  const loop = [[127, 37], [127.004, 37], [127.004, 37.004], [127, 37.004], [127, 37]];
  const mask = createFogMask(loop);
  assert.equal(covered(mask, [127.002, 37.002]), true, '폐회로 중앙은 미방문');
  assert.equal(covered(mask, [127.002, 37.0002]), false, '브랜치 안쪽 약 22m는 방문');
  assert.equal(covered(mask, [127.002, 36.9998]), false, '브랜치 바깥쪽 약 22m는 방문');
  assert.equal(covered(mask, [127.002, 37.0006]), true, '브랜치에서 약 67m인 내부는 미방문');
  assert.equal(covered(mask, [127.006, 37.002]), true, '폐회로 바깥도 미방문');
  assert.equal(covered(createFogMask(), [127.002, 37.002]), true, '기록 없을 때 전체 덮기');
});

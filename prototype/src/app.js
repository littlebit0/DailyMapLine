import * as maplibregl from 'maplibre-gl';
import { createRecording, directionChanges, exportMime, joinBranches, pathMetrics, pointAt, scaleKm, VIDEO_SECONDS_PER_KM } from './core.js';
import { createFogMask } from './visited.js';

maplibregl.setWorkerUrl('/maplibre-gl-worker.mjs');

const $ = id => document.getElementById(id);
const empty = () => ({ type: 'FeatureCollection', features: [] });
const line = coordinates => ({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates } });
const featurePoints = points => ({ type: 'FeatureCollection', features: points.map(p => ({ type: 'Feature', properties: {}, geometry: { type: 'Point', coordinates: p.coordinate } })) });
let recording, geometry, roads, input, map, outputUrl, recordingUrl;
let generating = false;

function style(data) {
  return {
    version: 8,
    sources: { local: { type: 'geojson', data, attribution: '© OpenStreetMap contributors' } },
    layers: [
      { id: 'land', type: 'background', paint: { 'background-color': '#f2f0e9' } },
      { id: 'parks', type: 'fill', source: 'local', filter: ['all', ['==', ['geometry-type'], 'Polygon'], ['any', ['has', 'leisure'], ['has', 'landuse']]], paint: { 'fill-color': '#dce7cf' } },
      { id: 'water', type: 'fill', source: 'local', filter: ['==', ['get', 'natural'], 'water'], paint: { 'fill-color': '#c1dce7' } },
      { id: 'stream', type: 'line', source: 'local', filter: ['all', ['==', ['geometry-type'], 'LineString'], ['has', 'waterway']], paint: { 'line-color': '#b6d9e8', 'line-width': 5 } },
      { id: 'buildings', type: 'fill', source: 'local', filter: ['has', 'building'], paint: { 'fill-color': '#dedbd4', 'fill-outline-color': '#d2cfc7' } },
      { id: 'road-case', type: 'line', source: 'local', filter: ['all', ['==', ['geometry-type'], 'LineString'], ['has', 'highway']], paint: { 'line-color': '#d8d5ca', 'line-width': ['interpolate', ['linear'], ['zoom'], 12, 1, 17, 11] }, layout: { 'line-cap': 'round', 'line-join': 'round' } },
      { id: 'roads', type: 'line', source: 'local', filter: ['all', ['==', ['geometry-type'], 'LineString'], ['has', 'highway']], paint: { 'line-color': '#fffdf7', 'line-width': ['interpolate', ['linear'], ['zoom'], 12, .6, 17, 8] }, layout: { 'line-cap': 'round', 'line-join': 'round' } },
    ],
  };
}

function createMap(container, interactive, width) {
  return new maplibregl.Map({ container, style: style(geometry), center: [126.9795, 37.5682], zoom: 15.5,
    interactive, attributionControl: interactive ? { compact: false } : false,
    canvasContextAttributes: { preserveDrawingBuffer: true, antialias: true },
    pixelRatio: width ? 1 : Math.min(devicePixelRatio, 2), fadeDuration: 0,
  });
}

function routeLayers() {
  map.addSource('fog', { type: 'geojson', data: empty() });
  map.addLayer({ id: 'fog', source: 'fog', type: 'fill', paint: { 'fill-color': '#718696', 'fill-opacity': .67 } });
  map.addSource('route', { type: 'geojson', data: empty() });
  map.addLayer({ id: 'route-white', source: 'route', type: 'line', paint: { 'line-color': '#fff', 'line-width': 7 }, layout: { 'line-cap': 'round', 'line-join': 'round' } });
  map.addLayer({ id: 'route-blue', source: 'route', type: 'line', paint: { 'line-color': '#287bdb', 'line-width': 3.5 }, layout: { 'line-cap': 'round', 'line-join': 'round' } });
  map.addSource('nodes', { type: 'geojson', data: empty() });
  map.addLayer({ id: 'nodes', source: 'nodes', type: 'circle', paint: { 'circle-color': '#287bdb', 'circle-radius': 4.5, 'circle-stroke-color': '#fff', 'circle-stroke-width': 2 } });
}

function updateFog(coords) {
  map.getSource('fog').setData(createFogMask(coords));
  map.setLayoutProperty('fog', 'visibility', $('fog-toggle').checked ? 'visible' : 'none');
}

function applyRecording(value) {
  recording = value;
  const coordinates = joinBranches(recording.branches);
  const metrics = pathMetrics(coordinates);
  map.getSource('route').setData(line(coordinates));
  map.getSource('nodes').setData(featurePoints(recording.nodes));
  updateFog(coordinates);
  $('node-count').textContent = `${recording.nodes.length}개`;
  $('route-length').textContent = `${(metrics.length / 1000).toFixed(2)} km`;
  $('video-length').textContent = `${(metrics.length / 1000 * VIDEO_SECONDS_PER_KM).toFixed(1)}초`;
  $('status').textContent = `브랜치 ${recording.branches.length}개를 길에 맞춰 연결하고 이 브라우저에 저장했습니다.`;
  $('video-status').textContent = '날짜와 이동 경로로 세로 영상을 생성합니다. 생성 중에는 잠시 기다려 주세요.';
  $('generate').disabled = false;
  $('export-record').disabled = false;
  window.prototypeState = { recording, totalMeters: metrics.length, duration: metrics.length / 1000 * VIDEO_SECONDS_PER_KM, visitedWidth: 100 };
}

function drawLine(ctx, renderMap, coords, turns, position) {
  ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  for (const [color, width] of [['#ffffff', 9], ['#247ddd', 5]]) {
    ctx.beginPath();
    coords.forEach((coord, i) => { const p = renderMap.project(coord); i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y); });
    ctx.strokeStyle = color; ctx.lineWidth = width; ctx.stroke();
  }
  for (const turn of turns) {
    if (turn.distance > position) continue;
    const p = renderMap.project(turn.coordinate);
    ctx.beginPath(); ctx.arc(p.x, p.y, 5, 0, Math.PI * 2);
    ctx.fillStyle = '#247ddd'; ctx.fill(); ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.stroke();
  }
}

function drawText(ctx, kilometers) {
  ctx.fillStyle = 'rgba(255,255,255,.93)'; ctx.fillRect(26, 28, 210, 48);
  ctx.fillStyle = '#253e54'; ctx.font = '24px sans-serif'; ctx.fillText(recording.date.replaceAll('-', '.'), 42, 60);
  ctx.font = '18px sans-serif';
  ctx.fillText('상세 지도는 서울 시청 주변 시험 범위만 포함', 28, 104);
  const bar = 114;
  ctx.strokeStyle = '#28465b'; ctx.lineWidth = 2;
  ctx.beginPath(); ctx.moveTo(30, 1198); ctx.lineTo(30 + bar, 1198); ctx.stroke();
  ctx.font = '18px sans-serif'; ctx.fillText(`${kilometers.toFixed(1)} km`, 30, 1187);
  ctx.fillStyle = 'rgba(255,255,255,.95)'; ctx.fillRect(0, 1225, 720, 55);
  ctx.fillStyle = '#354d5f'; ctx.font = '16px sans-serif';
  ctx.fillText('Map data © OpenStreetMap contributors', 24, 1245);
  ctx.fillText('openstreetmap.org/copyright · ODbL', 24, 1267);
}

async function generateVideo() {
  if (!recording || generating) return;
  generating = true;
  $('generate').disabled = true; $('record').disabled = true;
  $('progress').hidden = false; $('progress').value = 0;
  let renderMap, stream, recorder;
  try {
    const mimeType = exportMime();
    if (!mimeType) throw new Error('이 브라우저에서 영상 저장 형식을 지원하지 않습니다.');
    $('video-status').textContent = '영상을 만들고 있습니다. 이 창을 열어 두세요.';
    const host = $('render-host'); host.replaceChildren();
    renderMap = createMap(host, false, 720);
    await new Promise((resolve, reject) => { renderMap.once('load', resolve); renderMap.once('error', e => reject(e.error)); });
    const canvas = document.createElement('canvas'); canvas.width = 720; canvas.height = 1280;
    const ctx = canvas.getContext('2d', { alpha: false });
    const coordinates = joinBranches(recording.branches);
    const metrics = pathMetrics(coordinates);
    const turns = directionChanges(coordinates);
    const durationMs = metrics.length / 1000 * VIDEO_SECONDS_PER_KM * 1000;
    stream = canvas.captureStream(30);
    recorder = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: 4_000_000 });
    const chunks = [];
    const done = new Promise((resolve, reject) => {
      recorder.ondataavailable = event => { if (event.data.size) chunks.push(event.data); };
      recorder.onstop = () => resolve(new Blob(chunks, { type: mimeType }));
      recorder.onerror = event => reject(event.error ?? new Error('영상 인코딩에 실패했습니다.'));
    });
    let currentScale = 1;
    let prior = 0;
    const branchEnds = [];
    for (const b of recording.branches) { prior += b.length; branchEnds.push(prior); }
    const drawFrame = async (fraction, deltaSeconds) => {
      const position = metrics.length * fraction;
      const frame = pointAt(coordinates, metrics.cumulative, position);
      let branchIndex = branchEnds.findIndex(end => end >= position);
      if (branchIndex < 0) branchIndex = recording.branches.length - 1;
      const branch = recording.branches[branchIndex];
      const start = branchIndex ? branchEnds[branchIndex - 1] : 0;
      const branchFraction = branch.length ? (position - start) / branch.length : 1;
      const target = scaleKm(branch.length);
      const transition = Math.min(1, branchFraction / .15, (1 - branchFraction) / .15);
      const desired = 1 + (target - 1) * Math.max(0, transition);
      currentScale += (desired - currentScale) * Math.min(1, deltaSeconds * 7);
      const metersPerPixel = currentScale * 1000 / 114;
      const zoom = Math.log2(Math.cos(frame.coordinate[1] * Math.PI / 180) * 40075016.686 / (512 * metersPerPixel));
      const rendered = new Promise(resolve => renderMap.once('render', resolve));
      renderMap.jumpTo({ center: frame.coordinate, zoom }); renderMap.triggerRepaint();
      await rendered;
      ctx.drawImage(renderMap.getCanvas(), 0, 0, 720, 1280);
      drawLine(ctx, renderMap, frame.trace, turns, position);
      drawText(ctx, currentScale);
      $('progress').value = fraction;
    };
    await drawFrame(0, 1);
    recorder.start(100);
    const started = performance.now();
    let last = started;
    while (true) {
      const now = performance.now();
      const fraction = Math.min(1, (now - started) / durationMs);
      await drawFrame(fraction, (now - last) / 1000); last = now;
      if (fraction === 1) break;
      await new Promise(resolve => requestAnimationFrame(resolve));
    }
    await new Promise(resolve => setTimeout(resolve, 80));
    recorder.stop();
    const blob = await done;
    if (!blob.size) throw new Error('빈 영상이 생성되었습니다.');
    if (outputUrl) URL.revokeObjectURL(outputUrl);
    outputUrl = URL.createObjectURL(blob);
    const extension = mimeType.includes('mp4') ? 'mp4' : 'webm';
    $('result').src = outputUrl; $('result').hidden = false;
    $('download').href = outputUrl; $('download').download = `DailyMapLine-${recording.date}.${extension}`; $('download').hidden = false;
    $('video-status').textContent = `${extension.toUpperCase()} 영상 생성 완료 · ${(blob.size / 1024).toFixed(0)} KB. 저장 버튼으로 내려받으세요.`;
    window.prototypeState.video = { size: blob.size, mimeType, extension, expectedDuration: durationMs / 1000, turns: turns.length };
  } catch (error) {
    $('video-status').textContent = `영상 생성 실패: ${error.message}`;
    if (recorder?.state === 'recording') recorder.stop();
  } finally {
    stream?.getTracks().forEach(track => track.stop());
    renderMap?.remove();
    generating = false; $('generate').disabled = false; $('record').disabled = false;
  }
}

async function boot() {
  const values = await Promise.all(['/data/map.geojson', '/data/roads.json', '/sample.json'].map(async url => {
    const r = await fetch(url); if (!r.ok) throw new Error(`${url}: ${r.status}`); return r.json();
  }));
  [geometry, roads, input] = values;
  map = createMap('map', true);
  map.addControl(new maplibregl.NavigationControl({ showCompass: false }));
  map.addControl(new maplibregl.ScaleControl({ maxWidth: 100 }));
  map.on('error', e => { $('status').textContent = `지도 오류: ${e.error.message}`; });
  await new Promise(resolve => map.once('load', resolve));
  routeLayers(); updateFog(); $('record').disabled = false;
  $('status').textContent = '공개 지도 준비 완료. 시험 노드로 브랜치를 만들어 보세요.';
  $('record').onclick = () => {
    try {
      const value = createRecording(input, roads);
      localStorage.setItem('DailyMapLine.prototype.recording.v1', JSON.stringify(value));
      applyRecording(value);
    } catch (error) { $('status').textContent = error.message; }
  };
  $('fog-toggle').onchange = () => map.setLayoutProperty('fog', 'visibility', $('fog-toggle').checked ? 'visible' : 'none');
  $('generate').onclick = generateVideo;
  $('export-record').onclick = () => {
    if (recordingUrl) URL.revokeObjectURL(recordingUrl);
    recordingUrl = URL.createObjectURL(new Blob([JSON.stringify(recording, null, 2)], { type: 'application/json' }));
    const a = document.createElement('a'); a.href = recordingUrl; a.download = 'DailyMapLine-test-recording.json'; a.click();
  };
  try {
    const saved = JSON.parse(localStorage.getItem('DailyMapLine.prototype.recording.v1'));
    if (saved?.version === 1 && saved.synthetic === true && saved.nodes?.length && saved.branches?.length) applyRecording(saved);
  } catch { $('status').textContent = '저장한 시험 기록을 읽지 못했습니다. 시험 노드로 다시 만들 수 있습니다.'; }
}

boot().catch(error => { $('status').textContent = `준비 실패: ${error.message}`; });

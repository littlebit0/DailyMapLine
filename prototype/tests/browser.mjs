import { chromium } from 'playwright-core';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const out = fileURLToPath(new URL('../outputs/', import.meta.url));
await fs.mkdir(out, { recursive: true });
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true,
  args: ['--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage({ viewport: { width: 1360, height: 1000 }, deviceScaleFactor: 1, acceptDownloads: true });
const errors = [];
const external = [];
page.on('pageerror', error => errors.push(error.message));
page.on('request', request => { if (!/^(http:\/\/127\.0\.0\.1:4173|blob:|data:)/.test(request.url())) external.push(request.url()); });
try {
  await page.goto('http://127.0.0.1:4173');
  await page.getByRole('button', { name: '시험 노드로 브랜치 만들기' }).waitFor();
  await page.waitForFunction(() => !document.getElementById('record').disabled);
  await page.getByRole('button', { name: '시험 노드로 브랜치 만들기' }).click();
  await page.waitForFunction(() => window.prototypeState?.recording?.branches.length === 4);
  await page.screenshot({ path: path.join(out, 'visited-map.png'), fullPage: true });
  const state = await page.evaluate(() => window.prototypeState);
  await page.reload();
  await page.waitForFunction(() => window.prototypeState?.recording?.branches.length === 4);
  // No further HTTP requests: prove already-loaded local resources can render/export.
  await page.route('**/*', route => route.abort());
  await page.getByRole('button', { name: '기기에서 영상 만들기' }).click();
  await page.waitForFunction(() => window.prototypeState?.video || document.getElementById('video-status').textContent.includes('실패'), { timeout: 90000 });
  const videoState = await page.evaluate(() => window.prototypeState.video);
  assert.ok(videoState, await page.locator('#video-status').textContent());
  assert.ok(videoState.size > 1000);
  const metadata = await page.evaluate(async () => {
    const video = document.getElementById('result');
    if (video.readyState < 1) await new Promise(resolve => video.addEventListener('loadedmetadata', resolve, { once: true }));
    return { width: video.videoWidth, height: video.videoHeight, duration: video.duration };
  });
  assert.equal(metadata.width, 720); assert.equal(metadata.height, 1280);
  if (Number.isFinite(metadata.duration)) assert.ok(Math.abs(metadata.duration - state.duration) < .5, JSON.stringify(metadata));
  const downloadEvent = page.waitForEvent('download');
  await page.getByRole('link', { name: '영상 저장' }).click();
  const download = await downloadEvent;
  await download.saveAs(path.join(out, download.suggestedFilename()));
  await page.evaluate(async () => {
    const v = document.getElementById('result');
    v.currentTime = 2;
    await new Promise(resolve => v.addEventListener('seeked', resolve, { once: true }));
    const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
    c.getContext('2d').drawImage(v, 0, 0);
    window.testFrame = c.toDataURL();
  });
  const frame = await page.evaluate(() => window.testFrame);
  await fs.writeFile(path.join(out, 'video-frame.png'), Buffer.from(frame.split(',')[1], 'base64'));
  await page.screenshot({ path: path.join(out, 'video-result.png'), fullPage: true });
  assert.deepEqual(errors, []);
  assert.deepEqual(external, []);
  const result = { state, video: videoState, metadata, externalRequests: external, pageErrors: errors, savedFile: download.suggestedFilename() };
  await fs.writeFile(path.join(out, 'browser-result.json'), JSON.stringify(result, null, 2));
  process.stdout.write(JSON.stringify({ branches: state.recording.branches.length, meters: state.totalMeters, video: videoState, metadata, externalRequests: external.length, errors }) + '\n');
} finally { await browser.close(); }

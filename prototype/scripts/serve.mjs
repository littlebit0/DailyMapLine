import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(fileURLToPath(new URL('../public/', import.meta.url)));
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.geojson': 'application/geo+json' };
const server = http.createServer(async (request, response) => {
  try {
    const name = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const target = path.resolve(root, '.' + (name === '/' ? '/index.html' : name));
    if (!target.startsWith(root + path.sep) && target !== path.join(root, 'index.html')) {
      response.writeHead(403).end(); return;
    }
    const bytes = await fs.readFile(target);
    response.writeHead(200, { 'Content-Type': types[path.extname(target)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
    response.end(bytes);
  } catch { response.writeHead(404).end('Not found'); }
});
server.listen(4173, '127.0.0.1', () => process.stdout.write('DailyMapLine prototype: http://127.0.0.1:4173\n'));

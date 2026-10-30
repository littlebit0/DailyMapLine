import fs from 'node:fs/promises';
import path from 'node:path';

const root = new URL('../node_modules/', import.meta.url);
const notices = ['DailyMapLine prototype third-party notices', 'Map data: © OpenStreetMap contributors, ODbL 1.0, https://www.openstreetmap.org/copyright'];
for (const name of await fs.readdir(root)) {
  if (name.startsWith('.')) continue;
  const dirs = name.startsWith('@') ? (await fs.readdir(new URL(name + '/', root))).map(n => name + '/' + n) : [name];
  for (const dir of dirs) {
    const directory = new URL(dir + '/', root);
    const files = await fs.readdir(directory);
    for (const file of files.filter(n => /^licen[sc]e(?:\.|$)|^copying(?:\.|$)/i.test(n))) {
      const target = new URL(file, directory);
      if (!(await fs.stat(target)).isFile()) continue;
      notices.push('\n' + path.join(dir, file) + '\n' + await fs.readFile(target, 'utf8'));
    }
  }
}
await fs.writeFile(new URL('../public/THIRD-PARTY-NOTICES.txt', import.meta.url), notices.join('\n'));

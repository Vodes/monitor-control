import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const dist = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const name = 'pw.vodes.monitorcontrol.streamDeckPlugin';
const hash = createHash('sha256')
  .update(await readFile(path.join(dist, name)))
  .digest('hex');
await writeFile(path.join(dist, 'SHA256SUMS.txt'), `${hash}  ${name}\n`, 'utf8');
console.log(`SHA256 ${hash}  ${name}`);

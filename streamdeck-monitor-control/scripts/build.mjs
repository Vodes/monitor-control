import { build } from 'esbuild';
import { cp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyVersion } from './check-version.mjs';
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(await readFile(path.join(project, 'package.json'), 'utf8'));
const manifest = JSON.parse(await readFile(path.join(project, 'assets', 'manifest.json'), 'utf8'));
verifyVersion(pkg.version, manifest.Version);
const destination = path.join(project, 'pw.vodes.monitorcontrol.sdPlugin');
await mkdir(path.join(destination, 'bin'), { recursive: true });
await mkdir(path.join(destination, 'imgs'), { recursive: true });
await mkdir(path.join(project, 'dist'), { recursive: true });
await cp(path.join(project, 'assets', 'manifest.json'), path.join(destination, 'manifest.json'));
await cp(path.join(project, 'ui'), path.join(destination, 'ui'), { recursive: true });
await cp(path.join(project, 'worker'), path.join(destination, 'worker'), { recursive: true });
for (const file of ['Set-Monitor.ps1', 'NVIDIA-NVAPI-NOTICE.md']) {
  await cp(path.join(project, '..', file), path.join(destination, 'worker', file));
}
await cp(path.join(project, 'README.md'), path.join(destination, 'README.md'));
await cp(path.join(project, '..', 'LICENSE'), path.join(destination, 'LICENSE'));
await writeFile(path.join(destination, '.sdignore'), 'logs/\n*.log\n*.js.map\n');
const result = await build({
  absWorkingDir: project,
  entryPoints: ['src/plugin.ts'],
  bundle: true,
  platform: 'node',
  target: 'node24',
  metafile: true,
  format: 'esm',
  outfile: path.join(destination, 'bin', 'plugin.js'),
  sourcemap: true,
  banner: {
    js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);",
  },
});
const packageDirectories = new Set();
for (const input of Object.keys(result.metafile.inputs).filter((input) => input.startsWith('node_modules/'))) {
  let directory = path.dirname(path.resolve(project, input));
  while (directory.startsWith(path.join(project, 'node_modules'))) {
    try {
      await readFile(path.join(directory, 'package.json'));
      packageDirectories.add(directory);
      break;
    } catch {
      directory = path.dirname(directory);
    }
  }
}
const notices = [];
for (const directory of [...packageDirectories].sort()) {
  const metadata = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
  const licenseFiles = (await readdir(directory)).filter((name) => /^licen[cs]e(?:\.|$)/i.test(name));
  for (const file of licenseFiles)
    notices.push(`${metadata.name} ${metadata.version}\n${await readFile(path.join(directory, file), 'utf8')}`);
}
await writeFile(path.join(destination, 'THIRD-PARTY-NOTICES.txt'), notices.join('\n\n---\n\n'));
// Native vector artwork: no downloaded fonts, images, or network resources.
const monitor =
  '<rect x="22" y="27" width="100" height="63" rx="8" fill="#1d2c40" stroke="#55dfad" stroke-width="5"/><path d="M72 91v17m-23 0h46" stroke="#55dfad" stroke-width="5"/>';
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><rect width="144" height="144" rx="18" fill="#101824"/>${monitor}</svg>`;
for (const name of ['plugin', 'category', 'preset', 'status', 'key']) await writeFile(path.join(destination, 'imgs', name + '.svg'), svg);
for (const name of ['plugin.png', 'plugin@2x.png']) await cp(path.join(project, 'assets', name), path.join(destination, 'imgs', name));
await writeFile(
  path.join(destination, 'package.json'),
  JSON.stringify(
    {
      name: pkg.name,
      version: pkg.version,
      author: pkg.author,
      license: pkg.license,
      private: true,
      type: 'module',
    },
    null,
    2,
  ),
);
console.log(`Built ${destination}`);

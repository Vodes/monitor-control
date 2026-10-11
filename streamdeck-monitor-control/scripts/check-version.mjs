import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function verifyVersion(packageVersion, manifestVersion, tag = '') {
  if (typeof packageVersion !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(packageVersion)) {
    throw new Error('Package version must be MAJOR.MINOR.PATCH, without prerelease suffixes.');
  }
  if (packageVersion.split('.').some((part) => Number(part) > 65535)) throw new Error('Version components must be at most 65535.');
  if (manifestVersion !== `${packageVersion}.0`)
    throw new Error(`Manifest Version must be ${packageVersion}.0; received ${manifestVersion}.`);
  if (tag && tag !== `v${packageVersion}`) throw new Error(`Release tag must be v${packageVersion}; received ${tag}.`);
  return packageVersion;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const pkg = JSON.parse(await readFile(path.join(project, 'package.json'), 'utf8'));
  const manifest = JSON.parse(await readFile(path.join(project, 'assets', 'manifest.json'), 'utf8'));
  const version = verifyVersion(pkg.version, manifest.Version, process.env.RELEASE_TAG ?? '');
  console.log(`Versions verified: ${version} / ${manifest.Version}${process.env.RELEASE_TAG ? ' / ' + process.env.RELEASE_TAG : ''}`);
}

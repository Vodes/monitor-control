import { test } from 'node:test';
import assert from 'node:assert/strict';
import { verifyVersion } from '../scripts/check-version.mjs';

test('build version matches both package and Stream Deck manifest', () => {
  assert.equal(verifyVersion('1.0.0', '1.0.0.0'), '1.0.0');
  assert.throws(() => verifyVersion('1.0.1', '1.0.0.0'), /Manifest Version/);
  assert.throws(() => verifyVersion('1.0.0', '1.0.0.1'), /Manifest Version/);
});
test('release tags must match the version; stable versions have bounded components', () => {
  assert.equal(verifyVersion('1.2.3', '1.2.3.0', 'v1.2.3'), '1.2.3');
  assert.throws(() => verifyVersion('1.2.3', '1.2.3.0', 'v1.2.4'), /Release tag/);
  for (const version of ['1.0.0-beta.1', '01.0.0', '1.0', '1.0.0.0', '-1.0.0', '65536.0.0']) {
    assert.throws(() => verifyVersion(version, `${version}.0`));
  }
});

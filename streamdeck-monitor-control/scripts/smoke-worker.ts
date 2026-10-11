import assert from 'node:assert/strict';
import path from 'node:path';
import { existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { WorkerClient, powerShellCandidates } from '../src/worker.js';
import type { Monitor } from '../src/model.js';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const executables = [
  ...new Set([...(process.env.MONITOR_TEST_PWSH ? [process.env.MONITOR_TEST_PWSH] : []), ...powerShellCandidates()].filter(existsSync)),
];
if (!executables.length) throw new Error('No PowerShell executable found.');
for (const executable of executables) {
  const worker = new WorkerClient(
    path.join(root, 'pw.vodes.monitorcontrol.sdPlugin', 'worker', 'MonitorWorker.ps1'),
    mkdtempSync(path.join(tmpdir(), 'monitor-smoke-')),
    console.error,
    executable,
  );
  try {
    const parsed = await worker.request<{ fraction: string; hz: number }>('validateRate', {
      refreshRate: '60000/1001',
    });
    assert.equal(parsed.result.fraction, '60000/1001');
    assert.equal(parsed.result.hz, 60000 / 1001);
    await assert.rejects(worker.request('validateRate', { refreshRate: '1/0' }), /positive|Invalid/i);
    const { result: monitors } = await worker.request<Monitor[]>('status');
    assert.ok(Array.isArray(monitors));
    assert.ok(monitors.length > 0, 'No monitors returned in the local desktop session');
    for (const monitor of monitors) {
      const { result: rates } = await worker.request<Array<{ Numerator: number; Denominator: number }>>('rates', {
        monitorId: monitor.MonitorId,
      });
      assert.ok(Array.isArray(rates));
      assert.ok(rates.every((rate) => rate.Numerator > 0 && rate.Denominator > 0));
      if (monitors.filter((m) => m.MonitorName.toLowerCase() === monitor.MonitorName.toLowerCase()).length === 1) {
        const named = await worker.request('rates', { monitorName: monitor.MonitorName });
        assert.deepEqual(named.result, rates);
      }
      console.log(
        `${monitor.MonitorName}: ${monitor.RefreshRateHz} Hz, ${monitor.ColorMode}, Windows ${monitor.WindowsBitsPerColorChannel}-bit / NVIDIA ${monitor.NvidiaOutputBitsPerColorChannel}-bit, ${monitor.ColorRange}; ${rates.length} exposed rates`,
      );
    }
    // A valid native operation with an absent monitor fails during resolution,
    // never during a setter. Do not issue any apply request in this smoke test.
    await assert.rejects(worker.request('rates', { monitorId: 'nonexistent-monitor' }), /matching|active|Available/i);
    console.log(`PASS: read-only protocol / native enumeration in ${executable}`);
  } finally {
    await worker.close();
  }
}

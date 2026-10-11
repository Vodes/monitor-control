import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MonitorService } from '../src/service.js';
import type { Backend, WorkerReply } from '../src/worker.js';
import type { Monitor, Preset } from '../src/model.js';
const m: Monitor = {
  MonitorId: 'id',
  MonitorName: 'Panel',
  Width: 1920,
  Height: 1080,
  RefreshRateHz: 120,
  PhysicalRefreshRateHz: 120,
  WindowsDynamicRefreshRate: false,
  HdrEnabled: true,
  HdrActive: true,
  ColorMode: 'HDR',
  ColorRange: 'Full',
  ColorRangePolicy: 'User',
  ColorEncoding: 'RGB',
  BitsPerColorChannel: 10,
  WindowsBitsPerColorChannel: 10,
  NvidiaOutputBitsPerColorChannel: 10,
  ColorDepthReadingsAgree: true,
  VariableRefreshRateActive: null,
};
const p: Preset = { id: 'p', name: 'HDR', monitorId: 'id', hdr: 'On', colorRange: 'Keep' };
class FakeBackend implements Backend {
  fields: Record<string, unknown>[] = [];
  calls: string[] = [];
  monitors = [m];
  failApply = false;
  failStatus = false;
  applyGate?: Promise<void>;
  statusGate?: Promise<void>;
  async request<T>(op: string, fields: Record<string, unknown> = {}): Promise<WorkerReply<T>> {
    this.calls.push(op);
    this.fields.push(fields);
    if (op === 'apply') {
      await this.applyGate;
      if (this.failApply) throw new Error('Unsupported timing. Previous settings restored.');
      return { result: m as T, warnings: ['Driver depth fallback.'] };
    }
    if (op === 'validateRate') return { result: { fraction: '60000/1001', hz: 60000 / 1001 } as T, warnings: [] };
    await this.statusGate;
    if (this.failStatus) throw new Error('Query failed');
    return { result: this.monitors as T, warnings: [] };
  }
}
const tick = () => new Promise((resolve) => setImmediate(resolve));
test('name presets keep matching after reconnect and pass the name to native application', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  const named = { ...p, monitorId: undefined, monitorName: 'panel' };
  service.setLibrary({ version: 1, presets: [named] });
  backend.monitors = [{ ...m, MonitorId: 'driver-updated-id' }];
  await service.refresh();
  assert.deepEqual(service.matching(backend.monitors[0]), ['HDR']);
  assert.equal(await service.apply(named), true);
  const fields = backend.fields[backend.calls.indexOf('apply')];
  assert.equal(fields.monitorName, 'panel');
  assert.equal('monitorId' in fields, false);
  assert.deepEqual(service.actionWarnings.get('id'), ['Driver depth fallback.']);
});
test('duplicate names never highlight or apply; an explicit ID still works', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  const named = { ...p, monitorId: undefined, monitorName: 'Panel' };
  service.setLibrary({ version: 1, presets: [named] });
  backend.monitors = [m, { ...m, MonitorId: 'second' }];
  await service.refresh();
  assert.deepEqual(service.matching(m), []);
  assert.equal(await service.apply(named), false);
  assert.match(service.lastError, /ambiguous/);
  assert.equal(backend.calls.includes('apply'), false);
  assert.equal(await service.apply(p), true);
});
test('rapid presses are ignored globally; polling is paused through readback', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  await service.refresh();
  let release!: () => void;
  backend.applyGate = new Promise((resolve) => {
    release = resolve;
  });
  const first = service.apply(p);
  await tick();
  assert.equal(service.busy, true);
  assert.equal(await service.apply({ ...p, id: 'second' }), false);
  await service.refresh();
  assert.deepEqual(backend.calls, ['status', 'apply']);
  release();
  assert.equal(await first, true);
  assert.deepEqual(backend.calls, ['status', 'apply', 'status']);
  assert.equal(service.busy, false);
  assert.equal(service.fresh, true);
});
test('rollback failures retain restoration report and requery resulting state', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  await service.refresh();
  backend.failApply = true;
  assert.equal(await service.apply(p), false);
  assert.match(service.presetErrors.get(p.id)!, /Previous settings restored/);
  assert.equal(backend.calls.at(-1), 'status');
  assert.equal(service.fresh, true);
  assert.equal(service.matching(m).length, 0);
});
test('one snapshot fans out; concurrent polls coalesce and stop without interest', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend, 12);
  let release!: () => void;
  backend.statusGate = new Promise((resolve) => {
    release = resolve;
  });
  const a = service.watch(),
    b = service.watch();
  await tick();
  assert.equal(backend.calls.length, 1);
  release();
  await tick();
  backend.statusGate = undefined;
  await new Promise((resolve) => setTimeout(resolve, 30));
  a();
  b();
  const count = backend.calls.length;
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(backend.calls.length, count);
  service.dispose();
});
test('failed query invalidates old snapshots and blocks apply; recovery never applies', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  await service.refresh();
  backend.failStatus = true;
  await service.refresh();
  assert.equal(service.fresh, false);
  assert.equal(await service.apply(p), false);
  assert.equal(backend.calls.includes('apply'), false);
  backend.failStatus = false;
  await service.refresh();
  assert.equal(service.fresh, true);
  assert.equal(backend.calls.includes('apply'), false);
});
test('readback failure clears stale active feedback even after successful apply', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  await service.refresh();
  backend.failStatus = true;
  assert.equal(await service.apply(p), true);
  assert.equal(service.fresh, false);
  assert.equal(service.busy, false);
});
test('rates use native validation and normalization, no setter; deleted IDs stay absent', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  const library = await service.normalizeLibrary({
    version: 1,
    presets: [{ ...p, refreshRate: '59.94005994', rateHz: 123 }],
  });
  assert.equal(library.presets[0].rateHz, 60000 / 1001);
  assert.equal(library.presets[0].refreshRate, '60000/1001');
  service.setLibrary(library);
  assert.equal(service.library.presets[0].id, 'p');
  service.setLibrary({ version: 1, presets: [] });
  assert.equal(
    service.library.presets.find((p) => p.id === 'p'),
    undefined,
  );
  assert.deepEqual(backend.calls, ['validateRate']);
});
test('disconnected monitor cannot be applied; no auto-rebinding by name', async () => {
  const backend = new FakeBackend(),
    service = new MonitorService(backend);
  backend.monitors = [{ ...m, MonitorId: 'other-port-id' }];
  await service.refresh();
  assert.equal(await service.apply(p), false);
  assert.match(service.lastError, /disconnected/);
  assert.equal(backend.calls.includes('apply'), false);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  matchPreset,
  depthWarnings,
  validatePresetShape,
  validateLibraryShape,
  resolveMonitor,
  type Monitor,
  type Preset,
} from '../src/model.js';
import { presetView, statusView, escapeXml } from '../src/render.js';
export const monitor: Monitor = {
  MonitorId: 'display-id',
  MonitorName: 'Test <Panel>',
  Width: 3840,
  Height: 2160,
  RefreshRateHz: 60000 / 1001,
  PhysicalRefreshRateHz: 60000 / 1001,
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
export const preset: Preset = {
  id: 'preset-id',
  name: 'HDR 60',
  monitorId: 'display-id',
  hdr: 'On',
  refreshRate: '60000/1001',
  rateHz: 60000 / 1001,
  colorRange: 'Full',
};
test('name selectors survive device ID changes, match exactly, and reject ambiguity', () => {
  const selector = { monitorName: 'test <panel>' };
  assert.equal(resolveMonitor([monitor], selector).monitor, monitor);
  const updated = { ...monitor, MonitorId: 'new-driver-id' };
  assert.equal(resolveMonitor([updated], selector).monitor, updated);
  assert.equal(resolveMonitor([updated], { monitorName: 'Test' }).monitor, undefined);
  assert.equal(resolveMonitor([updated], { monitorId: monitor.MonitorId }).monitor, undefined);
  const ambiguous = resolveMonitor([monitor, updated], selector);
  assert.equal(ambiguous.monitor, undefined);
  assert.match(ambiguous.error!, /ambiguous.*display-id.*new-driver-id/);
  assert.equal(resolveMonitor([monitor, updated], { monitorId: 'new-driver-id' }).monitor, updated);
});
test('libraries accept name selectors and legacy IDs, but reject missing or mixed selectors', () => {
  const named = { ...preset, monitorId: undefined, monitorName: monitor.MonitorName };
  const library = validateLibraryShape({
    version: 1,
    presets: [preset, { ...named, id: 'named' }],
  });
  assert.equal(library.presets[1].monitorName, monitor.MonitorName);
  assert.equal('monitorId' in library.presets[1], false);
  assert.throws(() => validatePresetShape({ ...preset, monitorName: monitor.MonitorName }), /exactly one/);
  assert.throws(() => validatePresetShape({ ...preset, monitorId: undefined }), /exactly one/);
  assert.throws(() => validatePresetShape({ ...named, monitorName: '\n' }), /selector/);
});
test('exact fractions match both physical/path readings, with tolerance', () => {
  assert.equal(matchPreset(preset, monitor), 'active');
  assert.equal(matchPreset(preset, { ...monitor, RefreshRateHz: preset.rateHz! + 0.009 }), 'active');
  assert.equal(matchPreset(preset, { ...monitor, RefreshRateHz: preset.rateHz! + 0.011 }), 'inactive');
  assert.equal(matchPreset(preset, { ...monitor, PhysicalRefreshRateHz: 120 }), 'inactive');
  assert.equal(matchPreset(preset, { ...monitor, WindowsDynamicRefreshRate: true }), 'inactive');
});
test('partial presets can match together; Keep ignores range/policy', () => {
  assert.equal(matchPreset({ ...preset, refreshRate: undefined, colorRange: 'Keep' }, { ...monitor, ColorRange: 'Limited' }), 'active');
  assert.equal(matchPreset({ ...preset, hdr: undefined, colorRange: 'Keep' }, monitor), 'active');
  assert.equal(matchPreset(preset, { ...monitor, ColorRangePolicy: 'BestQuality' }), 'inactive');
});
test('unknown state cannot highlight; disconnected differs from unreadable', () => {
  assert.equal(matchPreset(preset, monitor, false), 'unknown');
  assert.equal(matchPreset(preset), 'unavailable');
  assert.equal(matchPreset(preset, { ...monitor, HdrActive: null }), 'unknown');
  assert.equal(matchPreset(preset, { ...monitor, HdrActive: false, RefreshRateHz: null }), 'inactive');
  assert.equal(matchPreset(preset, { ...monitor, PhysicalRefreshRateHz: null }), 'unknown');
  assert.equal(matchPreset(preset, { ...monitor, ColorRange: 'Unknown' }), 'unknown');
});
test('depth is best effort, and VRR unknown does not affect matching', () => {
  const low = { ...monitor, WindowsBitsPerColorChannel: 8, ColorDepthReadingsAgree: false };
  assert.equal(matchPreset(preset, low), 'active');
  assert.equal(depthWarnings(low).length, 2);
  assert.equal(
    depthWarnings({
      ...monitor,
      HdrActive: false,
      WindowsBitsPerColorChannel: 8,
      NvidiaOutputBitsPerColorChannel: 8,
    }).length,
    0,
  );
  assert.equal(depthWarnings({ ...monitor, WindowsBitsPerColorChannel: null }).length, 1);
  assert.equal(monitor.VariableRefreshRateActive, null);
});
test('library shape validates input, rejects no-ops, preserves stable IDs', () => {
  assert.equal(validatePresetShape(preset).id, preset.id);
  assert.throws(
    () =>
      validatePresetShape({
        ...preset,
        hdr: undefined,
        refreshRate: undefined,
        colorRange: 'Keep',
      }),
    /no changes/,
  );
  assert.throws(() => validatePresetShape({ ...preset, colorRange: 'AutoFull' }), /range/);
  assert.throws(() => validatePresetShape({ ...preset, name: '\n' }), /name/);
  assert.throws(() => validateLibraryShape({ version: 1, presets: [preset, preset] }), /unique/);
  assert.throws(() => validateLibraryShape({ version: 2, presets: [] }), /version 1/);
  const renamed = validateLibraryShape({ version: 1, presets: [{ ...preset, name: 'Renamed' }] });
  assert.equal(renamed.presets[0].id, preset.id);
});
test('button states and separate status are visible without extra preset text', () => {
  const view = presetView(preset, monitor, true, false);
  assert.equal(view.title, preset.name);
  assert.match(Buffer.from(view.image.split(',')[1], 'base64').toString(), /✓/);
  assert.match(presetView(preset, monitor, true, true, preset.id).title, /Applying/);
  assert.match(presetView(undefined, monitor, true, false).title, /Choose/);
  assert.match(statusView(monitor, true, false).title, /HDR\n59.94 Hz\n10-bit\nRGB Full/);
  assert.match(statusView({ ...monitor, HdrActive: false, ColorMode: 'WCG' }, true, false).title, /WCG/);
  assert.match(statusView(monitor, false, false).title, /unknown/);
  assert.match(statusView(undefined, true, false).title, /unavailable/);
  assert.equal(escapeXml('<&"\''), '&lt;&amp;&quot;&apos;');
});

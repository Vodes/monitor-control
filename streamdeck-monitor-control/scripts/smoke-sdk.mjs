// Production bundle connected to a simulated Stream Deck host. All PowerShell
// requests are getters/parsing; no preset keyDown/apply is ever sent.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
const require = createRequire(import.meta.url);
const sdkRequire = createRequire(require.resolve('@elgato/streamdeck'));
const { WebSocketServer } = sdkRequire('ws');
const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
await once(server, 'listening');
const port = server.address().port;
const pluginRoot = path.resolve('pw.vodes.monitorcontrol.sdPlugin');
const messages = [];
let globalSettings = {},
  socket,
  stderr = '';
const saved = new Map();
server.on('connection', (ws) => {
  socket = ws;
  ws.on('message', (buffer) => {
    const message = JSON.parse(buffer.toString());
    messages.push(message);
    if (message.event === 'getGlobalSettings')
      ws.send(
        JSON.stringify({
          event: 'didReceiveGlobalSettings',
          payload: { settings: globalSettings },
        }),
      );
    if (message.event === 'setGlobalSettings') globalSettings = message.payload;
    if (message.event === 'setSettings') saved.set(message.context, message.payload);
    if (message.event === 'getSettings')
      ws.send(
        JSON.stringify({
          event: 'didReceiveSettings',
          action: 'pw.vodes.monitorcontrol.preset',
          context: message.context,
          device: 'test-device',
          payload: { settings: saved.get(message.context) ?? {} },
        }),
      );
  });
});
const child = spawn(
  process.execPath,
  [
    path.join(pluginRoot, 'bin', 'plugin.js'),
    '-port',
    String(port),
    '-pluginUUID',
    'pw.vodes.monitorcontrol',
    '-registerEvent',
    'registerPlugin',
    '-info',
    JSON.stringify({
      application: { version: '7.5.1', platform: 'windows', language: 'en', font: 'Segoe UI' },
      plugin: { uuid: 'pw.vodes.monitorcontrol', version: '1.0.0.0' },
      devices: [{ id: 'test-device', name: 'Test Stream Deck XL', type: 2, size: { columns: 8, rows: 4 } }],
    }),
  ],
  {
    cwd: pluginRoot,
    windowsHide: true,
    env: { ...process.env, LOCALAPPDATA: mkdtempSync(path.join(tmpdir(), 'monitor-sdk-')) },
    stdio: ['ignore', 'pipe', 'pipe'],
  },
);
child.stderr.on('data', (data) => {
  stderr += data;
});
async function waitFor(predicate, description) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const match = messages.find(predicate);
    if (match) return match;
    if (child.exitCode != null) throw new Error(`Plugin exited ${child.exitCode}: ${stderr}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out: ${description}. ${stderr}`);
}
function send(event, payload = {}, context = 'preset-key', action = 'pw.vodes.monitorcontrol.preset') {
  socket.send(JSON.stringify({ event, action, context, device: 'test-device', payload }));
}
const pi = (type, data = {}) => send('sendToPlugin', { type, ...data });
try {
  await waitFor((m) => m.event === 'registerPlugin', 'SDK registration');
  send('willAppear', {
    settings: {},
    controller: 'Keypad',
    coordinates: { column: 0, row: 0 },
    state: 0,
    isInMultiAction: false,
  });
  send('propertyInspectorDidAppear');
  pi('hello');
  const snapshot = await waitFor(
    (m) => m.event === 'sendToPropertyInspector' && m.payload.type === 'state' && m.payload.fresh && m.payload.monitors.length,
    'native snapshot',
  );
  const monitorId = snapshot.payload.monitors[0].MonitorId;
  const monitorName = snapshot.payload.monitors[0].MonitorName;
  pi('save', {
    revision: 0,
    preset: {
      name: 'Test fractional preset',
      monitorName,
      refreshRate: '60000/1001',
      colorRange: 'Keep',
    },
  });
  await waitFor((m) => m.event === 'sendToPropertyInspector' && m.payload.type === 'saved', 'shared preset save');
  const first = globalSettings.library.presets[0];
  assert.equal(first.monitorName, monitorName);
  assert.equal('monitorId' in first, false);
  assert.equal(first.refreshRate, '60000/1001');
  assert.equal(first.rateHz, 60000 / 1001);
  pi('select', { id: first.id });
  await waitFor((m) => m.event === 'setTitle' && m.payload.title === 'Test fractional preset', 'named preset key render');
  assert.equal(saved.get('preset-key').presetId, first.id);
  // Stale editors must not overwrite newer library state.
  pi('save', { revision: 0, preset: { ...first, name: 'Stale overwrite' } });
  await waitFor(
    (m) => m.event === 'sendToPropertyInspector' && m.payload.type === 'error' && m.payload.message.includes('library changed'),
    'revision conflict',
  );
  assert.equal(globalSettings.library.presets[0].name, 'Test fractional preset');
  send(
    'willAppear',
    {
      settings: { monitorName },
      controller: 'Keypad',
      coordinates: { column: 1, row: 0 },
      state: 0,
      isInMultiAction: false,
    },
    'status-key',
    'pw.vodes.monitorcontrol.status',
  );
  await waitFor((m) => m.event === 'setTitle' && m.context === 'status-key' && m.payload.title.includes('Hz'), 'status key live render');
  pi('rates', { monitorName });
  const rates = await waitFor((m) => m.event === 'sendToPropertyInspector' && m.payload.type === 'rates', 'rate picker');
  assert.ok(Array.isArray(rates.payload.rates));
  const previousMessages = messages.length;
  pi('delete', { id: first.id, revision: 1 });
  await waitFor((m) => m.event === 'setGlobalSettings' && m.payload.revision === 2, 'delete persistence');
  await waitFor(
    (m) => messages.indexOf(m) >= previousMessages && m.event === 'setTitle' && m.payload.title === 'Choose\npreset',
    'deleted preset reference',
  );
  assert.equal(saved.get('preset-key').presetId, first.id); // Reference is preserved, not silently rebound.
  console.log(
    'PASS: production Elgato SDK registration, native polling, library save/validation/conflict/delete, stable key reference, preset/status rendering, and fractional rate picker. No display setters called.',
  );
} finally {
  // This harness sends no applying event; shutdown only stops read-only polling.
  child.kill();
  socket?.close();
  await new Promise((resolve) => server.close(resolve));
}

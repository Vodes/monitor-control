import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
class Element {
  value = '';
  textContent = '';
  disabled = false;
  label = '';
  children: Element[] = [];
  onclick?: () => void;
  onchange?: () => void;
  classList = { toggle: () => {} };
  addEventListener(): void {}
  replaceChildren(...children: Element[]): void {
    this.children = children;
  }
  append(child: Element): void {
    this.children.push(child);
  }
  click(): void {
    this.onclick?.();
  }
}
class Option extends Element {
  constructor(label: string, value: string) {
    super();
    this.label = label;
    this.value = value;
  }
}
class Socket {
  static OPEN = 1;
  readyState = 1;
  sent: Record<string, unknown>[] = [];
  onopen?: () => void;
  onmessage?: (ev: { data: string }) => void;
  constructor(public url: string) {}
  send(line: string): void {
    this.sent.push(JSON.parse(line));
  }
}
function harness() {
  const elements = new Map<string, Element>();
  const document = {
    getElementById: (id: string) => {
      if (!elements.has(id)) elements.set(id, new Element());
      return elements.get(id)!;
    },
    createElement: () => new Element(),
  };
  const context = vm.createContext({
    document,
    window: { confirm: () => true },
    WebSocket: Socket,
    Option,
    console,
    setTimeout,
  });
  vm.runInContext(readFileSync('ui/inspector.js', 'utf8'), context);
  vm.runInContext(
    `window.connectElgatoStreamDeckSocket(1234, 'ctx', 'registerPropertyInspector', '{}', '{"action":"pw.vodes.monitorcontrol.preset"}'); socket.onopen();`,
    context,
  );
  const socket = vm.runInContext('socket', context) as Socket;
  function receive(payload: object) {
    socket.onmessage!({ data: JSON.stringify({ event: 'sendToPropertyInspector', payload }) });
  }
  return { elements, context, socket, receive };
}
test('property inspector uses its context and registers before requesting state', () => {
  const h = harness();
  assert.equal(h.socket.sent[0].event, 'registerPropertyInspector');
  assert.equal(h.socket.sent[0].uuid, 'ctx');
  assert.equal(h.socket.sent[1].event, 'sendToPlugin');
  assert.equal(h.socket.sent[1].context, 'ctx');
});
test('successful save keeps the saved preset ID and updates editor revision', () => {
  const h = harness();
  const snapshot = {
    type: 'state',
    library: { version: 1, presets: [] as object[] },
    revision: 0,
    monitors: [],
    settings: {},
    fresh: true,
    busy: false,
    matching: [],
    warnings: [],
    logDirectory: 'logs',
    lastError: '',
  };
  h.receive(snapshot);
  h.receive({ type: 'saved', id: 'saved-id' });
  h.receive({
    ...snapshot,
    revision: 1,
    library: {
      version: 1,
      presets: [{ id: 'saved-id', name: 'HDR', monitorId: 'id', hdr: 'On', colorRange: 'Full' }],
    },
  });
  assert.equal(h.elements.get('name')!.value, 'HDR');
  h.elements.get('save')!.click();
  const payload = h.socket.sent.at(-1)!.payload as { preset: { id: string }; revision: number };
  assert.equal(payload.preset.id, 'saved-id');
  assert.equal(payload.revision, 1);
});
test('rate picker consumes the backend rational format and renders correct Hz', () => {
  const h = harness();
  h.elements.get('monitor')!.value = 'id';
  h.receive({
    type: 'rates',
    monitorId: 'id',
    rates: [{ Numerator: 60000, Denominator: 1001, RefreshRateHz: 60000 / 1001 }],
  });
  const option = h.elements.get('rates')!.children[0];
  assert.equal(option.value, '60000/1001');
  assert.equal(option.label, '59.940 Hz');
});
test('picker recommends names, saves only a name, and ignores stale ID rate replies', () => {
  const h = harness();
  h.receive({
    type: 'state',
    library: { version: 1, presets: [] },
    revision: 0,
    monitors: [{ MonitorName: 'Panel', MonitorId: 'id', Width: 1920, Height: 1080 }],
    settings: {},
    fresh: true,
    busy: false,
    matching: [],
    warnings: [],
    logDirectory: 'logs',
    lastError: '',
  });
  const choices = h.elements.get('monitor')!.children;
  assert.equal(choices[1].value, 'name:Panel');
  assert.match(choices[1].label, /recommended/);
  assert.equal(choices[2].value, 'id');
  h.elements.get('monitor')!.value = 'name:Panel';
  h.elements.get('monitor')!.onchange!();
  assert.equal((h.socket.sent.at(-1)!.payload as Record<string, unknown>).monitorName, 'Panel');
  h.receive({
    type: 'rates',
    monitorId: 'id',
    rates: [{ Numerator: 120, Denominator: 1, RefreshRateHz: 120 }],
  });
  assert.equal(h.elements.get('rates')!.children.length, 0);
  h.receive({
    type: 'rates',
    monitorName: 'Panel',
    rates: [{ Numerator: 120, Denominator: 1, RefreshRateHz: 120 }],
  });
  assert.equal(h.elements.get('rates')!.children.length, 1);
  h.elements.get('save')!.click();
  const saved = (h.socket.sent.at(-1)!.payload as { preset: Record<string, unknown> }).preset;
  assert.equal(saved.monitorName, 'Panel');
  assert.equal('monitorId' in saved, false);
});

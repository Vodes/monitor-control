import streamDeck, { action, SingletonAction, type KeyAction, type KeyDownEvent, type WillAppearEvent,
  type WillDisappearEvent, type DidReceiveSettingsEvent } from '@elgato/streamdeck';
import { appendFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { emptyLibrary, depthWarnings, validatePresetShape, validateSelector, resolveMonitor, type Library } from './model.js';
import { WorkerClient } from './worker.js';
import { MonitorService } from './service.js';
import { presetView, statusView, icon } from './render.js';

type Settings = { presetId?: string; monitorId?: string; monitorName?: string };
type Kind = 'preset' | 'status';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const logDirectory = path.join(process.env.LOCALAPPDATA ?? process.cwd(), 'MonitorControlStreamDeck', 'logs');
function log(message: string): void {
  streamDeck.logger.info(message);
  try { mkdirSync(logDirectory, { recursive: true }); appendFileSync(path.join(logDirectory, 'plugin.log'), `${new Date().toISOString()} ${message}\n`, 'utf8'); } catch { /* Stream Deck's own log remains available. */ }
}
const worker = new WorkerClient(path.join(root, 'worker', 'MonitorWorker.ps1'), logDirectory, log);
const service = new MonitorService(worker);
worker.on('invalid', error => service.invalidate(error));
let revision = 0;
let inspectorRelease: (() => void) | undefined;
const keys = new Map<string, { action: KeyAction<Settings>; kind: Kind; settings: Settings; release: () => void; last?: string }>();
const settingsById = new Map<string, Settings>();
let edits: Promise<unknown> = Promise.resolve();

async function render(): Promise<void> {
  await Promise.allSettled([...keys.values()].map(async key => {
    const preset = service.library.presets.find(p => p.id === key.settings.presetId);
    const selection = resolveMonitor(service.monitors, key.kind === 'preset' ? preset : key.settings);
    const ambiguous = selection.error?.includes('ambiguous');
    const view = ambiguous && service.fresh && !service.busy ? { title: 'Ambiguous\nmonitor', image: icon('error') } : key.kind === 'preset'
      ? presetView(preset, selection.monitor, service.fresh, service.busy, service.applyingPresetId, preset && service.presetErrors.get(preset.id))
      : key.settings.monitorId || key.settings.monitorName ? statusView(selection.monitor, service.fresh, service.busy)
      : { title: 'Choose\nmonitor', image: icon('configure') };
    const signature = JSON.stringify(view);
    if (key.last === signature) return;
    await key.action.setImage(view.image);
    await key.action.setTitle(view.title);
    key.last = signature;
  }));
}
function inspectorState(): object {
  const context = streamDeck.ui.action?.id;
  const settings = context ? settingsById.get(context) ?? {} : {};
  const selectedPreset = service.library.presets.find(p => p.id === settings.presetId);
  const selection = resolveMonitor(service.monitors, selectedPreset ?? settings);
  const monitor = selection.monitor;
  return { type: 'state', library: service.library, revision, monitors: service.monitors,
    fresh: service.fresh, busy: service.busy, settings, lastError: service.lastError, logDirectory,
    selectedMonitor: monitor, selectionError: selection.error,
    matching: monitor ? service.matching(monitor) : [],
    warnings: monitor ? [...depthWarnings(monitor), ...(service.actionWarnings.get(monitor.MonitorId) ?? [])] : [] };
}
async function sendState(): Promise<void> {
  if (streamDeck.ui.action) await streamDeck.ui.sendToPropertyInspector(JSON.parse(JSON.stringify(inspectorState())));
}
service.on('change', () => { void render(); void sendState().catch(error => log(`Inspector update: ${String(error)}`)); });

abstract class MonitorAction extends SingletonAction<Settings> {
  abstract kind: Kind;
  override onWillAppear(ev: WillAppearEvent<Settings>): void {
    if (!ev.action.isKey()) return;
    keys.get(ev.action.id)?.release();
    settingsById.set(ev.action.id, ev.payload.settings);
    keys.set(ev.action.id, { action: ev.action, kind: this.kind, settings: ev.payload.settings, release: service.watch() });
    void render();
  }
  override onWillDisappear(ev: WillDisappearEvent<Settings>): void {
    keys.get(ev.action.id)?.release(); keys.delete(ev.action.id);
    if (streamDeck.ui.action?.id !== ev.action.id) settingsById.delete(ev.action.id);
  }
  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>): void {
    settingsById.set(ev.action.id, ev.payload.settings);
    const key = keys.get(ev.action.id);
    if (key) { key.settings = ev.payload.settings; key.last = undefined; }
    void render(); void sendState(); void service.refresh();
  }
  override async onKeyDown(ev: KeyDownEvent<Settings>): Promise<void> {
    await ready;
    if (service.busy || !ev.action.isKey()) return;
    if (this.kind === 'status') { await service.refresh(); return; }
    const preset = service.library.presets.find(p => p.id === ev.payload.settings.presetId);
    if (!preset) { await ev.action.showAlert(); return; }
    const success = await service.apply(preset);
    if (!success) { log(`Preset ${preset.name}: ${service.lastError}`); await ev.action.showAlert(); }
  }
}
@action({ UUID: 'pw.vodes.monitorcontrol.preset' })
class PresetAction extends MonitorAction { kind = 'preset' as const; }
@action({ UUID: 'pw.vodes.monitorcontrol.status' })
class StatusAction extends MonitorAction { kind = 'status' as const; }
streamDeck.actions.registerAction(new PresetAction());
streamDeck.actions.registerAction(new StatusAction());

streamDeck.ui.onDidAppear(ev => {
  inspectorRelease?.(); inspectorRelease = service.watch();
  void ev.action.getSettings().then(settings => { settingsById.set(ev.action.id, settings as Settings); return sendState(); }).catch(error => log(String(error)));
});
streamDeck.ui.onDidDisappear(() => { inspectorRelease?.(); inspectorRelease = undefined; });
streamDeck.system.onSystemDidWakeUp(() => { service.fresh = false; void service.refresh(); });

async function persist(library: Library): Promise<void> {
  await streamDeck.settings.setGlobalSettings(JSON.parse(JSON.stringify({ library, revision: revision + 1 })));
  revision++; service.setLibrary(library);
}
streamDeck.ui.onSendToPlugin(ev => {
  const message = ev.payload as Record<string, unknown>;
  const job = edits.catch(() => undefined).then(async () => {
    await ready;
    if (!message || typeof message.type !== 'string') throw new Error('Invalid editor request.');
    const context = ev.action.id;
    const isCurrent = () => streamDeck.ui.action?.id === context;
    switch (message.type) {
      case 'hello': case 'refresh': await service.refresh(); break;
      case 'select': {
        const settings: Settings = ev.action.manifestId.endsWith('.preset')
          ? { presetId: typeof message.id === 'string' ? message.id : '' }
          : message.monitorName || message.monitorId ? validateSelector(message) : typeof message.id === 'string' && message.id ? { monitorId: message.id } : {};
        settingsById.set(context, settings);
        await ev.action.setSettings(settings);
        const key = keys.get(context); if (key) { key.settings = settings; key.last = undefined; }
        await render(); break;
      }
      case 'rates': {
        const selector = validateSelector(message);
        const { result, warnings } = await worker.request('rates', { ...selector });
        if (isCurrent()) await streamDeck.ui.sendToPropertyInspector(JSON.parse(JSON.stringify({ type: 'rates', ...selector, rates: result, warnings })));
        break;
      }
      case 'save': case 'delete': case 'import': {
        let savedId = '';
        if (message.revision !== revision) throw new Error('The preset library changed. Reload the preset before saving.');
        if (message.type === 'import') await persist(await service.normalizeLibrary(message.library));
        else if (message.type === 'delete') await persist({ version: 1, presets: service.library.presets.filter(p => p.id !== message.id) });
        else {
          const p = validatePresetShape({ ...(message.preset as object), id: (message.preset as { id?: string })?.id || randomUUID() });
          const normalized = await service.normalizeLibrary({ version: 1, presets: [p] });
          const library: Library = { version: 1, presets: service.library.presets.filter(existing => existing.id !== p.id).concat(normalized.presets) };
          if (library.presets.length > 200) throw new Error('The library is limited to 200 presets.');
          await persist(library);
          savedId = p.id;
        }
        if (isCurrent()) await streamDeck.ui.sendToPropertyInspector({ type: 'saved', id: savedId });
        break;
      }
      default: throw new Error('Unknown editor operation.');
    }
    if (isCurrent()) await sendState();
  });
  edits = job;
  void job.catch(async error => {
    log(`Preset editor: ${String(error)}`);
    if (streamDeck.ui.action?.id === ev.action.id) await streamDeck.ui.sendToPropertyInspector({ type: 'error', message: error instanceof Error ? error.message : String(error) });
  });
});
const ready = streamDeck.connect().then(async () => {
  const settings = await streamDeck.settings.getGlobalSettings();
  try {
    service.setLibrary(await service.normalizeLibrary(settings.library ?? emptyLibrary()));
    revision = typeof settings.revision === 'number' ? settings.revision : 0;
  } catch (error) { service.invalidate(new Error(`Cannot load preset library: ${String(error)}. Import a corrected backup.`)); log(service.lastError); }
});
void ready.catch(error => log(`Plugin startup: ${String(error)}`));
process.on('SIGTERM', () => { service.dispose(); void worker.close(); });
process.on('SIGINT', () => { service.dispose(); void worker.close(); });

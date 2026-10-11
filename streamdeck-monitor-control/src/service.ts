import { EventEmitter } from 'node:events';
import {
  emptyLibrary,
  validateLibraryShape,
  matchPreset,
  resolveMonitor,
  validateSelector,
  type MonitorSelector,
  type Library,
  type Monitor,
  type Preset,
} from './model.js';
import type { Backend } from './worker.js';

export class MonitorService extends EventEmitter {
  library: Library = emptyLibrary();
  monitors: Monitor[] = [];
  fresh = false;
  busy = false;
  applyingPresetId?: string;
  lastError = '';
  presetErrors = new Map<string, string>();
  actionWarnings = new Map<string, string[]>();
  private refreshPromise?: Promise<void>;
  private timer?: NodeJS.Timeout;
  private interest = 0;

  constructor(
    readonly backend: Backend,
    private readonly pollMs = 2000,
  ) {
    super();
  }

  invalidate(error: Error): void {
    this.fresh = false;
    this.lastError = error.message;
    this.emit('change');
  }

  async normalizeLibrary(value: unknown): Promise<Library> {
    const library = validateLibraryShape(value);
    for (const preset of library.presets) {
      if (preset.refreshRate) {
        const { result } = await this.backend.request<{ fraction: string; hz: number }>('validateRate', {
          refreshRate: preset.refreshRate,
        });
        preset.refreshRate = result.fraction;
        preset.rateHz = result.hz;
      }
    }
    return library;
  }

  setLibrary(library: Library): void {
    this.library = library;
    this.presetErrors.clear();
    this.emit('change');
  }

  watch(): () => void {
    this.interest++;
    if (!this.timer) this.timer = setInterval(() => void this.refresh(), this.pollMs);
    void this.refresh();
    let active = true;
    return () => {
      if (!active) return;
      active = false;
      if (--this.interest === 0) {
        clearInterval(this.timer);
        this.timer = undefined;
      }
    };
  }

  async refresh(): Promise<void> {
    if (this.busy) return;
    await this.capture();
  }

  private capture(): Promise<void> {
    if (this.refreshPromise) return this.refreshPromise;
    const job = (async () => {
      try {
        const { result } = await this.backend.request<Monitor[]>('status');
        if (!Array.isArray(result) || result.some((m) => !m || typeof m.MonitorId !== 'string'))
          throw new Error('Invalid monitor snapshot.');
        this.monitors = result;
        this.fresh = true;
      } catch (error) {
        this.fresh = false;
        this.lastError = String(error instanceof Error ? error.message : error);
      }
      this.emit('change');
    })();
    this.refreshPromise = job;
    void job.finally(() => {
      if (this.refreshPromise === job) this.refreshPromise = undefined;
    });
    return job;
  }

  async apply(preset: Preset): Promise<boolean> {
    if (this.busy) return false;
    if (!this.fresh) {
      return this.rejectPreset(preset, 'Monitor status is unknown. Refresh before applying a preset.');
    }
    const selected = resolveMonitor(this.monitors, preset);
    if (!selected.monitor) {
      return this.rejectPreset(preset, selected.error ?? 'Choose a monitor.');
    }
    // Busy is set synchronously, before any await, including an ongoing query.
    this.busy = true;
    this.applyingPresetId = preset.id;
    this.presetErrors.delete(preset.id);
    this.emit('change');
    let success = false;
    try {
      await this.refreshPromise;
      this.fresh = false;
      const { result, warnings } = await this.backend.request<Monitor>('apply', {
        ...validateSelector(preset),
        hdr: preset.hdr,
        refreshRate: preset.refreshRate,
        colorRange: preset.colorRange,
      });
      this.actionWarnings.set(result?.MonitorId ?? selected.monitor.MonitorId, warnings);
      this.lastError = '';
      success = true;
    } catch (error) {
      this.lastError = error instanceof Error ? error.message : String(error);
      this.presetErrors.set(preset.id, this.lastError);
    } finally {
      // Keep busy through readback, including rollback readback. No queued click
      // can initiate a second transaction during this verification window.
      await this.capture();
      this.busy = false;
      this.applyingPresetId = undefined;
      this.emit('change');
    }
    return success;
  }

  private rejectPreset(preset: Preset, message: string): false {
    this.lastError = message;
    this.presetErrors.set(preset.id, message);
    this.emit('change');
    return false;
  }

  monitor(selector?: MonitorSelector | string): Monitor | undefined {
    const target = typeof selector === 'string' ? { monitorId: selector } : selector;
    return resolveMonitor(this.monitors, target).monitor;
  }

  matching(monitor: Monitor): string[] {
    return this.library.presets
      .filter((preset) => {
        const selectedMonitor = this.monitor(preset);
        if (selectedMonitor?.MonitorId !== monitor.MonitorId) return false;
        return matchPreset(preset, monitor, this.fresh) === 'active';
      })
      .map((preset) => preset.name);
  }

  dispose(): void {
    clearInterval(this.timer);
    this.timer = undefined;
  }
}

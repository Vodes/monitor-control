export type Range = 'Full' | 'Limited' | 'Keep';
export interface MonitorSelector {
  monitorName?: string;
  monitorId?: string;
}

export function validateSelector(value: MonitorSelector): MonitorSelector {
  const keys = ['monitorName', 'monitorId'] as const;
  const present = keys.filter((key) => value[key] != null);
  if (present.length !== 1) throw new Error('Select exactly one monitor name or device ID.');
  const key = present[0]!;
  const text = value[key];
  if (typeof text !== 'string' || !text.trim() || text.length > 512 || /[\x00-\x1f]/.test(text))
    throw new Error('Invalid monitor selector.');
  return { [key]: text };
}

export function resolveMonitor(monitors: Monitor[], selector?: MonitorSelector): { monitor?: Monitor; error?: string } {
  if (!selector?.monitorName && !selector?.monitorId) return {};
  const key = selector.monitorName ? 'MonitorName' : 'MonitorId';
  const wanted = (selector.monitorName ?? selector.monitorId)!.toLowerCase();
  const matches = monitors.filter((m) => m[key]?.toLowerCase() === wanted);
  if (matches.length > 1)
    return {
      error: `Monitor name is ambiguous. Choose a device ID: ${matches.map((m) => m.MonitorId).join(', ')}`,
    };
  return matches.length ? { monitor: matches[0] } : { error: 'The selected monitor is disconnected.' };
}

export interface Preset extends MonitorSelector {
  id: string;
  name: string;
  hdr?: 'On' | 'Off';
  refreshRate?: string;
  rateHz?: number;
  colorRange: Range;
}

export interface Library {
  version: 1;
  presets: Preset[];
}

export interface Monitor {
  MonitorId: string;
  MonitorName: string;
  DisplayName?: string;
  Width: number;
  Height: number;
  RefreshRateHz: number | null;
  PhysicalRefreshRateHz: number | null;
  RefreshRateFraction?: string;
  WindowsDynamicRefreshRate: boolean | null;
  HdrEnabled: boolean | null;
  HdrActive: boolean | null;
  ColorMode: string;
  ColorRange: string;
  ColorRangePolicy: string;
  ColorEncoding: string;
  BitsPerColorChannel: number | null;
  WindowsBitsPerColorChannel: number | null;
  NvidiaOutputBitsPerColorChannel: number | null;
  ColorDepthReadingsAgree: boolean | null;
  ColorDepthFallbackReason?: string | null;
  VariableRefreshRateActive: boolean | null;
  [key: string]: unknown;
}

export type Match = 'active' | 'inactive' | 'unknown' | 'unavailable';
export function matchPreset(preset: Preset, monitor?: Monitor, fresh = true): Match {
  if (!fresh) return 'unknown';
  if (!monitor) return 'unavailable';
  const checks: Array<boolean | null> = [];
  if (preset.hdr) {
    const wanted = preset.hdr === 'On';
    for (const actual of [monitor.HdrEnabled, monitor.HdrActive]) checks.push(actual == null ? null : actual === wanted);
  }
  if (preset.refreshRate) {
    for (const actual of [monitor.RefreshRateHz, monitor.PhysicalRefreshRateHz]) {
      checks.push(actual == null || !Number.isFinite(preset.rateHz) ? null : Math.abs(actual - preset.rateHz!) <= 0.010000001);
    }
    checks.push(monitor.WindowsDynamicRefreshRate == null ? null : !monitor.WindowsDynamicRefreshRate);
  }
  if (preset.colorRange !== 'Keep') {
    checks.push(!monitor.ColorRange || monitor.ColorRange === 'Unknown' ? null : monitor.ColorRange === preset.colorRange);
    checks.push(!monitor.ColorRangePolicy || monitor.ColorRangePolicy === 'Unknown' ? null : monitor.ColorRangePolicy === 'User');
  }
  if (!checks.length || checks.includes(null)) return checks.includes(false) ? 'inactive' : 'unknown';
  return checks.every(Boolean) ? 'active' : 'inactive';
}

export function depthWarnings(monitor: Monitor): string[] {
  let expected: number | null = null;
  if (monitor.HdrActive != null) {
    expected = monitor.HdrActive ? 10 : 8;
  }
  const messages: string[] = [];
  if (expected == null || monitor.WindowsBitsPerColorChannel == null) messages.push('Color depth could not be verified.');
  else if (monitor.WindowsBitsPerColorChannel !== expected)
    messages.push(`Windows reports ${monitor.WindowsBitsPerColorChannel}-bit; ${expected}-bit preferred.`);
  if (monitor.ColorDepthReadingsAgree === false)
    messages.push(
      `Depth readings disagree: Windows ${monitor.WindowsBitsPerColorChannel}, NVIDIA ${monitor.NvidiaOutputBitsPerColorChannel}.`,
    );
  if (monitor.ColorDepthFallbackReason) messages.push(monitor.ColorDepthFallbackReason);
  return messages;
}

export function validatePresetShape(value: unknown): Preset {
  if (!value || typeof value !== 'object') throw new Error('Invalid preset.');
  const p = value as Record<string, unknown>;
  for (const key of ['id', 'name']) {
    if (typeof p[key] !== 'string' || !p[key].trim() || p[key].length > 512 || /[\x00-\x1f]/.test(p[key]))
      throw new Error(`Invalid preset ${key}.`);
  }
  if (p.hdr != null && p.hdr !== 'On' && p.hdr !== 'Off') throw new Error('Invalid HDR setting.');
  if (!['Full', 'Limited', 'Keep'].includes(p.colorRange as string)) throw new Error('Invalid range setting.');
  if (p.refreshRate != null && (typeof p.refreshRate !== 'string' || !p.refreshRate.trim() || p.refreshRate.length > 128))
    throw new Error('Invalid refresh rate.');
  if (!p.hdr && !p.refreshRate && p.colorRange === 'Keep') throw new Error('Preset requests no changes.');
  return {
    id: p.id as string,
    name: (p.name as string).trim(),
    ...validateSelector(p as MonitorSelector),
    ...(p.hdr ? { hdr: p.hdr as 'On' | 'Off' } : {}),
    ...(p.refreshRate ? { refreshRate: (p.refreshRate as string).trim() } : {}),
    colorRange: p.colorRange as Range,
  };
}

export function validateLibraryShape(value: unknown): Library {
  const lib = value as Library;
  if (!lib || lib.version !== 1 || !Array.isArray(lib.presets) || lib.presets.length > 200)
    throw new Error('Expected a version 1 preset library (up to 200 presets).');
  const presets = lib.presets.map(validatePresetShape);
  if (new Set(presets.map((p) => p.id)).size !== presets.length) throw new Error('Preset IDs must be unique.');
  return { version: 1, presets };
}

export const emptyLibrary = (): Library => ({ version: 1, presets: [] });

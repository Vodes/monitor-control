import { depthWarnings, matchPreset, type Monitor, type Preset } from './model.js';
export function escapeXml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[char]!);
}

export function icon(state: string, plain = false): string {
  const colors: Record<string, string> = {
    active: '#55dfad',
    activeWarning: '#ffc568',
    inactive: '#6e819a',
    applying: '#ffc568',
    warning: '#ffc568',
    error: '#ff7185',
    unknown: '#aab8d2',
    unavailable: '#ff7185',
    configure: '#aab8d2',
  };
  const marks: Record<string, string> = {
    active: '✓',
    activeWarning: '✓',
    warning: '!',
    error: '!',
    unknown: '?',
    unavailable: '×',
    applying: '…',
    configure: '+',
  };
  const color = colors[state] ?? '#aab8d2';
  const mark = marks[state] ?? '';
  const badge =
    state === 'activeWarning' ? `<text x="108" y="48" font-family="Segoe UI,Arial" font-size="20" fill="${color}">!</text>` : '';
  const art = plain
    ? ''
    : `<rect x="28" y="26" width="88" height="52" rx="6" fill="#1d2c40" stroke="${color}" stroke-width="3"/><path d="M72 79v10m-18 0h36" stroke="${color}" stroke-width="3"/><text x="72" y="66" text-anchor="middle" font-family="Segoe UI,Arial" font-size="32" fill="${color}">${mark}</text>${badge}`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><rect width="144" height="144" rx="18" fill="#101824"/><rect x="5" y="5" width="134" height="134" rx="15" fill="none" stroke="${color}" stroke-width="3"/>${art}</svg>`;
  return 'data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64');
}

export function presetView(
  preset: Preset | undefined,
  monitor: Monitor | undefined,
  fresh: boolean,
  busy: boolean,
  applyingId?: string,
  error?: string,
): { title: string; image: string } {
  if (!preset) return { title: 'Choose\npreset', image: icon('configure') };
  const match = matchPreset(preset, monitor, fresh);
  let state: string = match;
  if (busy) {
    state = applyingId === preset.id ? 'applying' : 'unknown';
  } else if (error) {
    state = 'error';
  } else if (match === 'active' && monitor && depthWarnings(monitor).length) {
    state = 'activeWarning';
  }
  return {
    title: `${busy && applyingId === preset.id ? 'Applying\n' : ''}${preset.name}`,
    image: icon(state),
  };
}

export function statusView(monitor: Monitor | undefined, fresh: boolean, busy: boolean): { title: string; image: string } {
  if (busy) return { title: 'Applying…', image: icon('applying') };
  if (!fresh) return { title: 'Status\nunknown', image: icon('unknown') };
  if (!monitor) return { title: 'Monitor\nunavailable', image: icon('unavailable') };
  let mode = 'SDR';
  if (monitor.HdrActive == null) {
    mode = '?';
  } else if (monitor.HdrActive) {
    mode = 'HDR';
  } else if (monitor.ColorMode?.startsWith('WCG')) {
    mode = 'WCG';
  }
  const hz = monitor.RefreshRateHz == null ? '?' : monitor.RefreshRateHz.toFixed(2).replace(/\.00$/, '');
  const bits =
    monitor.ColorDepthReadingsAgree === false
      ? `${monitor.WindowsBitsPerColorChannel ?? '?'}/${monitor.NvidiaOutputBitsPerColorChannel ?? '?'}`
      : String(monitor.WindowsBitsPerColorChannel ?? '?');
  const range = monitor.ColorRange && monitor.ColorRange !== 'Unknown' ? monitor.ColorRange : '? range';
  return {
    title: `${mode}\n${hz} Hz\n${bits}-bit\n${monitor.ColorEncoding || '?'} ${range}`,
    image: icon(depthWarnings(monitor).length ? 'warning' : 'inactive', true),
  };
}

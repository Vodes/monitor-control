/* Stream Deck's property-inspector socket. All resources are bundled/offline. */
let socket,
  context,
  actionId,
  state,
  editId = '',
  editRevision = 0,
  dirty = false,
  savedEditorId,
  pendingConfirmation;
const $ = (id) => document.getElementById(id);
const notice = (message, error = false) => {
  $('notice').textContent = message;
  $('notice').classList.toggle('error', error);
};
function confirmAction(message, callback) {
  pendingConfirmation = callback;
  $('confirmationMessage').textContent = message;
  $('confirmation').hidden = false;
}
$('confirmAction').onclick = () => {
  $('confirmation').hidden = true;
  const callback = pendingConfirmation;
  pendingConfirmation = undefined;
  callback?.();
};
$('cancelAction').onclick = () => {
  $('confirmation').hidden = true;
  pendingConfirmation = undefined;
};
function send(payload) {
  if (socket?.readyState !== WebSocket.OPEN) {
    notice('Stream Deck connection is unavailable.', true);
    return;
  }
  socket.send(JSON.stringify({ event: 'sendToPlugin', action: actionId, context, payload }));
}
window.connectElgatoStreamDeckSocket = (port, uuid, registerEvent, info, actionInfo) => {
  context = uuid;
  actionId = JSON.parse(actionInfo).action;
  socket = new WebSocket('ws://127.0.0.1:' + port);
  socket.onopen = () => {
    socket.send(JSON.stringify({ event: registerEvent, uuid }));
    send({ type: 'hello' });
  };
  socket.onclose = () => notice('Stream Deck connection closed.', true);
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.event !== 'sendToPropertyInspector') return;
    const payload = message.payload;
    if (payload.type === 'state') updateState(payload);
    else if (payload.type === 'error') {
      notice(payload.message, true);
      $('save').disabled = false;
    } else if (payload.type === 'saved') {
      dirty = false;
      savedEditorId = payload.id || '';
      notice('Library saved. No display settings changed.');
      $('save').disabled = false;
    } else if (payload.type === 'rates' && selectorValue(payload) === $('monitor').value) {
      $('rates').replaceChildren();
      for (const rate of payload.rates) {
        const option = document.createElement('option');
        option.value = `${rate.Numerator}/${rate.Denominator}`;
        option.label = `${Number(rate.RefreshRateHz).toFixed(3)} Hz`;
        $('rates').append(option);
      }
      $('rateHint').textContent = payload.rates.length
        ? 'Choose an exposed rate or type decimal Hz / a fraction. Blank keeps the current rate.'
        : 'No exposed rates at this resolution. Type a rate for Windows to validate, or leave blank.';
    }
  };
};
function fillSelect(element, choices, value, empty = 'Choose…') {
  element.replaceChildren(new Option(empty, ''));
  for (const choice of choices) element.append(new Option(choice.label, choice.value));
  if (value && !choices.some((choice) => choice.value === value)) element.append(new Option('Unavailable: ' + value.slice(-42), value));
  element.value = value || '';
}
function selectorValue(selector) {
  return selector?.monitorName ? 'name:' + selector.monitorName : selector?.monitorId || '';
}
function selector(value) {
  return value.startsWith('name:') ? { monitorName: value.slice(5) } : value ? { monitorId: value } : {};
}
function selectedMonitor(target) {
  const matches = (state?.monitors || []).filter((m) =>
    target?.monitorName
      ? m.MonitorName.toLowerCase() === target.monitorName.toLowerCase()
      : target?.monitorId && m.MonitorId.toLowerCase() === target.monitorId.toLowerCase(),
  );
  return matches.length === 1 ? matches[0] : undefined;
}
function monitorChoices() {
  const monitors = state?.monitors || [],
    names = new Map();
  for (const m of monitors) {
    const key = m.MonitorName.toLowerCase();
    if (!names.has(key)) {
      const count = monitors.filter((other) => other.MonitorName.toLowerCase() === key).length;
      names.set(key, {
        value: 'name:' + m.MonitorName,
        label: `${m.MonitorName} · by name${count > 1 ? ' (ambiguous — choose a device ID below)' : ' (recommended)'}`,
      });
    }
  }
  return [
    ...names.values(),
    ...monitors.map((m) => ({
      value: m.MonitorId,
      label: `Device ID: ${m.MonitorName} · ${m.Width}×${m.Height} · ${m.MonitorId.slice(-28)}`,
    })),
  ];
}
function updateState(next) {
  const first = !state,
    wasBusy = state?.busy;
  state = next;
  const presetButton = actionId.endsWith('.preset');
  const presets = state.library.presets.map((p) => ({ value: p.id, label: p.name }));
  $('actionLabel').textContent = presetButton ? 'Button preset' : 'Status monitor';
  fillSelect(
    $('actionSelection'),
    presetButton ? presets : monitorChoices(),
    presetButton ? state.settings.presetId : selectorValue(state.settings),
  );
  fillSelect($('editSelection'), presets, editId, 'New preset');
  if (!dirty) fillSelect($('monitor'), monitorChoices(), $('monitor').value);
  const preset = state.library.presets.find((p) => p.id === state.settings.presetId);
  const target = presetButton ? preset : state.settings;
  const monitor = selectedMonitor(target);
  if (state.busy) $('live').textContent = 'Applying preset… Further presses are ignored.';
  else if (!state.fresh) $('live').textContent = 'Status unknown. ' + state.lastError;
  else if (!monitor)
    $('live').textContent =
      state.selectionError ||
      (selectorValue(target)
        ? 'Selected monitor is disconnected or its name is ambiguous.'
        : 'Select a preset or monitor for this button.');
  else {
    const mode = monitor.HdrActive == null ? 'HDR unknown' : monitor.HdrActive ? 'HDR' : monitor.ColorMode;
    $('live').textContent =
      `${monitor.MonitorName}\n${mode} · ${monitor.RefreshRateHz?.toFixed(2) ?? '?'} Hz\nWindows ${monitor.WindowsBitsPerColorChannel ?? '?'}-bit · NVIDIA ${monitor.NvidiaOutputBitsPerColorChannel ?? '?'}-bit\n${monitor.ColorEncoding} · ${monitor.ColorRange}\n${state.matching.length ? 'Matches: ' + state.matching.join(', ') : 'Custom settings'}`;
  }
  $('details').textContent = JSON.stringify(
    {
      matchingPresets: state.matching,
      warnings: state.warnings,
      lastError: state.lastError || null,
      monitor: state.fresh ? (monitor ?? null) : null,
      fresh: state.fresh,
    },
    null,
    2,
  );
  $('logPath').value = state.logDirectory;
  if (first) {
    notice('Ready. Buttons reflect actual settings.');
    fillEditor('');
  }
  if (savedEditorId !== undefined) {
    fillEditor(savedEditorId);
    savedEditorId = undefined;
  }
  if (state.busy) notice('Applying… Extra preset presses will be ignored.');
  else if (wasBusy) notice(state.lastError || 'Finished. Live monitor status updated.', !!state.lastError);
}
function fillEditor(id, duplicate = false) {
  const preset = state?.library.presets.find((p) => p.id === id);
  editId = duplicate ? '' : id;
  editRevision = state?.revision ?? 0;
  dirty = false;
  $('editSelection').value = editId;
  $('name').value = preset ? preset.name + (duplicate ? ' copy' : '') : '';
  fillSelect($('monitor'), monitorChoices(), selectorValue(preset));
  $('hdr').value = preset?.hdr || '';
  $('rate').value = preset?.refreshRate || '';
  $('range').value = preset?.colorRange || 'Full';
  if ($('monitor').value) send({ type: 'rates', ...selector($('monitor').value) });
}
$('actionSelection').onchange = () =>
  send(
    actionId.endsWith('.preset')
      ? { type: 'select', id: $('actionSelection').value }
      : { type: 'select', ...selector($('actionSelection').value) },
  );
$('refresh').onclick = () => send({ type: 'refresh' });
$('editSelection').onchange = () => fillEditor($('editSelection').value);
$('new').onclick = () => fillEditor('');
$('duplicate').onclick = () => fillEditor($('editSelection').value, true);
$('delete').onclick = () => {
  if (!editId) return;
  const id = editId,
    revision = editRevision;
  confirmAction('Delete this shared preset? Buttons using it will need a new selection.', () => send({ type: 'delete', id, revision }));
};
for (const id of ['name', 'monitor', 'hdr', 'rate', 'range'])
  $(id).addEventListener('input', () => {
    dirty = true;
  });
$('monitor').onchange = () => {
  $('rates').replaceChildren();
  if ($('monitor').value) send({ type: 'rates', ...selector($('monitor').value) });
};
$('save').onclick = () => {
  $('save').disabled = true;
  notice('Validating and saving…');
  send({
    type: 'save',
    revision: editRevision,
    preset: {
      id: editId || undefined,
      name: $('name').value,
      ...selector($('monitor').value),
      hdr: $('hdr').value || undefined,
      refreshRate: $('rate').value.trim() || undefined,
      colorRange: $('range').value,
    },
  });
};
$('export').onclick = () => {
  $('backup').value = JSON.stringify(state.library, null, 2);
  const url = URL.createObjectURL(new Blob([$('backup').value], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = 'monitor-presets.json';
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  notice('Backup prepared. You can also copy the JSON below.');
};
$('importFile').onchange = async (event) => {
  const file = event.target.files[0];
  if (file) $('backup').value = await file.text();
};
$('import').onclick = () => {
  try {
    const library = JSON.parse($('backup').value);
    const revision = state.revision;
    confirmAction('Replace the shared preset library with this backup? This will not apply settings.', () =>
      send({ type: 'import', library, revision }),
    );
  } catch (error) {
    notice('Invalid JSON: ' + error.message, true);
  }
};

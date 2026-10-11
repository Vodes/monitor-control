# Monitor Control for Stream Deck

A preset button shows its name and a checkmark when the monitor's **actual** settings match. The optional status tile shows HDR/SDR/WCG, Hz, bits per channel, encoding, and Full/Limited range. Changes made in Windows or NVIDIA Control Panel are detected too.

## Install and set up

1. Double-click `dist/pw.vodes.monitorcontrol.streamDeckPlugin` and accept Stream Deck's installation dialog. Requires Stream Deck **7.5+** on **64-bit Windows 11**, in your normal desktop session. Node.js is supplied by Stream Deck. Installed PowerShell 7 is preferred; Windows PowerShell 5.1 works too.
2. Drag **Monitor Control → Apply Preset** onto a key. Expand **Manage shared presets**, enter a name, choose the monitor, and specify HDR, refresh rate, and range. Click **Save preset**, then choose it in **Button preset**.
3. Add further preset keys using the same shared library. Optionally drag **Monitor Status** onto another key and choose its monitor. Pressing the status key only refreshes its readings.
4. Keep the default key image and leave the Stream Deck custom title blank; custom artwork/title can override live plugin feedback.

For a monitor exposing 119.88 and 239.99 Hz, example presets are **HDR 240** (On / 239.99 / Full), **SDR 240** (Off / 239.99 / Full), **HDR 120** (On / 119.88 / Full), and **SDR 120** (Off / 119.88 / Full). Use your display's supported rates. Presets are not installed or applied automatically.

**Full** is the default range for new presets and uses NVIDIA's user color policy. Other GPUs cannot enforce this through the current backend; use **Keep** to leave range to the driver. HDR/rate actions with Full or Limited prefer 10-bit HDR / 8-bit SDR. An unsupported depth is a warning, not a rollback trigger. Limited is available only when deliberately chosen.

The refresh-rate input offers exposed rational rates at the current resolution. Decimal Hz and exact fractions such as `60000/1001` also work. A custom number requests a timing that Windows supports; it cannot create a new timing. Unsupported requests fail with the backend's restoration report.

Partial presets change only their specified HDR/rate fields and range policy. Set range to **Keep** for an HDR-only or refresh-only preset. Several partial presets may match together.

Select the recommended **by name** entry for presets and status tiles. Names match exactly, ignoring case, and are resolved again on every query/application, so driver updates that change device IDs do not require reselection. If several displays share a name, the plugin reports ambiguity and requires one of the **Device ID** entries. Existing ID-based presets and backups remain supported; edit their monitor selection to a name entry to switch. ID entries stay tied to that device ID and may require reselection after driver/connection changes.

## Feedback and failure handling

- Green checkmark: all requested settings match. Amber warning: matching settings with unexpected/unknown depth or disagreeing depth readings. Neutral: different settings.
- `Applying…`: one global transaction is running; extra preset presses are ignored, not queued.
- Question mark: readings are unknown or another preset is applying. Cross: selected monitor is disconnected. Plus: choose a preset.
- Red error: that preset's last attempt failed. Detailed error/restoration information is in **Diagnostics**. A subsequent attempt or library edit clears its error badge. Other keys reflect the settings read back after rollback.

Read-only polling runs every two seconds while plugin keys or their settings panel are visible. A completed action triggers an immediate readback. Nothing is applied at startup, wake, reconnect, settings edit, or import. A crashed worker is restarted with backoff; interrupted actions are never automatically replayed or killed on an application timeout.

HDR and NVIDIA color policy persistence remain controlled by Windows/driver. Refresh changes remain temporary, as in the standalone script. G-SYNC/VRR **activity remains unknown** when the backend cannot reliably measure it; Windows Dynamic Refresh Rate is a separate setting.

Logs: `%LOCALAPPDATA%\MonitorControlStreamDeck\logs\monitor-actions.log` contains native stages, verification, warnings and rollback; `plugin.log` contains bridge/editor errors. The exact folder and separate Windows/NVIDIA depth readings appear in Diagnostics. Polling does not log every snapshot.

**Backup / import library** exports JSON or lets you copy it. Presets are plugin global settings, separate from Stream Deck profile exports. Import replaces the library, retaining button references when IDs match, and never applies a preset. Keep a backup before replacing a library. Renaming keeps its ID; deleting leaves its keys needing a new selection.

## Build and verify

Developer requirements: Node 24+, pnpm, and 64-bit Windows for PowerShell integration checks. The installed plugin itself needs neither pnpm nor a separate Node installation.

```powershell
cd streamdeck-monitor-control
pnpm install --frozen-lockfile
pnpm check
pnpm test
pnpm build
pnpm validate
pnpm run package
pnpm run checksum
```

Build copies the canonical sibling `Set-Monitor.ps1` and `NVIDIA-NVAPI-NOTICE.md` into the plugin and bundles the Elgato SDK. Updating that script requires rebuilding/reinstalling the plugin. The standalone script remains usable independently. No local server, cloud service, downloaded UI resources, GPU redistributable, or additional PowerShell module is required.

For the existing backend suite, run `..\tests\Test-MonitorControl.ps1` in PowerShell 5.1 and 7. Run `tests\Test-MonitorWorker.ps1` in both versions after building for fake-only apply binding/diagnostics checks. For bridge integration, run `node --import tsx scripts/smoke-worker.ts` after building; it only lists monitors/rates, parses fractions, and rejects invalid operations. Set `MONITOR_TEST_PWSH` to a specific `pwsh.exe` to include it when not installed at the standard path. Run `node scripts/smoke-sdk.mjs` to exercise the production bundle against a simulated Stream Deck host, including read-only native polling, preset editing and live rendering. Tests use fake display operations; routine verification never changes live display settings.

Manual acceptance after installing:

1. Check status and matching buttons against Windows/NVIDIA readings. Change settings externally and confirm feedback updates within the next poll plus query time.
2. Apply HDR On/Off at 119.88 and 239.99 Hz. Verify Full range, depth/warnings, selected monitor layout, and unchanged peer settings.
3. Press several preset keys rapidly. Only the first display transaction should run. Check logs for its verified outcome.
4. Request an unsupported rate. Confirm restoration, an error badge/details, and other keys showing the restored actual state.
5. Disconnect/reconnect the monitor; verify unavailable/recovered status without automatic application. A name-based selection should recover even after its device ID changes. Identical names should show ambiguity until a device ID is selected.
6. Verify partial presets can match simultaneously, deleted presets need selection, and JSON backup/import survives restart.
7. Reboot/log out to check temporary refresh behavior; HDR persistence remains Windows-controlled.

Version 1 supports ordinary keys, without cycling, dials, automatic application-based switching, or VRR control. It is a local installer, not a Marketplace publication.

## License

Monitor Control is MIT licensed. The installer includes `LICENSE`, the NVIDIA attribution notice, and `THIRD-PARTY-NOTICES.txt` for bundled dependencies.

Official references: [Elgato SDK setup](https://docs.elgato.com/streamdeck/sdk/introduction/getting-started/), [global/action settings](https://docs.elgato.com/streamdeck/sdk/guides/settings/), [key feedback and custom overrides](https://docs.elgato.com/streamdeck/sdk/guides/keys/), [packaging](https://docs.elgato.com/streamdeck/sdk/introduction/distribution/).

# Monitor Control

Control a Windows monitor's HDR state, refresh rate, and NVIDIA output color range from PowerShell or an Elgato Stream Deck. Preset buttons highlight when their settings match the monitor, and an optional status tile displays live readings.

## Features

- Select an active monitor by friendly name or device ID.
- Enable/disable HDR and request integer, decimal, or exact fractional refresh rates.
- List exposed rates at the current resolution and scan mode.
- Enforce Full/Limited range on supported NVIDIA outputs, preferring 10-bit HDR and 8-bit SDR.
- Verify results and attempt restoration after failures or unintended configuration changes.
- Use shared Stream Deck presets with live matching, depth warnings, JSON backup/import, and a separate status key.

Refresh changes are temporary. HDR and NVIDIA color-policy persistence are controlled by Windows and the driver. Color depth is best effort; a mismatch produces a warning. Custom refresh requests must be supported by Windows; this project does not create custom timings.

## Requirements

| Component | Requirement |
| --- | --- |
| Monitor control | Windows 11, 64-bit PowerShell 5.1 or 7, local desktop session |
| HDR | HDR-capable display and Windows/driver support |
| Full/Limited range control | Supported NVIDIA output and the installed NVAPI driver library |
| Stream Deck plugin | Stream Deck 7.5 or later; ordinary keys |
| Building from source | Node.js 24 or later and pnpm 11.25.0 |

The scripts need no external PowerShell modules. The installed plugin bundles its backend and JavaScript dependencies and uses Stream Deck's Node.js runtime. Administrator elevation is normally unnecessary.

## Stream Deck quick start

1. Download `pw.vodes.monitorcontrol.streamDeckPlugin` from this repository's **Releases**, or build it locally.
2. Double-click the installer and accept Stream Deck's installation dialog.
3. Drag **Monitor Control → Apply Preset** onto a key. Open **Manage shared presets**, select the monitor and desired settings, and save. Choose that preset for the button.
4. Optionally add **Monitor Status** and choose a monitor. Pressing it only refreshes its readings.

Keep the button's default image and leave its custom title blank for live feedback. Editing a shared preset updates every button referencing it. Partial presets can match simultaneously.

New presets default to **Full** range. Choose **Keep** when NVIDIA range control is unavailable or when range should remain driver-selected. Saving, importing, startup, wake, and reconnect never apply a preset automatically.

Status is polled every two seconds while keys or their settings panel are visible. Further preset presses are ignored during a display transaction. Diagnostics show failure details and separate Windows/NVIDIA depth readings.

See the [plugin guide](streamdeck-monitor-control/README.md) for feedback states, backup/import, and manual acceptance checks.

## PowerShell quick start

The standalone script only needs `Set-Monitor.ps1`. Run in 64-bit PowerShell:

```powershell
# List active monitors and exposed rates.
.\Set-Monitor.ps1 -ListMonitors
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -ListRefreshRates

# Apply settings or read current status.
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr On -RefreshRate 120
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr Off -RefreshRate '60000/1001'
.\Set-Monitor.ps1 -MonitorName 'Monitor Name'

# Change only range, or preview an action.
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -ColorRange Full
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr Off -WhatIf
```

Names match exactly, ignoring case. Use `-MonitorId` instead of `-MonitorName` to distinguish identical models. HDR and refresh are independently optional. Use a decimal dot such as `59.94`, or an exact fraction such as `60000/1001`.

HDR/rate actions default to Full range on supported NVIDIA outputs. `-ColorRange Keep` skips NVIDIA range/depth writes; `-NoNvidiaApi` disables NVIDIA queries and control. Explicit Full/Limited requests fail before changes if NVIDIA support is unavailable.

`-LogPath '.\monitor.log'` appends results and diagnostics. Successful commands return structured objects; failed commands use a nonzero exit code. Individual refresh changes in duplicate/mirror mode are rejected.

See the [script and API reference](docs/monitor-control.md) for output fields and compatibility details.

## Limitations and diagnostics

- Windows Dynamic Refresh Rate differs from Adaptive-Sync, FreeSync, and G-SYNC. VRR activity remains unknown where it cannot be measured reliably; this project does not control VRR.
- Required mode/color changes can briefly blank other outputs even when their settings are preserved. Matching presets skip unnecessary setters.
- Full range is verified after an action; later driver, application, or Windows changes can replace it. Monitor OSD settings must agree with the signal.
- Plugin monitor selections default to friendly names, matched exactly without regard to case. Device ID entries are available for identical names; ambiguous names cannot apply presets. Names survive device ID changes after driver updates. Existing ID-based presets keep their selection; edit their monitor to the recommended name entry to switch.

Plugin logs: `%LOCALAPPDATA%\MonitorControlStreamDeck\logs`. `monitor-actions.log` records transactions and restoration; `plugin.log` records worker/editor errors. Standalone logs use `-LogPath`. Generated files and local logs are excluded from Git.

## Build and test

From the repository root:

```powershell
cd streamdeck-monitor-control
pnpm install --frozen-lockfile
pnpm check
pnpm test
pnpm build
pnpm validate
pnpm run package
```

The installer is written to `streamdeck-monitor-control/dist/pw.vodes.monitorcontrol.streamDeckPlugin`. Build bundles the canonical root script, project license, NVIDIA attribution, and dependency notices. Rebuild and reinstall after backend changes.

Run these suites from the root in both PowerShell 5.1 and 7, after building:

```powershell
.\tests\Test-MonitorControl.ps1
.\streamdeck-monitor-control\tests\Test-MonitorWorker.ps1
```

Tests simulate setting changes without changing real displays. Read-only native enumeration and the simulated Stream Deck host check require a local Windows desktop; see the [plugin guide](streamdeck-monitor-control/README.md). Hosted CI runs fake-only checks because it has no physical monitors. Actual HDR/rate/range acceptance and physical key use require manual hardware checks.

## GitHub builds and releases

The [workflow](.github/workflows/build-release.yml) builds on pushes, pull requests, and manual dispatch. It installs locked dependencies, checks types, runs JavaScript and both PowerShell fake-only suites, builds/validates the plugin, and uploads the installer plus `SHA256SUMS.txt` as an artifact.

To publish a release:

1. Set `version` in `streamdeck-monitor-control/package.json`, for example `1.0.1`.
2. Set `Version` in `streamdeck-monitor-control/assets/manifest.json` to the corresponding four-part version, for example `1.0.1.0`.
3. Commit the changes, then create and push the matching tag:

```powershell
git tag v1.0.1
git push origin v1.0.1
```

Tags use `vMAJOR.MINOR.PATCH`; mismatched versions fail the build. After a successful tag build, a separate job publishes the installer and checksum with generated release notes using the built-in `GITHUB_TOKEN`. No personal token is needed. Manual dispatch builds an artifact without publishing. Existing releases are not automatically overwritten.

## Disclaimer

This was mostly made with AI (GPT-6.1-Sol) but I use it personally and it's thoroughly tested.
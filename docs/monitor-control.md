# Monitor control script and API reference

For live preset highlighting and a monitor status tile, use the [Monitor Control plugin](../streamdeck-monitor-control/README.md). Its installer is `streamdeck-monitor-control/dist/pw.vodes.monitorcontrol.streamDeckPlugin`; it bundles the tested script and requires Stream Deck 7.5+ on Windows 11.

`Set-Monitor.ps1` works by itself. Run it in **64-bit Windows PowerShell 5.1 or PowerShell 7**, in your local Windows desktop session. No modules, SDK installation, or administrator elevation are normally needed. NVIDIA support uses the installed driver's `System32\nvapi64.dll`; nothing is downloaded. After updating the script, start a fresh PowerShell session because embedded C# types are cached for the lifetime of a session.

## Find your monitor

```powershell
.\Set-Monitor.ps1 -ListMonitors |
    Format-Table MonitorName, RefreshRateHz, HdrEnabled, ColorEncoding, ColorRange, BitsPerColorChannel
```

Names are exact matches, ignoring case. For identical monitor names, obtain and copy the full `MonitorId`:

```powershell
.\Set-Monitor.ps1 -ListMonitors | Format-List MonitorName, MonitorId
.\Set-Monitor.ps1 -MonitorId 'paste the complete ID here'
```

The ID is the monitor device-interface path. It is useful for distinguishing identical models, but may change after changing the connection or reinstalling a driver. Only active desktop displays are selectable.

## HDR and refresh rate

```powershell
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -ListRefreshRates |
    Format-Table Width, Height, RefreshRateHz, RefreshRateFraction

.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr On -RefreshRate 120
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr Off -RefreshRate 144
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -RefreshRate 59.94
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -RefreshRate '60000/1001'
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr Off
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr On -RefreshRate 120 -WhatIf
```

Use a decimal **dot**, irrespective of your Windows locale. `59.94` is the exact requested decimal; `60000/1001` is approximately 59.94005994 Hz. Use the fraction column to request a listed mode precisely. Decimal input supports up to nine significant decimal places, subject to the Windows 32-bit numerator/denominator limit.

DXGI lists exposed modes at the current physical signal resolution and scan mode. Available modes can depend on HDR, cable bandwidth, and driver configuration. An empty list does not establish that all rates are unsupported. You can request an unlisted rate, but **Windows must validate it**. This script does not create custom timings or overclock a monitor, and it does not silently substitute a nearest rate. A verified actual rate within 0.01 Hz counts as success.

Resolution, layout, rotation, scaling, and other monitors are checked after a change. Individual refresh changes in duplicate/mirror mode are rejected; use an extended desktop. Requesting a fixed rate disables Windows Dynamic Refresh Rate on that monitor. This does not control VRR/FreeSync/G-SYNC.

`WindowsDynamicRefreshRate` is Windows' desktop refresh boosting feature. The older `DynamicRefreshRate` field is retained as an alias of that same value for compatibility. **Neither reports G-SYNC or Adaptive-Sync.** `VariableRefreshRateSupported` now comes from NVIDIA's **generic monitor capability** query, rather than its current-mode “VRR possible” flag. Valid capability data reports true/false; unavailable or invalid data is null, with `VariableRefreshRateSupportUnavailableReason` explaining why. `VariableRefreshRateSource` identifies the capability source.

The earlier implementation labelled a raw current-mode flag as `VariableRefreshRateEnabled`/`Active`, which could misleadingly suggest G-SYNC was turned off. **Those fields now remain null (unknown)**, as do `VariableRefreshRateRequested` and `DisplayInVariableRefreshRateMode`. These legacy fields are retained for compatibility. The available queries do not reliably establish the per-monitor NVIDIA Control Panel checkbox or verify actual VRR activity in a game; `VariableRefreshRateUnavailableReason` states that limitation.

For diagnostics, `NvidiaReportedVrrModeActive` reports the separate `GetVRRInfo` bit-0 reading, and `NvidiaVrrRawFlags` preserves the entire hexadecimal flags word. A false mode reading is not proof that G-SYNC is configured off. Older SDKs defined only bit 0; newer SDKs name additional bits without changing the packet version, so the script does not interpret the remaining bits as reliable booleans across drivers. `NvidiaVrrSource`, `NvidiaVrrUnavailableReason`, and `NvidiaVrrReportingNote` describe the raw reading and its limits. These are read-only queries. The script does not enable or disable G-SYNC or measure instantaneous panel refresh. See [NVIDIA's monitor-capability and VRR definitions](https://github.com/NVIDIA/nvapi/blob/main/nvapi.h).

`ColorRange` refers to **Full/Limited output quantization range**, separately from HDR, RGB versus YCbCr encoding, and bits per channel. An unavailable reading is `Unknown`, never guessed from the encoding or from a DXGI color-space name.

## NVIDIA output range

For a reliably mapped NVIDIA output, HDR/refresh actions now **default to Full range**, preferring **10-bit HDR or 8-bit SDR**. After Windows finishes changing modes, the script validates and applies range and output depth together with NVIDIA's user color-selection policy, then checks NVIDIA and Windows readback. It requests the preferred depth even when HDR is already enabled at 8 bits. It also pins Full when the initial reading was already Full. Format and colorimetry remain unchanged; the script does not force RGB or change desktop/compositor depth. A range-only action requests the existing output depth. `ColorRangePolicy` reports `User` or `BestQuality` (driver/OS automatic selection). `ColorRangeEnforcedByAction` is true only in a successful action's returned status when that action set or confirmed its requested range; it is false for read-only queries.

NVIDIA's user policy covers the complete color configuration, not just range. The earlier range implementation copied whatever depth Windows had selected, so it could pin a transient 8-bit HDR output. The updated action explicitly prefers 10-bit HDR before falling back. `PreferredBitsPerColorChannel` records the preference for the action; `ColorDepthFallbackReason` explains validation rejection or an unconfirmed depth. If that preference is rejected, the script validates Full at the mode's existing depth and warns about the mismatch. It never falls back to Limited to obtain 10 bits. If neither requested-range combination works, the action fails and attempts restoration.

**Output depth is best effort and a mismatch is a warning**, even when NVIDIA accepted the request in validation. The script gives the depth readings up to five seconds to settle; if HDR, refresh, and range are verified, a depth-only mismatch leaves those settings applied instead of rolling them back. `BitsPerColorChannel` retains the Windows reading for compatibility, also exposed as `WindowsBitsPerColorChannel`. `NvidiaOutputBitsPerColorChannel` reports the NVIDIA output-color reading independently. `ColorDepthReadingsAgree` is true/false when both readings are available, otherwise null. A disagreement is reported instead of picking whichever reading matches the request. Actual API errors, HDR/rate/range failures, and unintended topology/encoding/other-monitor changes still trigger restoration. Timeout errors include the requested settings and the last observed HDR, path/physical rate, range, policy, and depth values **before restoration**.

Turning HDR off can initially leave a user-pinned 10-bit output in Windows' WCG Advanced Color mode. WCG is an SDR mode with advanced color management; applying the action's 8-bit SDR preference can subsequently change the reported mode to SDR. The script permits an SDR/WCG transition on the selected monitor only when HDR is conclusively off on both sides and an intended output-depth action actually changed the NVIDIA depth reading. It reports the transition through `ColorModeTransitionNote` and a warning. Encoding, NVIDIA colorimetry/desktop depth, HDR state, unknown modes, and other monitors remain protected by the existing checks. Range-only actions do not authorize a color-mode transition. See [Microsoft's Advanced Color kinds](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range).

Action logs include `DIAGNOSTIC` entries for the initial settings, HDR/rate changes, NVIDIA color passes, timing recovery, final readback, and failure/restoration snapshots. These record Windows color mode and encoding alongside HDR, range, refresh, and both depth readings. Color-state guard failures also include before/after values in the error itself. Diagnostics are buffered during the transaction and written after it completes or fails; the user log is appended to, not replaced.

A NVIDIA color change can reset a temporary Windows refresh request to the driver's saved rate. The action checks timing after the color change and reapplies an explicit refresh request, preserving its exact fraction. HDR-only and range-only actions restore the timing snapshot, including Windows DRR, if the NVIDIA change altered it. If timing recovery changes the range again, the script allows one further range repair at the current output depth, then restores timing again. It does not repeatedly retry the preferred depth. If timing and range still conflict after two color passes, the action fails and attempts restoration. Restoration also checks timing after restoring NVIDIA color settings.

An already-matching HDR/rate/range/depth preset skips refresh and NVIDIA color setters. That avoids unnecessary mode changes when a Stream Deck button is pressed again. NVIDIA's BestQuality policy still needs a change to User to pin Full; a different requested output depth/range still needs a driver call. Necessary mode or NVIDIA color changes can briefly blank other outputs even when their settings stay the same; these APIs expose no guarantee against that driver behavior. `-ColorRange Keep` avoids NVIDIA color writes, at the cost of leaving the existing range/depth policy in place. Read-only queries do not call setters.

```powershell
# Set and verify Full without changing HDR or refresh.
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -ColorRange Full

# Full plus 10-bit HDR is preferred on supported NVIDIA outputs.
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr On -RefreshRate 120

# Explicit overrides for a display that needs Limited, or driver-selected behavior.
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -ColorRange Limited
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr Off -ColorRange Keep

# Read status without any NVIDIA API calls.
.\Set-Monitor.ps1 -ListMonitors -NoNvidiaApi

# Inspect monitor capability, unknown configured state, and raw driver mode data.
.\Set-Monitor.ps1 -ListMonitors |
    Format-List MonitorName, WindowsDynamicRefreshRate, VariableRefreshRate*, NvidiaReportedVrrModeActive, NvidiaVrr*, DisplayInVariableRefreshRateMode
```

Windows can briefly choose Limited during a mode transition: these APIs cannot make the Windows mode change and NVIDIA range selection atomic. Full is reapplied afterward. If Full is unsupported, the setter fails, or readback cannot verify the requested range/user policy, the action fails and attempts to restore the original HDR, timing, and NVIDIA color settings (including the original range and automatic/user policy). A failed action may therefore restore a previously Limited range. Restoration failures are reported explicitly. A successful action verifies the result at that moment; later applications, driver resets, or Windows changes can replace it. NVIDIA color policy may persist across sessions independently of the temporary refresh request. Monitor OSD range settings remain under your control and should agree with the signal.

If NVIDIA identifies the output but its range cannot be read/restored reliably, default Full actions fail before changing settings. On non-NVIDIA outputs, when NVIDIA mapping/APIs are unavailable, or with `-NoNvidiaApi`, ordinary Windows HDR/refresh changes remain available **with a warning that Full could not be enforced**. Explicit `-ColorRange Full`/`Limited` always requires NVIDIA support and fails before changes if unavailable. `-ColorRange Keep` opts out of NVIDIA range/depth changes and may leave Limited or a previously pinned depth; it does not reset NVIDIA's user policy to automatic. Used alone, it just returns status. Duplicate, Mosaic, and Surround outputs are excluded from individual NVIDIA range control to avoid targeting the wrong physical monitor.

Refresh-rate changes are **not saved** to the Windows display database. Windows, applications, reconnecting a monitor, signing out, or restarting can replace a temporary mode. HDR persistence is controlled by Windows and is not made temporary by this script. Display transitions may briefly blank the monitor.

Windows reports the actual **bits per color channel**, which differs from the desktop's “32 bits per pixel.” The script expects 8 with HDR off and 10 with HDR on, and warns on a mismatch or an unavailable reading. With NVIDIA range control active, HDR/rate actions request that preferred output depth alongside the requested range; range-only actions preserve depth. When NVIDIA control is unavailable or skipped, Windows/the driver selects output depth. HDR may still use 8-bit output with dithering if the preferred combination is rejected.

The newer HDR API distinguishes HDR from wide-color SDR. The compatibility API provides a less precise inference, labeled in `ColorMode`; if it reports enforced wide color, HDR changes are refused. A requested HDR state is verified as both user-enabled and active.

`-WhatIf` reads the current monitor and parses the request, but does not toggle HDR, validate a hypothetical HDR combination, or call a display-setting API. No countdown or confirmation prompt is used during normal execution. Failures attempt to restore the original configuration and explicitly report if restoration fails. A nonzero process exit code indicates failure.

## Validation

Run the automated checks without changing any displays:

```powershell
.\tests\Test-MonitorControl.ps1
```

The suite compiles the embedded interop and tests native/NVAPI structure layouts, rational parsing, selection ambiguity, configuration generation, raw VRR bit flags versus monitor capability and unknown configured state, output-depth enumeration, preferred-depth validation/fallback, user-pinned 8-bit HDR recovery, delayed depth readback, NVIDIA resetting a requested 120 Hz to 239.99 Hz, fractional timing recovery, bounded timing/range conflicts, range policy/encoding preservation, transaction ordering, simulated failures/restoration. Actual HDR, mode, and color setter acceptance require hardware checks.

For manual testing, first record current settings. On the intended monitor, test HDR off/on, a listed whole-number rate, and a listed fraction. Confirm resolution/layout and other monitors remain unchanged. Confirm `ColorRange` is Full and `ColorRangePolicy` is User after an NVIDIA action, including a mode that previously selected Limited; compare the NVIDIA Control Panel's range/depth readings. Check 10-bit HDR and 8-bit SDR when supported, then rerun the HDR command with HDR already enabled at 8 bits to check whether the preferred depth applies. Repeat an already-matching preset to check that no extra modeset occurs. A rejected or unconfirmed preferred depth must leave verified HDR/rate/range applied and report a warning; an unsupported rate/range must report failure, restoring preceding changes. Test plugin presets from Stream Deck and inspect their logs. Verify that a subsequent Windows mode restore/restart returns to the saved refresh rate; HDR and NVIDIA policy may remain independently. Compare the VRR flags on the desktop and while a known VRR game runs. No live display changes are part of the automated suite.

API references: [Windows display definitions](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/wingdi.h), [SetDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig), and [DXGI fractional mode enumeration](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutput1-getdisplaymodelist1).

NVIDIA references: [public NVAPI SDK definitions](https://github.com/NVIDIA/nvapi/blob/main/nvapi.h) and [interface IDs](https://github.com/NVIDIA/nvapi/blob/main/nvapi_interface.h). SDK attribution is in `NVIDIA-NVAPI-NOTICE.md`.

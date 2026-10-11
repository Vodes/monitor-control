# Validation record — 2026-10-11

- TypeScript strict checking passed.
- All 22 plugin tests passed: matching/tolerance, partial presets, unknown readings, depth warnings, library validation, property inspector save revision/IDs, rational rate picker, global busy handling, polling coalescing, rollback readback, worker timeout/crash handling, protocol errors, and argument separation.
- Existing production C# / fake backend suite passed all **81 checks in PowerShell 5.1** and **81 in PowerShell 7**, without calling display setters. This includes topology preservation, supported/unsupported requests, API failures, NVIDIA depth/range recovery, and rollback/restoration failures.
- Worker fake-only apply binding, warning/status separation, restoration reports, and invalid-operation/no-op checks passed in both PowerShell versions.
- Packaged worker read-only native enumeration passed in both versions. Main monitor: MPG 322U X24, HDR, 239.99 Hz, Windows/NVIDIA 10-bit, Full; 9 exposed rates. Peer: OMEN 34c, SDR, 120 Hz, Windows/NVIDIA 8-bit, Full; 6 rates. Decimal/fraction parsing and invalid input/monitor rejection passed.
- Production bundle connected to a simulated Stream Deck host: SDK registration, native polling, preset save/validation/conflict/delete, stable action references, preset/status title updates, and fractional mode list all passed.
- Elgato CLI validation passed; installer packaged with the bundled canonical script, worker, UI, SDK, native artwork, NVIDIA notice, and dependency license notices. Logs and source maps are excluded.

No routine check applied settings to a real monitor. Installation in the actual Stream Deck app, physical key interaction, and display switching remain manual acceptance checks; see README.md. The SDK harness persisted settings only inside its simulated host, not in the user's Stream Deck profiles.

## Repository and release packaging update

- All 24 plugin tests passed, including new manifest/package/tag version checks; TypeScript checking passed.
- GitHub Actions workflow syntax and expressions passed actionlint v1.7.12. A hosted run awaits creation/push of the GitHub repository.
- The rebuilt installer passed Elgato validation and contains 19 files, including the project MIT `LICENSE`. Bundled license equality, SHA-256 checksum, root documentation links, and Git ignore rules were verified locally.

## Friendly-name selection update

- Strict TypeScript checking and all 29 plugin tests passed. New coverage checks name matching, changed device IDs, duplicate-name refusal, legacy ID libraries, name-only application requests, preferred picker entries, and stale rate replies.
- Worker fake-only tests passed in PowerShell 5.1 and 7, including name/ID parameter binding, name-based rates, and invalid/mixed selectors. The existing native command handler still resolves the selector again after taking the display mutex.
- Read-only native enumeration passed in both PowerShell versions; rates returned by name and ID agreed. Main display remained HDR at 239.99 Hz / 10-bit / Full, and the peer remained SDR at 120 Hz / 8-bit / Full.
- The production SDK harness passed using a name-based saved preset, name-based status tile, and name-based rate picker. No real display setter or real Stream Deck profile write was issued.

## Project scope cleanup

- Removed the launch-helper implementation, its five obsolete test groups, related setup documentation, and unused ignore rules.
- The remaining standalone/backend suite passed all 76 checks in both PowerShell 5.1 and 7 without calling display setters.
- Rebuilt, validated, and packaged the plugin with the updated documentation and checksum.

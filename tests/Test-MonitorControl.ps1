#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# Add-Type names are cached by PowerShell. If the user already ran the main
# script, isolate compilation of the production source + fake backend.
if ('MonitorControl.NativeBackend' -as [type]) {
    $testHost = if ($PSVersionTable.PSVersion.Major -ge 6) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    & $testHost -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'The isolated test process failed.' }
    return
}
. (Join-Path $root 'Set-Monitor.ps1')

# Compile the production C# with a fake backend in the same assembly. No native
# setter is called anywhere in this suite; no Pester/module installation is needed.
$testSource = @'
namespace MonitorControl.Tests {
    public sealed class FakeBackend : IDisplayBackend, IColorRangeBackend {
        public DisplayState Current;
        public readonly System.Collections.Generic.List<string> Events = new System.Collections.Generic.List<string>();
        public bool ResetRateOnHdr, ChangePeer, FailHdrOnce, FailRestore, ReturnWrongRate;
        public int FailRateCall, RateCalls;
        public uint? DepthOverride;
        public bool LimitedOnModeChange, IgnoreRangeOnce, FailColorRestore, ChangePeerRange, ChangeDepthOnRange, FailRangeOnce, IgnoreUserPolicy, ChangeColorimetryOnRange;
        public bool HonorUserDepth, EightBitOnHdr, RejectPreferredDepth, IgnoreDepthOnce;
        public bool ResetRateOnColor, ResetRateOnColorRestore, LowerDepthOnRateRecovery;
        public bool WcgOnSdrAtHighDepth, ChangeWindowsEncodingOnRange;
        public string ForcedWindowsModeOnRange;
        public int LimitedRateChanges;
        bool colorResetPending;
        public int DepthReadDelay;
        uint? pendingDepth;
        public FakeBackend() { Current = MakeState(); }
        public static DisplayState MakeState() {
            var monitors = new MonitorInfo[2]; var paths = new DisplayPath[2]; var modes = new DisplayMode[4];
            for (int i = 0; i < 2; i++) {
                monitors[i] = new MonitorInfo { MonitorName = i == 0 ? "Test Panel" : "Other Panel", MonitorId = "id" + i,
                    DisplayName = "DISPLAY" + i, Width = 1920, Height = 1080, SignalWidth = 1920, SignalHeight = 1080,
                    X = i * 1920, Y = 0, Rotation = 1, Scaling = 1, ScanLine = 1, SourceKey = "source" + i, PathIndex = i,
                    Refresh = new Rate(60, 1), PhysicalRefresh = new Rate(60, 1), HdrSupported = true, HdrEnabled = false,
                    HdrActive = false, ColorMode = "SDR", ColorEncoding = "RGB", BitsPerColorChannel = 8, HdrApi = "HdrState",
                    ColorRange = "Full", ColorRangeSource = "NVIDIA NVAPI", ColorRangeUnavailableReason = null,
                    NvidiaColorState = new NvidiaColor { Version = 0x50018, Size = 24, Command = 1, Format = 0, Colorimetry = 0, Range = 0, Bpc = 2, Policy = 1, DesktopDepth = 1 } };
                paths[i] = new DisplayPath { Flags = 9, Source = new PathSource { Id = (uint)i, ModeIndex = ((uint)i * 2) << 16 },
                    Target = new PathTarget { Id = (uint)i, ModeIndex = (((uint)i * 2 + 1) << 16) | 0x1234,
                        Refresh = new Rate(60, 1), Rotation = 1, Scaling = 1, ScanLine = 1, Available = 1 } };
                modes[i * 2] = new DisplayMode { Type = 1, Id = (uint)i, Source = new SourceMode { Width = 1920, Height = 1080, Position = new Point { X = i * 1920 } } };
                modes[i * 2 + 1] = new DisplayMode { Type = 2, Id = (uint)i, Target = new Signal { Active = new Region { Width = 1920, Height = 1080 }, VSync = new Rate(60, 1), ScanLine = 1 } };
            }
            return new DisplayState { Monitors = monitors, Paths = paths, Modes = modes, QueryFlags = 0x52 };
        }
        public DisplayState Capture() {
            if (pendingDepth.HasValue && DepthReadDelay-- <= 0) { Current.Monitors[0].BitsPerColorChannel = pendingDepth; pendingDepth = null; }
            return Current.Copy();
        }
        public void Wait(int ms) { }
        public void SetHdr(string id, bool enabled) {
            Events.Add("HDR:" + enabled); MonitorInfo m = Selection.ById(Current, id);
            m.HdrEnabled = enabled; m.HdrActive = enabled; m.ColorMode = enabled ? "HDR" : "SDR";
            bool pinnedDepth = HonorUserDepth && m.NvidiaColorState.HasValue && m.NvidiaColorState.Value.Policy == 0;
            m.BitsPerColorChannel = DepthOverride ?? (pinnedDepth ? NvidiaApi.BitsFromBpc(m.NvidiaColorState.Value.Bpc) : enabled && !EightBitOnHdr ? 10u : 8u);
            if (m.NvidiaColorState.HasValue) { var color = m.NvidiaColorState.Value; if (!pinnedDepth) color.Bpc = enabled && !EightBitOnHdr ? 3u : 2u; color.DesktopDepth = enabled ? 5u : 1u; m.NvidiaColorState = color; }
            if (!enabled && WcgOnSdrAtHighDepth && m.BitsPerColorChannel >= 10) m.ColorMode = "WCG";
            if (LimitedOnModeChange) SetFakeColor(m, NvidiaApi.RangeRequest(m.NvidiaColorState.Value, "Limited"));
            if (enabled && ResetRateOnHdr) { m.Refresh = new Rate(60, 1); m.PhysicalRefresh = new Rate(60, 1); }
            if (FailHdrOnce) { FailHdrOnce = false; throw new System.InvalidOperationException("Simulated HDR setter failure after mutation"); }
        }
        public void SetRefresh(string id, Rate rate) {
            RateCalls++; Events.Add("RATE:" + rate.ToString());
            if (RateCalls == FailRateCall) throw new System.InvalidOperationException("Simulated mode rejection");
            MonitorInfo m = Selection.ById(Current, id);
            m.Refresh = ReturnWrongRate ? new Rate(75, 1) : rate; m.PhysicalRefresh = m.Refresh; m.DynamicRefreshRate = false;
            if (ChangePeer) Current.Monitors[1].X += 100;
            if (LimitedOnModeChange) SetFakeColor(m, NvidiaApi.RangeRequest(m.NvidiaColorState.Value, "Limited"));
            if (LimitedRateChanges > 0) { LimitedRateChanges--; SetFakeColor(m, NvidiaApi.RangeRequest(m.NvidiaColorState.Value, "Limited")); }
            if (colorResetPending && LowerDepthOnRateRecovery) {
                var color = m.NvidiaColorState.Value; color.Bpc = 2; SetFakeColor(m, color); m.BitsPerColorChannel = 8;
            }
            colorResetPending = false;
            if (ChangePeerRange) SetFakeColor(Current.Monitors[1], NvidiaApi.RangeRequest(Current.Monitors[1].NvidiaColorState.Value, "Limited"));
        }
        static void SetFakeColor(MonitorInfo m, NvidiaColor color) { m.NvidiaColorState = color; m.ColorRange = NvidiaApi.DecodeRange(color.Range); }
        public NvidiaColor SetColorRange(string id, string range, uint? preferredBits) {
            MonitorInfo m = Selection.ById(Current, id);
            var desired = NvidiaApi.RangeRequest(m.NvidiaColorState.Value, range, preferredBits);
            if (!NvidiaApi.RequiresColorSet(m.NvidiaColorState.Value, desired)) return desired;
            var request = NvidiaApi.ChooseColorRequest(m.NvidiaColorState.Value, range, preferredBits,
                candidate => !RejectPreferredDepth || candidate.Bpc == m.NvidiaColorState.Value.Bpc);
            if (!NvidiaApi.RequiresColorSet(m.NvidiaColorState.Value, request)) return request;
            Events.Add("RANGE:" + range);
            if (IgnoreRangeOnce) { IgnoreRangeOnce = false; return request; }
            var actual = request;
            if (IgnoreDepthOnce) { IgnoreDepthOnce = false; actual.Bpc = m.NvidiaColorState.Value.Bpc; }
            SetFakeColor(m, actual);
            if (DepthReadDelay > 0) pendingDepth = NvidiaApi.BitsFromBpc(actual.Bpc);
            else m.BitsPerColorChannel = NvidiaApi.BitsFromBpc(actual.Bpc);
            if (WcgOnSdrAtHighDepth && m.HdrActive == false) m.ColorMode = m.BitsPerColorChannel >= 10 ? "WCG" : "SDR";
            if (ForcedWindowsModeOnRange != null) m.ColorMode = ForcedWindowsModeOnRange;
            if (ChangeWindowsEncodingOnRange) m.ColorEncoding = "YCbCr444";
            if (IgnoreUserPolicy) { var color = m.NvidiaColorState.Value; color.Policy = 1; m.NvidiaColorState = color; }
            if (ChangeColorimetryOnRange) { var color = m.NvidiaColorState.Value; color.Colorimetry = 9; m.NvidiaColorState = color; }
            if (ChangeDepthOnRange) m.BitsPerColorChannel = 12;
            if (ResetRateOnColor) {
                m.Refresh = new Rate(239990, 1000); m.PhysicalRefresh = m.Refresh; colorResetPending = true;
            }
            if (FailRangeOnce) { FailRangeOnce = false; throw new System.InvalidOperationException("Simulated color rejection after mutation"); }
            return request;
        }
        public void RestoreColor(string id, NvidiaColor color) {
            Events.Add("COLORRESTORE:" + id);
            if (FailColorRestore) throw new System.InvalidOperationException("Simulated color restoration rejection");
            var m = Selection.ById(Current, id); SetFakeColor(m, color);
            m.BitsPerColorChannel = color.Bpc == 3 ? 10u : 8u;
            if (WcgOnSdrAtHighDepth && m.HdrActive == false) m.ColorMode = m.BitsPerColorChannel >= 10 ? "WCG" : "SDR";
            if (ResetRateOnColorRestore) { m.Refresh = new Rate(239990, 1000); m.PhysicalRefresh = m.Refresh; }
        }
        public void Restore(DisplayState state) {
            Events.Add("RESTORE");
            if (FailRestore) throw new System.InvalidOperationException("Simulated restoration rejection");
            DisplayState replacement = state.Copy();
            foreach (MonitorInfo m in replacement.Monitors) {
                MonitorInfo old = Selection.ById(Current, m.MonitorId);
                m.HdrEnabled = old.HdrEnabled; m.HdrActive = old.HdrActive;
                m.ColorMode = old.ColorMode; m.BitsPerColorChannel = old.BitsPerColorChannel;
                m.NvidiaColorState = old.NvidiaColorState; m.ColorRange = old.ColorRange;
            }
            Current = replacement;
        }
    }
    public static class Suite {
        static readonly System.Collections.Generic.List<string> passed = new System.Collections.Generic.List<string>();
        static void Assert(bool value, string message) { if (!value) throw new System.Exception(message); }
        static void Test(string name, System.Action body) { body(); passed.Add(name); }
        static string Throws(System.Action body, string expected) {
            try { body(); } catch (System.Exception e) { Assert(e.Message.Contains(expected), "Wrong failure: " + e.Message); return e.Message; }
            throw new System.Exception("Expected failure: " + expected);
        }
        public static string[] Run() {
            Test("Native structure sizes and offsets", () => NativeBackend.ValidateLayouts());
            Test("Raw VRR flags do not claim monitor support or G-SYNC enablement", () => {
                var m = new MonitorInfo(); Assert(!m.VariableRefreshRateSupported.HasValue && !m.VariableRefreshRateEnabled.HasValue, "Unavailable VRR guessed false");
                NvidiaApi.DecodeVrr(0x16, m);
                Assert(!m.VariableRefreshRateSupported.HasValue && !m.VariableRefreshRateRequested.HasValue && !m.DisplayInVariableRefreshRateMode.HasValue && !m.VariableRefreshRateEnabled.HasValue && !m.VariableRefreshRateActive.HasValue, "Raw mode flags interpreted as configured enablement");
                Assert(m.NvidiaReportedVrrModeActive == false && m.NvidiaVrrRawFlags == "0x00000016", "Raw flags lost");
                Assert(!m.WindowsDynamicRefreshRate, "VRR changed Windows DRR");
                NvidiaApi.DecodeVrr(1, m); Assert(m.NvidiaReportedVrrModeActive == true && !m.VariableRefreshRateEnabled.HasValue && !m.VariableRefreshRateSupported.HasValue, "Driver mode flag promoted to enablement/support");
                Assert(NvidiaApi.DecodeRange(0) == "Full" && NvidiaApi.DecodeRange(1) == "Limited" && NvidiaApi.DecodeRange(255) == "Unknown", "Range mapping");
            });
            Test("Monitor VRR capability is independent of current-mode flags", () => {
                var m = new MonitorInfo(); NvidiaApi.DecodeVrrCapability(true, 1, m); NvidiaApi.DecodeVrr(0, m);
                Assert(m.VariableRefreshRateSupported == true && m.NvidiaReportedVrrModeActive == false && !m.VariableRefreshRateEnabled.HasValue, "Supported monitor falsely labelled unsupported/off");
                Assert(m.VariableRefreshRateSupportUnavailableReason == null && m.VariableRefreshRateUnavailableReason.Contains("cannot be confirmed"), "Query limitations missing");
                NvidiaApi.DecodeVrrCapability(true, 0, m); Assert(m.VariableRefreshRateSupported == false, "Valid negative capability ignored");
                NvidiaApi.DecodeVrrCapability(false, 255, m); Assert(!m.VariableRefreshRateSupported.HasValue && m.VariableRefreshRateSupportUnavailableReason != null, "Invalid capability guessed");
            });
            Test("Range request preserves encoding, depth, and colorimetry while pinning user policy", () => {
                var original = new NvidiaColor { Version = 0x50018, Size = 24, Command = 1, Format = 2, Colorimetry = 9, Range = 1, Bpc = 3, Policy = 1, DesktopDepth = 5 };
                var request = NvidiaApi.RangeRequest(original, "Full");
                Assert(request.Range == 0 && request.Command == 2 && request.Policy == 0, "Range/user policy missing");
                Assert(request.Format == 2 && request.Colorimetry == 9 && request.Bpc == 3 && request.DesktopDepth == 5 && request.Version == original.Version, "Other color settings changed");
                Assert(original.Range == 1 && original.Policy == 1, "Snapshot mutated");
                Throws(() => NvidiaApi.RangeRequest(original, "Auto"), "Full or Limited");
            });
            Test("Output-depth mapping changes BPC without changing desktop HDR depth or encoding", () => {
                var original = new NvidiaColor { Version = 0x50018, Size = 24, Format = 0, Colorimetry = 8, Range = 1, Bpc = 2, Policy = 0, DesktopDepth = 0 };
                var request = NvidiaApi.RangeRequest(original, "Full", 10);
                Assert(request.Bpc == 3 && request.Format == 0 && request.Colorimetry == 8 && request.DesktopDepth == 0 && request.Range == 0, "Output versus desktop depth mixed up");
                Assert(original.Bpc == 2, "Original packet mutated");
                foreach (uint bits in new uint[] { 6, 8, 10, 12, 16 }) Assert(NvidiaApi.BitsFromBpc(NvidiaApi.RangeRequest(original, "Full", bits).Bpc) == bits, "Incorrect BPC enum");
                Assert(!NvidiaApi.BitsFromBpc(0).HasValue && !NvidiaApi.BitsFromBpc(255).HasValue, "Unknown/default BPC guessed");
                Throws(() => NvidiaApi.RangeRequest(original, "Full", 9), "Unsupported output bit depth");
            });
            Test("Color validation prefers Full plus 10 bits and falls back only to a supported Full packet", () => {
                var current = FakeBackend.MakeState().Monitors[0].NvidiaColorState.Value;
                var requests = new System.Collections.Generic.List<uint>();
                var chosen = NvidiaApi.ChooseColorRequest(current, "Full", 10, candidate => { requests.Add(candidate.Bpc); return candidate.Bpc == 2; });
                Assert(chosen.Range == 0 && chosen.Bpc == 2 && System.String.Join(",", requests) == "3,2", "Depth fallback did not retain Full");
                chosen = NvidiaApi.ChooseColorRequest(current, "Full", 10, candidate => true);
                Assert(chosen.Bpc == 3 && chosen.Range == 0, "Supported 10-bit request discarded");
                Throws(() => NvidiaApi.ChooseColorRequest(current, "Full", 10, candidate => false), "range is unsupported");
            });
            Test("HDR enable upgrades a user-pinned 8-bit output to Full plus 10 bits", () => {
                var b = new FakeBackend { HonorUserDepth = true }; var m = b.Current.Monitors[0]; var c = m.NvidiaColorState.Value; c.Policy = 0; m.NvidiaColorState = c;
                m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.HdrActive == true && m.BitsPerColorChannel == 10 && m.ColorRange == "Full" && m.NvidiaColorState.Value.Bpc == 3, "Pinned 8-bit HDR not corrected");
                Assert(m.PreferredBitsPerColorChannel == 10 && m.ColorDepthFallbackReason == null, "Incorrect depth diagnostics");
            });
            Test("Already-enabled 8-bit HDR is repaired by the same HDR/rate command", () => {
                var b = new FakeBackend { EightBitOnHdr = true }; b.SetHdr("id0", true); b.Events.Clear();
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.BitsPerColorChannel == 10 && m.HdrActive == true && m.ColorRange == "Full", "Existing HDR stayed pinned to 8 bits");
                Assert(System.String.Join(",", b.Events) == "RATE:120/1,RANGE:Full", "Toggled HDR unnecessarily");
            });
            Test("NVIDIA 10-bit Full change resetting 120 to 239.99 is corrected", () => {
                var b = new FakeBackend { EightBitOnHdr = true, ResetRateOnColor = true };
                b.SetHdr("id0", true); b.SetRefresh("id0", new Rate(120, 1)); b.Events.Clear();
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.HdrActive == true && m.RefreshRateHz == 120 && m.PhysicalRefresh.Hz == 120 && m.ColorRange == "Full" && m.BitsPerColorChannel == 10, "Logged failure was not recovered");
                Assert(System.String.Join(",", b.Events) == "RANGE:Full,RATE:120/1", "Unexpected setters or rollback");
                Assert(b.Current.Monitors[1].RefreshRateHz == 60 && b.Current.Monitors[1].BitsPerColorChannel == 8, "Peer settings changed");
            });
            Test("NVIDIA timing reset recovery retains the exact fractional request", () => {
                var b = new FakeBackend { ResetRateOnColor = true };
                var m = new Controller(b).Apply("id0", true, new Rate(60000, 1001), "AutoFull");
                Assert(m.Refresh.ToString() == "60000/1001" && m.PhysicalRefresh.ToString() == "60000/1001" && m.ColorRange == "Full", "Fraction rounded during recovery");
                Assert(!b.Events.Contains("RESTORE"), "Successful fractional recovery rolled back");
            });
            Test("Timing recovery reducing HDR depth warns without retrying NVIDIA depth", () => {
                var b = new FakeBackend { ResetRateOnColor = true, LowerDepthOnRateRecovery = true };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.RefreshRateHz == 120 && m.ColorRange == "Full" && m.HdrActive == true && m.BitsPerColorChannel == 8, "Correct mode discarded for depth downgrade");
                Assert(m.ColorDepthFallbackReason.Contains("not confirmed") && !b.Events.Contains("RESTORE"), "Depth downgrade not reported as warning");
                Assert(b.Events.FindAll(e => e == "RANGE:Full").Count == 1, "Unnecessary repeated depth changes");
            });
            Test("Range reset on first timing recovery gets one bounded range repair", () => {
                var b = new FakeBackend { ResetRateOnColor = true, LimitedRateChanges = 2 };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.RefreshRateHz == 120 && m.ColorRange == "Full" && m.NvidiaColorState.Value.Policy == 0, "Second pass did not stabilize");
                Assert(System.String.Join(",", b.Events) == "RATE:120/1,HDR:True,RANGE:Full,RATE:120/1,RANGE:Full,RATE:120/1", "Unexpected repair sequence");
            });
            Test("Second range repair preserves reduced depth instead of retrying 10 bits", () => {
                var b = new FakeBackend { ResetRateOnColor = true, LimitedRateChanges = 2, LowerDepthOnRateRecovery = true };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.RefreshRateHz == 120 && m.ColorRange == "Full" && m.HdrActive == true && m.BitsPerColorChannel == 8 && m.NvidiaOutputBitsPerColorChannel == 8, "Range repair retried incompatible preferred depth");
                Assert(m.ColorDepthFallbackReason.Contains("did not retain the preferred 10-bit") && !b.Events.Contains("RESTORE"), "Reduced depth was not reported as best effort");
                Assert(b.Events.FindAll(e => e == "RANGE:Full").Count == 2, "Unexpected color retry count");
            });
            Test("Conflicting timing and range fail after two color passes and restore", () => {
                var b = new FakeBackend { ResetRateOnColor = true, LimitedOnModeChange = true };
                Throws(() => new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull"), "did not stabilize after two color passes");
                Assert(b.Events.FindAll(e => e == "RANGE:Full").Count == 2, "Unbounded color retry");
                var m = b.Current.Monitors[0];
                Assert(m.HdrActive == false && m.RefreshRateHz == 60 && m.ColorRange == "Full" && m.NvidiaColorState.Value.Policy == 1, "Original settings not restored");
            });
            Test("HDR-only NVIDIA timing reset preserves unrequested refresh and DRR", () => {
                var b = new FakeBackend { ResetRateOnColor = true }; b.Current.Monitors[0].DynamicRefreshRate = true;
                var m = new Controller(b).Apply("id0", true, null, "AutoFull");
                Assert(m.HdrActive == true && m.RefreshRateHz == 60 && m.DynamicRefreshRate && m.ColorRange == "Full", "Unrequested timing or DRR lost");
                Assert(System.String.Join(",", b.Events) == "HDR:True,RANGE:Full,RESTORE", "Unexpected fixed-rate setter");
            });
            Test("Range-only NVIDIA timing reset preserves HDR and depth", () => {
                var b = new FakeBackend { ResetRateOnColor = true };
                var m = new Controller(b).Apply("id0", null, null, "Full");
                Assert(m.HdrActive == false && m.RefreshRateHz == 60 && m.BitsPerColorChannel == 8 && m.ColorRange == "Full" && m.NvidiaColorState.Value.Policy == 0, "Range-only altered mode");
            });
            Test("Failed rate recovery restores timing after NVIDIA color restoration", () => {
                var b = new FakeBackend { ResetRateOnColor = true, ResetRateOnColorRestore = true, FailRateCall = 2 };
                Throws(() => new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull"), "Previous settings restored");
                var m = b.Current.Monitors[0];
                Assert(m.RefreshRateHz == 60 && m.HdrActive == false && m.ColorRange == "Full" && m.NvidiaColorState.Value.Policy == 1, "Restoring NVIDIA color reset saved timing");
                Assert(b.Events[b.Events.Count - 1] == "RESTORE", "Missing post-color timing restoration");
            });
            Test("HDR disable upgrades policy to the desired 8-bit SDR output", () => {
                var b = new FakeBackend(); b.SetHdr("id0", true); var c = b.Current.Monitors[0].NvidiaColorState.Value; c.Policy = 0; b.Current.Monitors[0].NvidiaColorState = c; b.HonorUserDepth = true;
                var m = new Controller(b).Apply("id0", false, null, "AutoFull");
                Assert(m.HdrActive == false && m.BitsPerColorChannel == 8 && m.NvidiaColorState.Value.Bpc == 2 && m.PreferredBitsPerColorChannel == 8, "SDR retained 10-bit user pin");
            });
            Test("HDR off at 239.99 permits WCG to SDR while switching pinned 10-bit to 8-bit", () => {
                var b = new FakeBackend { WcgOnSdrAtHighDepth = true };
                b.SetHdr("id0", true); b.SetRefresh("id0", new Rate(23999, 100));
                var c = b.Current.Monitors[0].NvidiaColorState.Value; c.Policy = 0; b.Current.Monitors[0].NvidiaColorState = c;
                b.HonorUserDepth = true; b.Events.Clear(); var controller = new Controller(b);
                var m = controller.Apply("id0", false, new Rate(23999, 100), "AutoFull");
                Assert(m.HdrEnabled == false && m.HdrActive == false && m.ColorMode == "SDR" && m.ColorEncoding == "RGB" && m.BitsPerColorChannel == 8 && m.NvidiaOutputBitsPerColorChannel == 8 && m.ColorRange == "Full" && m.RefreshRateHz == 239.99, "Expected SDR depth/mode transition failed");
                Assert(System.String.Join(",", b.Events) == "HDR:False,RANGE:Full", "Already matching rate reapplied or mode rolled back");
                Assert(m.ColorModeTransitionNote.Contains("WCG to SDR") && controller.Diagnostics.Exists(e => e.Contains("After HDR off") && e.Contains("Windows color mode=WCG")) && controller.Diagnostics.Exists(e => e.Contains("After NVIDIA color pass") && e.Contains("Windows color mode=SDR")), "Before/after mode transition not recorded");
            });
            Test("HDR-only off preserves 239.99 through the SDR depth/mode transition", () => {
                var b = new FakeBackend { WcgOnSdrAtHighDepth = true };
                b.SetHdr("id0", true); b.SetRefresh("id0", new Rate(23999, 100));
                var c = b.Current.Monitors[0].NvidiaColorState.Value; c.Policy = 0; b.Current.Monitors[0].NvidiaColorState = c; b.HonorUserDepth = true;
                var m = new Controller(b).Apply("id0", false, null, "AutoFull");
                Assert(m.RefreshRateHz == 239.99 && m.HdrActive == false && m.ColorMode == "SDR" && m.BitsPerColorChannel == 8, "Omitted rate was not preserved");
            });
            Test("Rate-only SDR action permits the intended 10-bit WCG to 8-bit SDR transition", () => {
                var b = new FakeBackend { WcgOnSdrAtHighDepth = true }; var m = b.Current.Monitors[0];
                var c = m.NvidiaColorState.Value; c.Bpc = 3; c.Policy = 0; m.NvidiaColorState = c; m.BitsPerColorChannel = 10; m.ColorMode = "WCG";
                m = new Controller(b).Apply("id0", null, new Rate(23999, 100), "AutoFull");
                Assert(m.HdrActive == false && m.HdrEnabled == false && m.ColorMode == "SDR" && m.BitsPerColorChannel == 8 && m.RefreshRateHz == 239.99 && m.ColorModeTransitionNote != null, "Intentional SDR mode change treated as HDR change");
            });
            Test("Range-only action still rejects an unsolicited WCG to SDR mode change", () => {
                var b = new FakeBackend { ForcedWindowsModeOnRange = "SDR" }; var m = b.Current.Monitors[0];
                var c = m.NvidiaColorState.Value; c.Bpc = 3; m.NvidiaColorState = c; m.BitsPerColorChannel = 10; m.ColorMode = "WCG";
                string error = Throws(() => new Controller(b).Apply("id0", null, null, "Full"), "unexpectedly changed Windows encoding, color mode, or HDR state");
                Assert(error.Contains("Before NVIDIA color:") && error.Contains("Windows color mode=WCG") && error.Contains("Windows color mode=SDR"), "Guard failure omitted differing fields");
            });
            Test("SDR mode change without an actual requested depth change is still rejected", () => {
                var b = new FakeBackend { ForcedWindowsModeOnRange = "SDR", RejectPreferredDepth = true }; var m = b.Current.Monitors[0];
                var c = m.NvidiaColorState.Value; c.Bpc = 3; m.NvidiaColorState = c; m.BitsPerColorChannel = 10; m.ColorMode = "WCG";
                Throws(() => new Controller(b).Apply("id0", false, new Rate(23999, 100), "Full"), "unexpectedly changed Windows encoding, color mode, or HDR state");
            });
            Test("Intended SDR depth/mode change never excuses an encoding change", () => {
                var b = new FakeBackend { WcgOnSdrAtHighDepth = true, ChangeWindowsEncodingOnRange = true };
                b.SetHdr("id0", true); var c = b.Current.Monitors[0].NvidiaColorState.Value; c.Policy = 0; b.Current.Monitors[0].NvidiaColorState = c; b.HonorUserDepth = true;
                var controller = new Controller(b);
                string error = Throws(() => controller.Apply("id0", false, new Rate(23999, 100), "AutoFull"), "unexpectedly changed Windows encoding, color mode, or HDR state");
                Assert(error.Contains("encoding=RGB") && error.Contains("encoding=YCbCr444") && error.Contains("Windows color mode=WCG") && error.Contains("Windows color mode=SDR"), "Encoding failure not diagnosable");
                Assert(controller.Diagnostics.Exists(e => e.Contains("Failure before restoration") && e.Contains("encoding=YCbCr444")), "Failure state not recorded before rollback");
                Assert(b.Current.Monitors[0].HdrActive == true && b.Current.Monitors[0].ColorEncoding == "RGB", "Original HDR or encoding was not restored");
            });
            Test("Unknown color mode is not accepted as an SDR depth transition", () => {
                var b = new FakeBackend { WcgOnSdrAtHighDepth = true, ForcedWindowsModeOnRange = "Unknown" };
                b.SetHdr("id0", true); var c = b.Current.Monitors[0].NvidiaColorState.Value; c.Policy = 0; b.Current.Monitors[0].NvidiaColorState = c; b.HonorUserDepth = true;
                Throws(() => new Controller(b).Apply("id0", false, new Rate(23999, 100), "AutoFull"), "unexpectedly changed Windows encoding, color mode, or HDR state");
            });
            Test("Rate-only HDR action also prefers 10-bit output", () => {
                var b = new FakeBackend { EightBitOnHdr = true }; b.SetHdr("id0", true);
                var m = new Controller(b).Apply("id0", null, new Rate(120, 1), "Full");
                Assert(m.BitsPerColorChannel == 10 && m.HdrActive == true, "Rate-only HDR did not prefer 10 bits");
            });
            Test("Range-only actions preserve depth", () => {
                var b = new FakeBackend { EightBitOnHdr = true }; b.SetHdr("id0", true);
                var m = new Controller(b).Apply("id0", null, null, "Full");
                Assert(m.BitsPerColorChannel == 8 && !m.PreferredBitsPerColorChannel.HasValue, "Range-only unexpectedly changed depth");
            });
            Test("Unsupported 10-bit Full request retains Full at current depth with diagnostics", () => {
                var b = new FakeBackend { EightBitOnHdr = true, RejectPreferredDepth = true };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.HdrActive == true && m.ColorRange == "Full" && m.BitsPerColorChannel == 8 && m.PreferredBitsPerColorChannel == 10 && m.ColorDepthFallbackReason.Contains("rejected"), "Unsupported depth handled incorrectly");
            });
            Test("Driver acceptance followed by an ignored depth change warns without rollback", () => {
                var b = new FakeBackend { EightBitOnHdr = true, IgnoreDepthOnce = true };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.HdrActive == true && m.BitsPerColorChannel == 8 && m.RefreshRateHz == 120 && m.ColorRange == "Full" && m.ColorDepthFallbackReason.Contains("not confirmed"), "Correct mode rolled back for preferred depth");
                Assert(!b.Events.Contains("RESTORE"), "Depth-only failure triggered rollback");
            });
            Test("Depth verification waits for Windows readback to catch up", () => {
                var b = new FakeBackend { EightBitOnHdr = true, DepthReadDelay = 3 };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.BitsPerColorChannel == 10, "Depth readback was not awaited");
            });
            Test("Windows and NVIDIA depth disagreement is preserved and warned without rollback", () => {
                var b = new FakeBackend { EightBitOnHdr = true, DepthReadDelay = 200 };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.HdrActive == true && m.ColorRange == "Full" && m.RefreshRateHz == 120, "Verified settings discarded for depth disagreement");
                Assert(m.BitsPerColorChannel == 8 && m.NvidiaOutputBitsPerColorChannel == 10 && m.ColorDepthReadingsAgree == false, "Disagreement hidden");
                Assert(m.ColorDepthFallbackReason.Contains("Windows depth=8") && m.ColorDepthFallbackReason.Contains("NVIDIA output depth=10"), "Diagnostic readbacks missing");
                Assert(!b.Events.Contains("RESTORE"), "Readback disagreement rolled back mode");
            });
            Test("Repeated matching preset skips all refresh/HDR/color setters", () => {
                var b = new FakeBackend(); var controller = new Controller(b);
                controller.Apply("id0", true, new Rate(120, 1), "AutoFull"); b.Events.Clear();
                controller.Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(b.Events.Count == 0, "Matching preset cycled displays");
            });
            Test("Matching fixed refresh still disables Windows DRR", () => {
                var b = new FakeBackend(); b.Current.Monitors[0].DynamicRefreshRate = true;
                new Controller(b).Apply("id0", null, new Rate(60, 1));
                Assert(System.String.Join(",", b.Events) == "RATE:60/1" && !b.Current.Monitors[0].DynamicRefreshRate, "Skipped necessary DRR disable");
            });
            Test("Physical refresh mismatch cannot be mistaken for a matching preset", () => {
                var b = new FakeBackend(); b.Current.Monitors[0].PhysicalRefresh = new Rate(120, 1);
                new Controller(b).Apply("id0", null, new Rate(60, 1));
                Assert(System.String.Join(",", b.Events) == "RATE:60/1" && b.Current.Monitors[0].PhysicalRefresh.Hz == 60, "Skipped physical refresh correction");
            });
            Test("Color no-op checks include user policy, range, and output depth", () => {
                var c = FakeBackend.MakeState().Monitors[0].NvidiaColorState.Value;
                Assert(NvidiaApi.RequiresColorSet(c, NvidiaApi.RangeRequest(c, "Full")), "Best-quality policy falsely treated as pinned Full");
                c.Policy = 0;
                Assert(!NvidiaApi.RequiresColorSet(c, NvidiaApi.RangeRequest(c, "Full", 8)), "Already matching packet causes modeset");
                Assert(NvidiaApi.RequiresColorSet(c, NvidiaApi.RangeRequest(c, "Full", 10)), "Necessary depth switch skipped");
                Assert(NvidiaApi.RequiresColorSet(c, NvidiaApi.RangeRequest(c, "Limited")), "Necessary range switch skipped");
            });
            Test("Default Full corrects Limited after HDR and rate transitions", () => {
                var b = new FakeBackend { LimitedOnModeChange = true, ResetRateOnHdr = true };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull");
                Assert(m.ColorRange == "Full" && m.NvidiaColorState.Value.Policy == 0 && m.NvidiaColorState.Value.Bpc == 3 && m.ColorRangeEnforcedByAction, "Full policy/depth not retained");
                Assert(System.String.Join(",", b.Events) == "RATE:120/1,HDR:True,RATE:120/1,RANGE:Full", "Range not last");
            });
            Test("Range-only pins Full even when the initial reading is Full", () => {
                var b = new FakeBackend(); new Controller(b).Apply("id0", null, null, "Full");
                Assert(System.String.Join(",", b.Events) == "RANGE:Full" && b.Current.Monitors[0].NvidiaColorState.Value.Policy == 0, "Automatic selection left enabled");
            });
            Test("Explicit Limited and Keep do not enforce Full", () => {
                var b = new FakeBackend(); new Controller(b).Apply("id0", null, null, "Limited");
                Assert(b.Current.Monitors[0].ColorRange == "Limited", "Limited request ignored");
                b.Events.Clear(); new Controller(b).Apply("id0", null, new Rate(120, 1), null);
                Assert(System.String.Join(",", b.Events) == "RATE:120/1" && b.Current.Monitors[0].ColorRange == "Limited", "Keep applied Full");
            });
            Test("Unreadable NVIDIA range fails default/explicit requests before mutations", () => {
                var b = new FakeBackend(); b.Current.Monitors[0].NvidiaColorState = null; b.Current.Monitors[0].ColorRange = "Unknown";
                Throws(() => new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull"), "refusing setting changes");
                Throws(() => new Controller(b).Apply("id0", true, null, "Full"), "refusing setting changes");
                Assert(b.Events.Count == 0, "Changed unreadable color settings");
            });
            Test("Non-NVIDIA mode changes remain available without claiming Full enforcement", () => {
                var b = new FakeBackend(); var m = b.Current.Monitors[0]; m.ColorRangeSource = "Unavailable"; m.ColorRange = "Unknown"; m.NvidiaColorState = null;
                new Controller(b).Apply("id0", null, new Rate(120, 1), "AutoFull");
                Assert(System.String.Join(",", b.Events) == "RATE:120/1", "Tried vendor API on unsupported GPU");
                Throws(() => new Controller(b).Apply("id0", null, null, "Full"), "refusing setting changes");
            });
            Test("Clone range change is rejected before mutations", () => {
                var b = new FakeBackend(); b.Current.Monitors[1].X = 0;
                Throws(() => new Controller(b).Apply("id0", null, null, "Full"), "duplicated");
                Assert(b.Events.Count == 0, "Changed cloned range");
            });
            Test("Ignored Full request fails and restores original mode and range policy", () => {
                var b = new FakeBackend { LimitedOnModeChange = true, IgnoreRangeOnce = true };
                Throws(() => new Controller(b).Apply("id0", true, new Rate(120, 1), "AutoFull"), "Previous settings restored");
                var m = b.Current.Monitors[0];
                Assert(m.ColorRange == "Full" && m.NvidiaColorState.Value.Policy == 1 && m.HdrActive == false && m.RefreshRateHz == 60, "Original color/mode not restored");
                Assert(b.Events.Contains("COLORRESTORE:id0"), "Color restoration missing");
            });
            Test("Failed color setter restores previous Limited range and automatic policy", () => {
                var b = new FakeBackend { FailRangeOnce = true }; var m = b.Current.Monitors[0]; var c = m.NvidiaColorState.Value; c.Range = 1; m.NvidiaColorState = c; m.ColorRange = "Limited";
                Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1), "Full"), "Previous settings restored");
                m = b.Current.Monitors[0]; Assert(m.ColorRange == "Limited" && m.NvidiaColorState.Value.Policy == 1 && m.RefreshRateHz == 60, "Original Limited policy lost");
            });
            Test("Peer color range drift is detected and restored", () => {
                var b = new FakeBackend { ChangePeerRange = true };
                Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1), "AutoFull"), "Unexpected color/HDR");
                Assert(b.Current.Monitors[1].ColorRange == "Full" && b.Events.Contains("COLORRESTORE:id1"), "Peer range not restored");
            });
            Test("Range changes cannot silently alter depth", () => {
                var b = new FakeBackend { ChangeDepthOnRange = true };
                var m = new Controller(b).Apply("id0", null, null, "Full");
                Assert(m.ColorRange == "Full" && m.BitsPerColorChannel == 12 && m.ColorDepthFallbackReason.Contains("not confirmed"), "Depth drift hidden or correct range discarded");
            });
            Test("Color restoration failure is explicit", () => {
                var b = new FakeBackend { LimitedOnModeChange = true, IgnoreRangeOnce = true, FailColorRestore = true };
                string message = Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1), "AutoFull"), "RESTORATION FAILED");
                Assert(message.Contains("Simulated color restoration rejection"), "Color failure details missing");
            });
            Test("Full without the user policy is rejected", () => {
                var b = new FakeBackend { IgnoreUserPolicy = true };
                Throws(() => new Controller(b).Apply("id0", null, null, "Full"), "user output-color policy");
                Assert(b.Current.Monitors[0].NvidiaColorState.Value.Policy == 1, "Original policy lost");
            });
            Test("Range setter colorimetry drift is rejected and restored", () => {
                var b = new FakeBackend { ChangeColorimetryOnRange = true };
                Throws(() => new Controller(b).Apply("id0", null, null, "Full"), "NVIDIA encoding, colorimetry");
                Assert(b.Current.Monitors[0].NvidiaColorState.Value.Colorimetry == 0, "Colorimetry not restored");
            });
            Test("Color restoration is attempted even if timing restoration fails", () => {
                var b = new FakeBackend { LimitedOnModeChange = true, IgnoreRangeOnce = true, FailRestore = true };
                Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1), "Full"), "RESTORATION FAILED");
                Assert(b.Events.Contains("COLORRESTORE:id0") && b.Current.Monitors[0].ColorRange == "Full", "Color restoration skipped after timing failure");
            });
            Test("Integer, decimal, exact fraction, and reduction", () => {
                Assert(Rate.Parse("144").ToString() == "144/1", "Integer parsing");
                Assert(Rate.Parse("59.94").ToString() == "2997/50", "Decimal parsing");
                Assert(Rate.Parse("60000/1001").ToString() == "60000/1001", "Fraction parsing");
                Assert(Rate.Parse("120000/2002").ToString() == "60000/1001", "Reduction");
                Assert(Rate.Parse(" 060.0000 ").ToString() == "60/1", "Zero trimming");
                Assert(Rate.Parse("8589934590/2").ToString() == "4294967295/1", "Reduce before UInt32 bounds");
            });
            Test("Invalid rates and overflow rejected", () => {
                foreach (string s in new string[] { "0", "0/1", "1/0", "-1", "NaN", "Infinity", "1e2", "59,94", "60 Hz", "1/2/3", "", "4294967296", "1/4294967296", "0.0000000001", "99999999999999999999999" })
                    Throws(() => Rate.Parse(s), "");
            });
            Test("Exact, case-insensitive name and ID selection", () => {
                var s = FakeBackend.MakeState();
                Assert(Selection.Resolve(s.Monitors, "test panel", null).MonitorId == "id0", "Case-insensitive name");
                Assert(Selection.Resolve(s.Monitors, "test panel", " ").MonitorId == "id0", "Blank ID incorrectly overrode name");
                Assert(Selection.Resolve(s.Monitors, null, "ID1").MonitorName == "Other Panel", "ID selection");
                Throws(() => Selection.Resolve(s.Monitors, "Test", null), "No matching");
                Throws(() => Selection.Resolve(s.Monitors, null, null), "exactly one");
                Throws(() => Selection.Resolve(s.Monitors, "Test Panel", "id0"), "exactly one");
            });
            Test("Duplicate names include disambiguating IDs", () => {
                var s = FakeBackend.MakeState(); s.Monitors[1].MonitorName = s.Monitors[0].MonitorName;
                string message = Throws(() => Selection.Resolve(s.Monitors, "Test Panel", null), "Ambiguous");
                Assert(message.Contains("id0") && message.Contains("id1"), "Candidate IDs missing");
            });
            Test("Modern refresh candidate updates target VSync and preserves indexes/peers", () => {
                var s = FakeBackend.MakeState(); var p = s.Paths[0]; p.Flags |= 0x10; s.Paths[0] = p;
                var candidate = NativeBackend.BuildRefreshConfig(s, "id0", Rate.Parse("60000/1001"));
                Assert(candidate.Paths[0].Target.ModeIndex == 0x00011234u, "Virtual indexes changed");
                Assert(candidate.Modes[1].Target.VSync.ToString() == "60000/1001", "Target VSync not updated");
                Assert(s.Modes[1].Target.VSync.ToString() == "60/1", "Original mode mutated");
                Assert(candidate.Paths[0].Flags == 9 && s.Paths[0].Flags == 25, "DRR flag/immutable input");
                Assert(candidate.Paths[0].Source.ModeIndex == s.Paths[0].Source.ModeIndex, "Source index changed");
                Assert(candidate.Paths[1].Target.ModeIndex == s.Paths[1].Target.ModeIndex, "Peer target changed");
                Assert(candidate.Paths[1].Target.Refresh.ToString() == "60/1", "Peer rate changed");
                Assert(candidate.Paths[0].Target.Refresh.ToString() == "60000/1001", "Lost rational");
            });
            Test("Legacy target VSync update", () => {
                var s = FakeBackend.MakeState(); var p = s.Paths[0]; p.Flags = 1; p.Source.ModeIndex = 0; p.Target.ModeIndex = 1; s.Paths[0] = p; s.QueryFlags = 2;
                var c = NativeBackend.BuildRefreshConfig(s, "id0", new Rate(120, 1));
                Assert(c.Paths[0].Target.ModeIndex == 1 && c.Modes[1].Target.VSync.ToString() == "120/1", "Legacy target rate");
            });
            Test("Validation/application flags neither persist nor relax settings", () => {
                var s = FakeBackend.MakeState();
                Assert(NativeBackend.ApplyFlags(s, true) == 0x28060, "Validation flags");
                Assert(NativeBackend.ApplyFlags(s, false) == 0x280A0, "Application flags");
                Assert((NativeBackend.ApplyFlags(s, false) & 0x600) == 0, "Persistence/allow changes unexpectedly enabled");
                s.QueryFlags = 2; Assert(NativeBackend.ApplyFlags(s, false) == 0xA0, "Legacy flags");
            });
            Test("Clone refresh rejected before mutations", () => {
                var b = new FakeBackend(); b.Current.Monitors[1].SourceKey = "source0";
                Throws(() => new Controller(b).Apply("id0", false, new Rate(120, 1)), "duplicated");
                Assert(b.Events.Count == 0, "Mutation before clone rejection");
                Throws(() => NativeBackend.BuildRefreshConfig(b.Current, "id0", new Rate(120, 1)), "duplicated");
            });
            Test("Duplicate desktop rectangle with distinct sources is rejected", () => {
                var b = new FakeBackend(); b.Current.Monitors[1].X = 0;
                Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1)), "duplicated");
                Assert(b.Events.Count == 0, "Mutated duplicate desktop");
            });
            Test("Refresh before HDR enable and reapplication after HDR resets timing", () => {
                var b = new FakeBackend { ResetRateOnHdr = true };
                var m = new Controller(b).Apply("id0", true, new Rate(120, 1));
                Assert(System.String.Join(",", b.Events) == "RATE:120/1,HDR:True,RATE:120/1", "Wrong enable ordering");
                Assert(m.HdrActive == true && m.RefreshRateHz == 120, "Incorrect final state");
            });
            Test("HDR disable before refresh", () => {
                var b = new FakeBackend(); b.SetHdr("id0", true); b.Events.Clear();
                new Controller(b).Apply("id0", false, new Rate(144, 1));
                Assert(System.String.Join(",", b.Events) == "HDR:False,RATE:144/1", "Wrong disable ordering");
            });
            Test("Unsupported HDR refused before rate mutation", () => {
                var b = new FakeBackend(); b.Current.Monitors[0].HdrSupported = false;
                Throws(() => new Controller(b).Apply("id0", true, new Rate(120, 1)), "unsupported");
                Assert(b.Events.Count == 0, "Changed rate for unsupported HDR");
            });
            Test("Unknown legacy WCG state refused", () => {
                var b = new FakeBackend(); b.Current.Monitors[0].HdrEnabled = null;
                Throws(() => new Controller(b).Apply("id0", false, null), "wide-color SDR");
                Assert(b.Events.Count == 0, "Unknown HDR mutated");
            });
            Test("Policy-limited HDR refused", () => {
                var b = new FakeBackend(); b.Current.Monitors[0].ColorLimitedByPolicy = true;
                Throws(() => new Controller(b).Apply("id0", true, null), "policy");
            });
            Test("HDR-only and refresh-only operation", () => {
                var b = new FakeBackend(); new Controller(b).Apply("id0", true, null);
                Assert(b.Current.Monitors[0].RefreshRateHz == 60, "HDR-only rate changed");
                new Controller(b).Apply("id0", null, Rate.Parse("60000/1001"));
                Assert(b.Current.Monitors[0].HdrActive == true, "Refresh-only HDR changed");
            });
            Test("Depth mismatch remains successful", () => {
                var b = new FakeBackend { DepthOverride = 8 };
                Assert(new Controller(b).Apply("id0", true, null).BitsPerColorChannel == 8, "Depth mismatch incorrectly failed");
            });
            Test("Rejected rate after disabling HDR restores HDR and timing", () => {
                var b = new FakeBackend { FailRateCall = 1 }; b.SetHdr("id0", true); b.Events.Clear();
                Throws(() => new Controller(b).Apply("id0", false, new Rate(144, 1)), "Previous settings restored");
                Assert(b.Current.Monitors[0].HdrActive == true && b.Current.Monitors[0].RefreshRateHz == 60, "Original state missing");
                Assert(b.Events.Contains("RESTORE") && b.Events.Contains("HDR:True"), "Restore operations missing");
            });
            Test("HDR setter error after partial mutation restores SDR", () => {
                var b = new FakeBackend { FailHdrOnce = true };
                Throws(() => new Controller(b).Apply("id0", true, null), "Previous settings restored");
                Assert(b.Current.Monitors[0].HdrActive == false, "HDR not restored after partial failure");
            });
            Test("Wrong resulting rate fails verification and restores", () => {
                var b = new FakeBackend { ReturnWrongRate = true };
                string message = Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1)), "Previous settings restored");
                Assert(message.Contains("Last observed before restoration") && message.Contains("refresh=75/1") && message.Contains("physical=75/1") && message.Contains("Windows depth=8") && message.Contains("NVIDIA output depth=8"), "Failure lost pre-restoration readings");
                Assert(b.Current.Monitors[0].RefreshRateHz == 60, "Rate not restored");
            });
            Test("Unexpected peer layout change is detected and restored", () => {
                var b = new FakeBackend { ChangePeer = true };
                Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1)), "Unexpected resolution");
                Assert(b.Current.Monitors[1].X == 1920 && b.Current.Monitors[0].RefreshRateHz == 60, "Peer layout not restored");
            });
            Test("Restoration failure is explicit", () => {
                var b = new FakeBackend { ChangePeer = true, FailRestore = true };
                string message = Throws(() => new Controller(b).Apply("id0", null, new Rate(120, 1)), "RESTORATION FAILED");
                Assert(message.Contains("Simulated restoration rejection"), "Restoration failure details missing");
            });
            Test("Inactive HDR is not reported as successful HDR", () => {
                var b = new FakeBackend(); b.Current.Monitors[0].HdrEnabled = true; b.Current.Monitors[0].HdrActive = false;
                Throws(() => new Controller(b).Apply("id0", true, null), "within five seconds");
                Assert(b.Events.Count == 0, "Unnecessary mutation");
            });
            Test("0.01 Hz verification tolerance", () => {
                Assert(Controller.Close(Rate.Parse("59.94"), Rate.Parse("60000/1001")), "Fraction tolerance");
                Assert(!Controller.Close(new Rate(60, 1), Rate.Parse("60000/1001")), "60 incorrectly treated as 59.94");
            });
            return passed.ToArray();
        }
    }
}
'@
Add-Type -TypeDefinition ($script:MonitorInteropSource + [Environment]::NewLine + $testSource)
$passed = @([MonitorControl.Tests.Suite]::Run())

$fakeState = [MonitorControl.Tests.FakeBackend]::MakeState()
$status = ConvertTo-MonitorStatus $fakeState.Monitors[0]
if ($status.RotationDegrees -ne 0 -or $status.RefreshRateFraction -ne '60/1' -or
    $status.BitsPerColorChannel -ne 8 -or $status.ColorRange -ne 'Full' -or $status.ColorRangePolicy -ne 'BestQuality' -or
    $status.WindowsBitsPerColorChannel -ne 8 -or $status.NvidiaOutputBitsPerColorChannel -ne 8 -or $status.ColorDepthReadingsAgree -ne $true -or
    $status.WindowsDynamicRefreshRate -ne $false -or $null -ne $status.VariableRefreshRateActive -or $status.PSObject.Properties.Name -contains 'PathIndex' -or
    $status.PSObject.Properties.Name -contains 'SourceKey') { throw 'Status output contains wrong/missing fields.' }
$passed += 'Structured status contains display settings rather than backend indexes'

foreach ($invalidArguments in @(
    @{},
    @{ MonitorName = 'Panel'; MonitorId = 'id' },
    @{ ListMonitors = $true; MonitorName = 'Panel' },
    @{ MonitorName = 'Panel'; ListRefreshRates = $true; Hdr = 'On' },
    @{ ListMonitors = $true; ColorRange = 'Full' },
    @{ MonitorName = 'Panel'; ListRefreshRates = $true; ColorRange = 'Full' }
)) {
    $rejected = $false
    try { Invoke-MonitorCommand -Arguments $invalidArguments -Caller $null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid CLI argument combination accepted.' }
}
$passed += 'Invalid CLI combinations rejected before display access'

$fakeBackend = [MonitorControl.Tests.FakeBackend]::new()
$controller = [MonitorControl.Controller]::new($fakeBackend)
$result = $controller.Apply('id0', $true, [MonitorControl.Rate]::Parse('59.94'))
if ($result.HdrActive -ne $true -or $result.RefreshRateFraction -ne '2997/50') { throw 'PowerShell nullable argument binding failed for combined settings.' }
$result = $controller.Apply('id0', $null, [MonitorControl.Rate]::Parse('120'))
if ($result.HdrActive -ne $true -or $result.RefreshRateHz -ne 120) { throw 'PowerShell nullable HDR binding failed.' }
$result = $controller.Apply('id0', $false, $null)
if ($result.HdrActive -ne $false -or $result.RefreshRateHz -ne 120) { throw 'PowerShell nullable rate binding failed.' }
$passed += 'PowerShell calls bind combined, HDR-only, and rate-only nullable arguments'
$result = $controller.Apply('id0', $null, $null, 'Full')
if ($result.ColorRange -ne 'Full' -or $result.NvidiaColorState.Policy -ne 0) { throw 'PowerShell range-only binding failed.' }
$result = $controller.Apply('id0', $true, [MonitorControl.Rate]::Parse('120'), 'AutoFull')
if ($result.ColorRange -ne 'Full' -or $result.HdrActive -ne $true) { throw 'PowerShell automatic range binding failed.' }
$eventCount = $fakeBackend.Events.Count
$result = $controller.Apply('id0', $null, $null, $null)
if ($fakeBackend.Events.Count -ne $eventCount -or $result.ColorRangeEnforcedByAction) { throw 'PowerShell null range binding failed.' }
$passed += 'PowerShell calls bind range-only and automatic Full arguments'

Write-Output ('PASS: {0} checks; no display setters were called.' -f $passed.Count)
$passed | ForEach-Object { Write-Output ('  ' + $_) }

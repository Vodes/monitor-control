#requires -Version 5.1
<#
.SYNOPSIS
Lists active monitors, changes HDR/refresh rate, and keeps NVIDIA output range Full.
.EXAMPLE
.\Set-Monitor.ps1 -ListMonitors
.EXAMPLE
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -ListRefreshRates
.EXAMPLE
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -Hdr On -RefreshRate '60000/1001'
.EXAMPLE
.\Set-Monitor.ps1 -MonitorName 'Monitor Name' -ColorRange Full
.NOTES
Run in the local Windows desktop session using 64-bit PowerShell.
NVIDIA HDR/rate actions prefer 10-bit HDR or 8-bit SDR with the requested range.
Unsupported depths produce a warning. Refresh changes are not saved; Windows
controls HDR persistence. See Monitor-Control.md for Stream Deck setup.
NVIDIA output range defaults to Full after setting changes; -ColorRange Keep
leaves selection to the driver. -NoNvidiaApi disables NVIDIA queries/control.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$MonitorName,
    [string]$MonitorId,
    [ValidateSet('On', 'Off')][string]$Hdr,
    [string]$RefreshRate,
    [ValidateSet('Full', 'Limited', 'Keep')][string]$ColorRange,
    [switch]$NoNvidiaApi,
    [switch]$ListMonitors,
    [switch]$ListRefreshRates,
    [string]$LogPath
)

# Kept inside this script so the delivered tool has no module or compiler SDK dependency.
$script:MonitorInteropSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

namespace MonitorControl {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rate {
        public uint Numerator, Denominator;
        public Rate(uint n, uint d) {
            if (n == 0 || d == 0) throw new ArgumentException("Refresh rate must be positive.");
            uint g = Gcd(n, d); Numerator = n / g; Denominator = d / g;
        }
        static uint Gcd(uint a, uint b) { while (b != 0) { uint t = a % b; a = b; b = t; } return a; }
        public double Hz { get { return Denominator == 0 ? 0 : (double)Numerator / Denominator; } }
        public override string ToString() { return Numerator + "/" + Denominator; }
        public static Rate Parse(string text) {
            if (text == null) throw new ArgumentException("A refresh rate is required.");
            text = text.Trim();
            if (Regex.IsMatch(text, @"^[0-9]+/[0-9]+$")) {
                string[] parts = text.Split('/'); ulong n, d;
                if (!UInt64.TryParse(parts[0], out n) || !UInt64.TryParse(parts[1], out d) || n == 0 || d == 0)
                    throw new ArgumentException("Invalid or unrepresentable refresh-rate fraction.");
                ulong a = n, b = d; while (b != 0) { ulong t = a % b; a = b; b = t; }
                n /= a; d /= a;
                if (n > UInt32.MaxValue || d > UInt32.MaxValue) throw new ArgumentException("Refresh-rate fraction exceeds the Windows 32-bit rational limit.");
                return new Rate((uint)n, (uint)d);
            }
            if (!Regex.IsMatch(text, @"^[0-9]+(?:\.[0-9]+)?$"))
                throw new ArgumentException("Use positive decimal Hz (59.94) or a fraction (60000/1001), with a dot as decimal separator.");
            // Strip insignificant zeros before constructing a bounded exact rational.
            if (text.IndexOf('.') >= 0) text = text.TrimEnd('0').TrimEnd('.');
            string[] decimalParts = text.Split('.');
            int places = decimalParts.Length == 2 ? decimalParts[1].Length : 0;
            if (places > 9) throw new ArgumentException("Decimal rates support at most nine significant decimal places; use an exact fraction instead.");
            ulong numerator;
            if (!UInt64.TryParse(text.Replace(".", ""), out numerator) || numerator == 0)
                throw new ArgumentException("Invalid or unrepresentable refresh rate.");
            ulong denominator = 1; for (int i = 0; i < places; i++) denominator *= 10;
            return Parse(numerator.ToString(CultureInfo.InvariantCulture) + "/" + denominator.ToString(CultureInfo.InvariantCulture));
        }
    }

    [StructLayout(LayoutKind.Sequential)] public struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Region { public uint Width, Height; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Header { public uint Type, Size; public Luid Adapter; public uint Id; }
    [StructLayout(LayoutKind.Sequential)] public struct PathSource { public Luid Adapter; public uint Id, ModeIndex, Status; }
    [StructLayout(LayoutKind.Sequential)] public struct PathTarget {
        public Luid Adapter; public uint Id, ModeIndex, OutputTechnology, Rotation, Scaling;
        public Rate Refresh; public uint ScanLine; public int Available; public uint Status;
    }
    [StructLayout(LayoutKind.Sequential)] public struct DisplayPath { public PathSource Source; public PathTarget Target; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] public struct Signal {
        public ulong PixelRate; public Rate HSync, VSync; public Region Active, Total; public uint Standard, ScanLine;
    }
    [StructLayout(LayoutKind.Sequential)] public struct SourceMode { public uint Width, Height, PixelFormat; public Point Position; }
    [StructLayout(LayoutKind.Explicit, Size = 64)] public struct DisplayMode {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(4)] public uint Id;
        [FieldOffset(8)] public Luid Adapter;
        [FieldOffset(16)] public Signal Target;
        [FieldOffset(16)] public SourceMode Source;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SourceName {
        public Header Header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct TargetName {
        public Header Header; public uint Flags, Technology; public ushort Manufacturer, Product; public uint Connector;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
    }
    [StructLayout(LayoutKind.Sequential)] struct ColorInfo { public Header Header; public uint Flags, Encoding, Bits; }
    [StructLayout(LayoutKind.Sequential)] struct ColorInfo2 { public Header Header; public uint Flags, Encoding, Bits, Mode; }
    [StructLayout(LayoutKind.Sequential)] struct HdrPacket { public Header Header; public uint Enable; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct OutputDesc {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public Rect Desktop; public int Attached; public uint Rotation; public IntPtr Monitor;
    }
    [StructLayout(LayoutKind.Sequential)] struct DxgiMode {
        public uint Width, Height; public Rate Refresh; public uint Format, ScanLine, Scaling; public int Stereo;
    }
    // NVIDIA's public NVAPI ABI. See NVIDIA-NVAPI-NOTICE.md for SDK attribution.
    [StructLayout(LayoutKind.Sequential)] public struct NvidiaColor {
        public uint Version; public ushort Size; public byte Command, Padding;
        public byte Format, Colorimetry, Range, Reserved;
        public uint Bpc, Policy, DesktopDepth;
    }
    [StructLayout(LayoutKind.Sequential)] struct NvidiaVrr {
        public uint Version, Flags, Reserved0, Reserved1, Reserved2, Reserved3;
    }
    // NV_MONITOR_CAPABILITIES_V1 contains a 49-byte union, aligned as bytes.
    // The enclosing structure is rounded to four-byte alignment (68 bytes).
    [StructLayout(LayoutKind.Explicit, Size = 68)] struct NvidiaMonitorCapabilities {
        [FieldOffset(0)] public uint Version;
        [FieldOffset(4)] public ushort Size;
        [FieldOffset(8)] public uint InfoType;
        [FieldOffset(12)] public uint ConnectorType;
        [FieldOffset(16)] public byte ValidFlags;
        [FieldOffset(17)] public byte GenericFlags;
    }
    [StructLayout(LayoutKind.Sequential)] struct NvidiaDisplayIdentity {
        public uint Version; public Luid Adapter; public uint Target, Reserved0, Reserved1, Reserved2, Reserved3;
    }
    [StructLayout(LayoutKind.Sequential)] struct NvidiaTargetIdentity {
        public uint Version; public Luid Adapter; public uint Target;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)] public uint[] Displays;
        public uint Count, Reserved0, Reserved1, Reserved2, Reserved3;
    }

    public sealed class MonitorInfo {
        public MonitorInfo() {
            VariableRefreshRateSource = "Unavailable";
            VariableRefreshRateUnavailableReason = "Windows display configuration does not report G-SYNC/Adaptive-Sync enablement.";
            VariableRefreshRateSupportUnavailableReason = "Windows display configuration does not report monitor VRR capability.";
            NvidiaVrrSource = "Unavailable";
            NvidiaVrrUnavailableReason = "NVIDIA VRR mode information has not been queried.";
            ColorRange = "Unknown";
            ColorRangeSource = "Unavailable";
            ColorRangeUnavailableReason = "Windows display configuration does not report output quantization range.";
        }
        public string MonitorName { get; set; }
        public string MonitorId { get; set; }
        public string DisplayName { get; set; }
        public uint Width { get; set; }
        public uint Height { get; set; }
        public int X { get; set; }
        public int Y { get; set; }
        public uint Rotation { get; set; }
        public uint Scaling { get; set; }
        public uint SignalWidth { get; set; }
        public uint SignalHeight { get; set; }
        public uint ScanLine { get; set; }
        public Rate Refresh { get; set; }
        public Rate PhysicalRefresh { get; set; }
        public double RefreshRateHz { get { return Refresh.Hz; } }
        public string RefreshRateFraction { get { return Refresh.ToString(); } }
        public double PhysicalRefreshRateHz { get { return PhysicalRefresh.Hz; } }
        public bool DynamicRefreshRate { get; set; }
        public bool WindowsDynamicRefreshRate { get { return DynamicRefreshRate; } }
        public bool? VariableRefreshRateSupported { get; set; }
        public bool? VariableRefreshRateEnabled { get; set; }
        public bool? VariableRefreshRateActive { get { return VariableRefreshRateEnabled; } }
        public bool? VariableRefreshRateRequested { get; set; }
        public bool? DisplayInVariableRefreshRateMode { get; set; }
        public string VariableRefreshRateSource { get; set; }
        public string VariableRefreshRateUnavailableReason { get; set; }
        public string VariableRefreshRateSupportUnavailableReason { get; set; }
        public bool? NvidiaReportedVrrModeActive { get; set; }
        public string NvidiaVrrRawFlags { get; set; }
        public string NvidiaVrrSource { get; set; }
        public string NvidiaVrrUnavailableReason { get; set; }
        public string NvidiaVrrReportingNote { get { return "Raw driver mode information does not establish the per-monitor G-SYNC checkbox or verify VRR activity in a game. Older drivers define only bit 0; remaining bits are not interpreted."; } }
        public string ColorRange { get; set; }
        public string ColorRangeSource { get; set; }
        public string ColorRangeUnavailableReason { get; set; }
        public bool ColorRangeEnforcedByAction { get; set; }
        public uint? PreferredBitsPerColorChannel { get; set; }
        public string ColorDepthFallbackReason { get; set; }
        public string ColorModeTransitionNote { get; set; }
        public NvidiaColor? NvidiaColorState { get; set; }
        public bool? HdrSupported { get; set; }
        public bool? HdrEnabled { get; set; }
        public bool? HdrActive { get; set; }
        public bool ColorLimitedByPolicy { get; set; }
        public string ColorMode { get; set; }
        public string ColorEncoding { get; set; }
        public uint? BitsPerColorChannel { get; set; }
        public uint? NvidiaOutputBitsPerColorChannel { get { return NvidiaColorState.HasValue ? NvidiaApi.BitsFromBpc(NvidiaColorState.Value.Bpc) : null; } }
        public bool? ColorDepthReadingsAgree { get { return BitsPerColorChannel.HasValue && NvidiaOutputBitsPerColorChannel.HasValue ? BitsPerColorChannel == NvidiaOutputBitsPerColorChannel : (bool?)null; } }
        public string HdrApi { get; set; }
        public string SourceKey { get; set; }
        public int PathIndex { get; set; }
        public MonitorInfo Copy() { return (MonitorInfo)MemberwiseClone(); }
    }
    public sealed class DisplayState {
        public DisplayPath[] Paths;
        public DisplayMode[] Modes;
        public uint QueryFlags;
        public MonitorInfo[] Monitors;
        public DisplayState Copy() {
            return new DisplayState { Paths = (DisplayPath[])Paths.Clone(), Modes = (DisplayMode[])Modes.Clone(),
                QueryFlags = QueryFlags, Monitors = Monitors.Select(m => m.Copy()).ToArray() };
        }
    }
    public sealed class RateInfo {
        public uint Width { get; set; }
        public uint Height { get; set; }
        public uint Numerator { get; set; }
        public uint Denominator { get; set; }
        public double RefreshRateHz { get { return (double)Numerator / Denominator; } }
        public string RefreshRateFraction { get { return Numerator + "/" + Denominator; } }
    }
    public interface IDisplayBackend {
        DisplayState Capture();
        void SetHdr(string id, bool enabled);
        void SetRefresh(string id, Rate rate);
        void Restore(DisplayState state);
        void Wait(int milliseconds);
    }
    public interface IColorRangeBackend {
        NvidiaColor SetColorRange(string id, string range, uint? preferredBits);
        void RestoreColor(string id, NvidiaColor original);
    }

    public static class NvidiaApi {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)] static extern IntPtr GetProcAddress(IntPtr module, string name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr Query(uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Initialize();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)] delegate int GetDisplay(string name, out uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetIdentity(uint id, ref NvidiaDisplayIdentity info);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetTargets(ref NvidiaTargetIdentity info);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ColorControl(uint id, ref NvidiaColor info);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetVrr(uint id, ref NvidiaVrr info);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetMonitorCapabilities(uint id, ref NvidiaMonitorCapabilities info);
        static Query query; static bool attempted; static string unavailable;
        static readonly object gate = new object();
        static T Function<T>(uint id) where T : class {
            IntPtr address = query(id);
            return address == IntPtr.Zero ? null : Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }
        static void Ensure() {
            lock (gate) {
                if (!attempted) {
                    attempted = true;
                    // System32 only; never load a DLL from the script directory or download one.
                    IntPtr library = LoadLibraryEx("nvapi64.dll", IntPtr.Zero, 0x800);
                    if (library == IntPtr.Zero) unavailable = "NVIDIA's installed nvapi64.dll is unavailable.";
                    else {
                        IntPtr address = GetProcAddress(library, "nvapi_QueryInterface");
                        if (address == IntPtr.Zero) unavailable = "NVIDIA QueryInterface is unavailable.";
                        else {
                            query = (Query)Marshal.GetDelegateForFunctionPointer(address, typeof(Query));
                            Initialize init = Function<Initialize>(0x0150e828);
                            int status = init == null ? -3 : init();
                            if (status != 0) unavailable = "NVIDIA initialization failed (NVAPI " + status + ").";
                        }
                    }
                }
                if (unavailable != null) throw new InvalidOperationException(unavailable);
            }
        }
        static void Check(int status, string action) {
            if (status != 0) throw new InvalidOperationException(action + " failed (NVAPI " + status + ").");
        }
        static uint DisplayId(MonitorInfo monitor, DisplayPath path) {
            Ensure(); GetDisplay lookup = Function<GetDisplay>(0xae457190);
            GetIdentity identity = Function<GetIdentity>(0xbae8aa5e);
            if (lookup == null || identity == null) throw new InvalidOperationException("NVIDIA cannot reliably map this monitor to its display ID.");
            uint id; Check(lookup(monitor.DisplayName, out id), "Map NVIDIA display");
            NvidiaDisplayIdentity info = new NvidiaDisplayIdentity { Version = 0x10020 };
            Check(identity(id, ref info), "Verify NVIDIA display identity");
            if (info.Adapter.Low != path.Target.Adapter.Low || info.Adapter.High != path.Target.Adapter.High || info.Target != path.Target.Id)
                throw new InvalidOperationException("NVIDIA display ID does not match the selected Windows monitor.");
            GetTargets targets = Function<GetTargets>(0xe7e5f89e);
            if (targets == null) throw new InvalidOperationException("NVIDIA cannot check for a grouped Mosaic/Surround output.");
            NvidiaTargetIdentity group = new NvidiaTargetIdentity { Version = 0x10224, Adapter = path.Target.Adapter, Target = path.Target.Id, Displays = new uint[128] };
            Check(targets(ref group), "Check NVIDIA output group");
            if (group.Count != 1 || group.Displays[0] != id)
                throw new InvalidOperationException("NVIDIA Mosaic/Surround outputs cannot be controlled as an individual monitor.");
            return id;
        }
        public static string DecodeRange(byte value) { return value == 0 ? "Full" : value == 1 ? "Limited" : "Unknown"; }
        public static void DecodeVrr(uint flags, MonitorInfo monitor) {
            monitor.NvidiaReportedVrrModeActive = (flags & 1) != 0;
            monitor.NvidiaVrrRawFlags = "0x" + flags.ToString("X8", CultureInfo.InvariantCulture);
            // V1 originally defined only bit 0. New SDKs name more bits without
            // changing the packet version, so a zero cannot identify support for
            // those fields. None of these bits is the Control Panel checkbox.
            monitor.VariableRefreshRateEnabled = null;
            monitor.VariableRefreshRateRequested = null;
            monitor.DisplayInVariableRefreshRateMode = null;
        }
        public static void DecodeVrrCapability(bool valid, byte flags, MonitorInfo monitor) {
            monitor.VariableRefreshRateSupported = valid ? (bool?)((flags & 1) != 0) : null;
            monitor.VariableRefreshRateSource = valid ? "NVIDIA NVAPI monitor capabilities" : "Unavailable";
            monitor.VariableRefreshRateSupportUnavailableReason = valid ? null : "NVIDIA did not return valid generic monitor capabilities.";
            monitor.VariableRefreshRateUnavailableReason = "Per-monitor G-SYNC enablement and actual VRR activity cannot be confirmed by these queries; see the separately labelled NVIDIA mode information.";
        }
        static NvidiaColor ReadColor(uint id) {
            ColorControl control = Function<ColorControl>(0x92f9d80d);
            if (control == null) throw new InvalidOperationException("NVIDIA color control is unavailable.");
            NvidiaColor color = new NvidiaColor { Version = 0x50018, Size = 24, Command = 1 };
            int status = control(id, ref color);
            if (status == -9) { color = new NvidiaColor { Version = 0x40014, Size = 20, Command = 1 }; status = control(id, ref color); }
            Check(status, "Read NVIDIA output color settings"); return color;
        }
        public static void Read(MonitorInfo monitor, DisplayPath path, bool duplicated) {
            uint id;
            try {
                if (duplicated) throw new InvalidOperationException("NVIDIA readings are ambiguous for duplicated displays.");
                id = DisplayId(monitor, path);
            } catch (Exception e) {
                monitor.ColorRangeUnavailableReason = e.Message; monitor.VariableRefreshRateUnavailableReason = e.Message;
                monitor.VariableRefreshRateSupportUnavailableReason = e.Message; monitor.NvidiaVrrUnavailableReason = e.Message; return;
            }
            monitor.ColorRangeSource = "NVIDIA NVAPI";
            try {
                NvidiaColor color = ReadColor(id); monitor.NvidiaColorState = color;
                monitor.ColorRange = DecodeRange(color.Range); monitor.ColorRangeSource = "NVIDIA NVAPI";
                monitor.ColorRangeUnavailableReason = monitor.ColorRange == "Unknown" ? "NVIDIA did not report an explicit Full/Limited range." : null;
            } catch (Exception e) { monitor.ColorRangeUnavailableReason = e.Message; }
            try {
                GetMonitorCapabilities get = Function<GetMonitorCapabilities>(0x3b05c7e1);
                if (get == null) throw new InvalidOperationException("NVIDIA monitor capabilities are unavailable in this driver.");
                NvidiaMonitorCapabilities caps = new NvidiaMonitorCapabilities { Version = 0x10044, Size = 68, InfoType = 0x1002 };
                Check(get(id, ref caps), "Read NVIDIA monitor VRR capability");
                DecodeVrrCapability((caps.ValidFlags & 1) != 0 && caps.InfoType == 0x1002, caps.GenericFlags, monitor);
            } catch (Exception e) { monitor.VariableRefreshRateSupportUnavailableReason = e.Message; }
            try {
                GetVrr get = Function<GetVrr>(0xdf8fda57);
                if (get == null) throw new InvalidOperationException("NVIDIA VRR information is unavailable in this driver.");
                NvidiaVrr vrr = new NvidiaVrr { Version = 0x10018 };
                Check(get(id, ref vrr), "Read NVIDIA VRR information");
                DecodeVrr(vrr.Flags, monitor); monitor.NvidiaVrrSource = "NVIDIA NVAPI GetVRRInfo";
                monitor.NvidiaVrrUnavailableReason = null;
            } catch (Exception e) { monitor.NvidiaVrrUnavailableReason = e.Message; }
        }
        public static uint? BitsFromBpc(uint bpc) {
            return bpc == 1 ? 6u : bpc == 2 ? 8u : bpc == 3 ? 10u : bpc == 4 ? 12u : bpc == 5 ? 16u : (uint?)null;
        }
        public static NvidiaColor RangeRequest(NvidiaColor current, string range, uint? bits = null) {
            if (range != "Full" && range != "Limited") throw new ArgumentException("Color range must be Full or Limited.");
            current.Command = 2; current.Range = range == "Full" ? (byte)0 : (byte)1;
            current.Policy = 0; // user-selected output range rather than driver best-quality selection
            if (bits.HasValue) {
                uint depth = bits.Value;
                if (depth != 6 && depth != 8 && depth != 10 && depth != 12 && depth != 16) throw new ArgumentException("Unsupported output bit depth.");
                current.Bpc = depth == 6 ? 1u : depth == 8 ? 2u : depth == 10 ? 3u : depth == 12 ? 4u : 5u;
            }
            return current;
        }
        public static NvidiaColor ChooseColorRequest(NvidiaColor current, string range, uint? preferredBits, Func<NvidiaColor, bool> supported) {
            NvidiaColor fallback = RangeRequest(current, range);
            if (preferredBits.HasValue) {
                NvidiaColor preferred = RangeRequest(current, range, preferredBits);
                if (preferred.Bpc != fallback.Bpc && supported(preferred)) return preferred;
            }
            if (!supported(fallback)) throw new InvalidOperationException("Requested output range is unsupported with the current encoding/depth.");
            return fallback;
        }
        public static NvidiaColor PrepareColor(MonitorInfo monitor, DisplayPath path, string range, uint? preferredBits) {
            uint id = DisplayId(monitor, path); ColorControl control = Function<ColorControl>(0x92f9d80d);
            if (control == null || !monitor.NvidiaColorState.HasValue) throw new InvalidOperationException("NVIDIA color control is unavailable.");
            int lastStatus = 0;
            try {
                return ChooseColorRequest(monitor.NvidiaColorState.Value, range, preferredBits, candidate => {
                    candidate.Command = 3; lastStatus = control(id, ref candidate); return lastStatus == 0;
                });
            } catch (InvalidOperationException e) { throw new InvalidOperationException(e.Message + " (NVAPI " + lastStatus + ").", e); }
        }
        public static bool SameColor(NvidiaColor a, NvidiaColor b) {
            return a.Format == b.Format && a.Colorimetry == b.Colorimetry && a.Range == b.Range &&
                a.Bpc == b.Bpc && a.Policy == b.Policy && (a.Size < 24 || b.Size < 24 || a.DesktopDepth == b.DesktopDepth);
        }
        public static bool SameColorExceptBpc(NvidiaColor a, NvidiaColor b) { a.Bpc = b.Bpc; return SameColor(a, b); }
        public static bool RequiresColorSet(NvidiaColor current, NvidiaColor requested) { return !SameColor(current, requested); }
        public static void Set(MonitorInfo monitor, DisplayPath path, NvidiaColor color, bool validate) {
            uint id = DisplayId(monitor, path); ColorControl control = Function<ColorControl>(0x92f9d80d);
            if (control == null) throw new InvalidOperationException("NVIDIA color control is unavailable.");
            if (validate) {
                NvidiaColor test = color; test.Command = 3;
                Check(control(id, ref test), "Validate NVIDIA output color settings");
            }
            color.Command = 2; Check(control(id, ref color), "Set NVIDIA output color settings");
        }
        public static void ValidateColor(MonitorInfo monitor, DisplayPath path, NvidiaColor color) {
            uint id = DisplayId(monitor, path); ColorControl control = Function<ColorControl>(0x92f9d80d);
            if (control == null) throw new InvalidOperationException("NVIDIA color control is unavailable.");
            color.Command = 3; Check(control(id, ref color), "Validate NVIDIA output color settings");
        }
        public static void ValidateLayouts() {
            if (Marshal.SizeOf(typeof(NvidiaColor)) != 24 || Marshal.OffsetOf(typeof(NvidiaColor), "Format").ToInt32() != 8 ||
                Marshal.OffsetOf(typeof(NvidiaColor), "Bpc").ToInt32() != 12 || Marshal.SizeOf(typeof(NvidiaVrr)) != 24 ||
                Marshal.SizeOf(typeof(NvidiaMonitorCapabilities)) != 68 || Marshal.OffsetOf(typeof(NvidiaMonitorCapabilities), "InfoType").ToInt32() != 8 ||
                Marshal.OffsetOf(typeof(NvidiaMonitorCapabilities), "GenericFlags").ToInt32() != 17 ||
                Marshal.SizeOf(typeof(NvidiaDisplayIdentity)) != 32 || Marshal.SizeOf(typeof(NvidiaTargetIdentity)) != 548 ||
                Marshal.OffsetOf(typeof(NvidiaTargetIdentity), "Count").ToInt32() != 528) throw new InvalidOperationException("NVAPI structure layout mismatch.");
        }
    }

    public static class Selection {
        public static MonitorInfo Resolve(MonitorInfo[] monitors, string name, string id) {
            if (String.IsNullOrWhiteSpace(name) == String.IsNullOrWhiteSpace(id))
                throw new ArgumentException("Supply exactly one of -MonitorName or -MonitorId.");
            bool useId = !String.IsNullOrWhiteSpace(id);
            MonitorInfo[] matches = monitors.Where(m => String.Equals(useId ? id : name,
                useId ? m.MonitorId : m.MonitorName, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (matches.Length == 1) return matches[0];
            string candidates = String.Join("; ", (matches.Length == 0 ? monitors : matches)
                .Select(m => m.MonitorName + " [-MonitorId '" + m.MonitorId + "']"));
            throw new ArgumentException((matches.Length == 0 ? "No matching active monitor. Available: " : "Ambiguous monitor name. Use a MonitorId: ") + candidates);
        }
        public static MonitorInfo ById(DisplayState state, string id) {
            MonitorInfo result = state.Monitors.FirstOrDefault(m => String.Equals(m.MonitorId, id, StringComparison.OrdinalIgnoreCase));
            if (result == null) throw new InvalidOperationException("Monitor disconnected or topology changed: " + id);
            return result;
        }
        public static bool IsDuplicated(DisplayState state, MonitorInfo selected) {
            // Clones normally share a source. Across adapters/virtual sources they
            // can instead have different source IDs but the same desktop rectangle.
            return state.Monitors.Any(m => !String.Equals(m.MonitorId, selected.MonitorId, StringComparison.OrdinalIgnoreCase) &&
                (m.SourceKey == selected.SourceKey || (m.X == selected.X && m.Y == selected.Y && m.Width == selected.Width && m.Height == selected.Height)));
        }
    }

    public sealed class Controller {
        readonly IDisplayBackend backend;
        public readonly List<string> Diagnostics = new List<string>();
        public Controller(IDisplayBackend backend) { this.backend = backend; }
        void Record(string stage, DisplayState state) {
            Diagnostics.Add(stage + ": " + String.Join(" | ", state.Monitors.Select(m => m.MonitorName + ": " + Describe(m))));
        }
        public static bool Close(Rate a, Rate b) { return a.Denominator != 0 && b.Denominator != 0 && Math.Abs(a.Hz - b.Hz) <= 0.01; }
        public static bool RequiresRefreshSet(MonitorInfo monitor, Rate rate) {
            return !Close(monitor.Refresh, rate) || !Close(monitor.PhysicalRefresh, rate) || monitor.DynamicRefreshRate;
        }
        static bool TimingChanged(DisplayState before, DisplayState after) {
            return before.Monitors.Any(old => {
                MonitorInfo now = Selection.ById(after, old.MonitorId);
                return !Close(old.Refresh, now.Refresh) || !Close(old.PhysicalRefresh, now.PhysicalRefresh) || old.DynamicRefreshRate != now.DynamicRefreshRate;
            });
        }
        static string Value(object value) { return value == null ? "unknown" : Convert.ToString(value, CultureInfo.InvariantCulture); }
        public static string Describe(MonitorInfo m) {
            return "HDR enabled=" + Value(m.HdrEnabled) + ", active=" + Value(m.HdrActive) +
                "; Windows color mode=" + Value(m.ColorMode) + ", encoding=" + Value(m.ColorEncoding) +
                "; refresh=" + m.Refresh + " (" + m.Refresh.Hz.ToString("0.#####", CultureInfo.InvariantCulture) + " Hz), physical=" + m.PhysicalRefresh +
                " (" + m.PhysicalRefresh.Hz.ToString("0.#####", CultureInfo.InvariantCulture) + " Hz), Windows DRR=" + m.DynamicRefreshRate +
                "; range=" + m.ColorRange + "; Windows depth=" + Value(m.BitsPerColorChannel) +
                ", NVIDIA output depth=" + Value(m.NvidiaOutputBitsPerColorChannel) +
                ", NVIDIA policy=" + (m.NvidiaColorState.HasValue ? Value(m.NvidiaColorState.Value.Policy) : "unknown") +
                (m.NvidiaColorState.HasValue ? ", format=" + m.NvidiaColorState.Value.Format + ", colorimetry=" + m.NvidiaColorState.Value.Colorimetry + ", desktop depth=" + m.NvidiaColorState.Value.DesktopDepth : "") +
                (m.ColorRangeUnavailableReason == null ? "" : "; range read error=" + m.ColorRangeUnavailableReason);
        }
        static bool IsSdrDepthModeChange(MonitorInfo before, MonitorInfo after, bool depthRequested) {
            // WCG is an SDR Advanced Color mode. Windows may leave it when an
            // intended output-depth change removes its high-precision output.
            // Require an actual NVIDIA depth change, known SDR/WCG modes, and
            // HDR conclusively off on both sides; never excuse an encoding change.
            return depthRequested && before.HdrEnabled == false && before.HdrActive == false &&
                after.HdrEnabled == false && after.HdrActive == false &&
                (before.ColorMode == "SDR" || before.ColorMode == "WCG") &&
                (after.ColorMode == "SDR" || after.ColorMode == "WCG") &&
                before.NvidiaOutputBitsPerColorChannel.HasValue && after.NvidiaOutputBitsPerColorChannel.HasValue &&
                before.NvidiaOutputBitsPerColorChannel != after.NvidiaOutputBitsPerColorChannel;
        }
        static void CheckLayout(DisplayState before, DisplayState after, string selected, bool changingRate) {
            if (before.Monitors.Length != after.Monitors.Length) throw new InvalidOperationException("Active monitor topology changed.");
            foreach (MonitorInfo old in before.Monitors) {
                MonitorInfo now = Selection.ById(after, old.MonitorId);
                if (now.SourceKey != old.SourceKey || now.Width != old.Width || now.Height != old.Height || now.X != old.X || now.Y != old.Y ||
                    now.Rotation != old.Rotation || now.Scaling != old.Scaling || now.SignalWidth != old.SignalWidth || now.SignalHeight != old.SignalHeight || now.ScanLine != old.ScanLine)
                    throw new InvalidOperationException("Unexpected resolution, layout, rotation, scaling, or scan-mode change on " + old.MonitorName);
                bool isSelected = String.Equals(old.MonitorId, selected, StringComparison.OrdinalIgnoreCase);
                if (!isSelected || !changingRate) {
                    if (!Close(now.Refresh, old.Refresh) || !Close(now.PhysicalRefresh, old.PhysicalRefresh) || now.DynamicRefreshRate != old.DynamicRefreshRate)
                        throw new InvalidOperationException("Unexpected refresh-rate change on " + old.MonitorName);
                }
                if (!isSelected && (now.HdrEnabled != old.HdrEnabled || now.HdrActive != old.HdrActive || now.ColorMode != old.ColorMode ||
                    now.BitsPerColorChannel != old.BitsPerColorChannel || now.ColorEncoding != old.ColorEncoding ||
                    (old.ColorRange != "Unknown" && now.ColorRange != old.ColorRange) ||
                    (old.NvidiaColorState.HasValue && (!now.NvidiaColorState.HasValue || !NvidiaApi.SameColor(old.NvidiaColorState.Value, now.NvidiaColorState.Value)))))
                    throw new InvalidOperationException("Unexpected color/HDR change on " + old.MonitorName);
            }
        }
        DisplayState WaitFor(string id, bool? hdr, Rate? rate, string range = null, uint? bits = null) {
            MonitorInfo last = null;
            for (int attempt = 0; attempt < 21; attempt++) {
                DisplayState state = backend.Capture(); MonitorInfo m = Selection.ById(state, id);
                last = m;
                bool hdrMatches = !hdr.HasValue || (m.HdrEnabled == hdr && m.HdrActive == hdr);
                bool rateMatches = !rate.HasValue || (Close(m.PhysicalRefresh, rate.Value) && Close(m.Refresh, rate.Value) && !m.DynamicRefreshRate);
                bool depthMatches = !bits.HasValue || (m.BitsPerColorChannel == bits && m.NvidiaColorState.HasValue && NvidiaApi.BitsFromBpc(m.NvidiaColorState.Value.Bpc) == bits);
                bool requiredMatches = hdrMatches && rateMatches && (range == null || m.ColorRange == range);
                // Depth is best effort. Give both readbacks time to settle, but a
                // depth-only mismatch must not undo correct HDR, refresh, and range.
                if (requiredMatches && (depthMatches || attempt == 20)) return state;
                if (attempt < 20) backend.Wait(250);
            }
            throw new InvalidOperationException("Display did not reach the requested HDR/refresh/color-range state within five seconds. Requested: HDR=" +
                (hdr.HasValue ? Value(hdr) : "unchanged") + ", refresh=" + (rate.HasValue ? rate.Value.ToString() : "unchanged") +
                ", range=" + (range ?? "unchanged") + ", preferred depth=" + Value(bits) + ". Last observed before restoration: " + Describe(last) + ".");
        }
        public MonitorInfo Apply(string id, bool? hdr, Rate? rate) {
            return Apply(id, hdr, rate, null);
        }
        public MonitorInfo Apply(string id, bool? hdr, Rate? rate, string range) {
            Diagnostics.Clear();
            // PowerShell converts a null string argument to the empty string.
            if (String.IsNullOrEmpty(range)) range = null;
            DisplayState original = backend.Capture(); MonitorInfo selected = Selection.ById(original, id);
            IColorRangeBackend colorBackend = backend as IColorRangeBackend;
            if (range == "AutoFull") range = selected.ColorRangeSource == "NVIDIA NVAPI" ? "Full" : null;
            if (range != null && range != "Full" && range != "Limited") throw new ArgumentException("Color range must be Full or Limited.");
            if (range != null && (colorBackend == null || !selected.NvidiaColorState.HasValue || selected.ColorRange == "Unknown" || selected.NvidiaColorState.Value.Policy > 1))
                throw new InvalidOperationException("Cannot read and restore output color range reliably; refusing setting changes. " + selected.ColorRangeUnavailableReason);
            if (range != null && Selection.IsDuplicated(original, selected))
                throw new InvalidOperationException("Individual color-range changes are not supported for duplicated displays.");
            if (rate.HasValue && Selection.IsDuplicated(original, selected))
                throw new InvalidOperationException("Individual refresh changes are not supported for duplicated displays. Use an extended desktop.");
            if (hdr.HasValue && (!selected.HdrEnabled.HasValue || !selected.HdrActive.HasValue))
                throw new InvalidOperationException("Windows cannot reliably identify HDR state on this display; refusing to change wide-color SDR as if it were HDR.");
            if (hdr == true && (selected.HdrSupported != true || selected.ColorLimitedByPolicy))
                throw new InvalidOperationException("HDR is unsupported or limited by Windows policy on this display.");
            bool dirty = false; uint? preferredDepth = null; string depthFallback = null; string colorModeNote = null;
            Record("Initial settings", original);
            try {
                if (hdr == false && selected.HdrEnabled != false) {
                    dirty = true; backend.SetHdr(id, false); Record("After HDR off", WaitFor(id, false, null));
                }
                if (rate.HasValue && RequiresRefreshSet(Selection.ById(backend.Capture(), id), rate.Value)) {
                    dirty = true; backend.SetRefresh(id, rate.Value); Record("After refresh request", WaitFor(id, null, rate));
                }
                if (hdr == true && selected.HdrEnabled != true) { dirty = true; backend.SetHdr(id, true); Record("After HDR on", WaitFor(id, true, null)); }
                // HDR can reset the timing. Reapply only an explicitly requested rate.
                if (rate.HasValue) {
                    MonitorInfo current = Selection.ById(backend.Capture(), id);
                    if (RequiresRefreshSet(current, rate.Value)) {
                        dirty = true; backend.SetRefresh(id, rate.Value);
                    }
                }
                DisplayState final = WaitFor(id, hdr, rate);
                Record("After Windows settings", final);
                if (range != null) {
                    DisplayState beforeColor = final;
                    MonitorInfo priorColor = Selection.ById(final, id);
                    // NVIDIA's user policy covers depth as well as range: copying the
                    // transient 8-bit mode here would pin HDR to 8 bits on later actions.
                    // Range-only actions retain depth; HDR/rate actions prefer 10/8 bits.
                    if (hdr.HasValue || rate.HasValue) preferredDepth = priorColor.HdrActive == true ? 10u : priorColor.HdrActive == false ? 8u : (uint?)null;
                    NvidiaColor requestedColor = new NvidiaColor(); uint? requestedBits = null;
                    bool preferredRejected = false;
                    for (int colorPass = 0; colorPass < 2; colorPass++) {
                        // A color modeset can restore the driver's saved refresh rate.
                        // Prefer depth once; subsequent range repair retains depth so
                        // we do not repeatedly provoke the same depth/timing conflict.
                        dirty = true; requestedColor = colorBackend.SetColorRange(id, range, colorPass == 0 ? preferredDepth : null);
                        requestedBits = NvidiaApi.BitsFromBpc(requestedColor.Bpc);
                        if (colorPass == 0) preferredRejected = preferredDepth.HasValue && requestedBits != preferredDepth;
                        final = WaitFor(id, hdr, null, range);
                        Record("After NVIDIA color pass " + (colorPass + 1), final);
                        if (rate.HasValue && RequiresRefreshSet(Selection.ById(final, id), rate.Value)) {
                            backend.SetRefresh(id, rate.Value); final = WaitFor(id, hdr, rate);
                            Record("After refresh recovery", final);
                        } else if (!rate.HasValue && TimingChanged(beforeColor, final)) {
                            // Without an explicit fixed rate, preserve the snapshot,
                            // including Windows DRR, rather than choosing a new rate.
                            backend.Restore(beforeColor); final = WaitFor(id, hdr, null);
                            Record("After timing snapshot recovery", final);
                        }
                        MonitorInfo current = Selection.ById(final, id);
                        if (current.ColorRange == range) break;
                        if (colorPass == 1) throw new InvalidOperationException(
                            "Windows timing and NVIDIA output range did not stabilize after two color passes. Last observed before restoration: " + Describe(current) + ".");
                    }
                    final = WaitFor(id, hdr, rate, range, requestedBits);
                    Record("After color/depth readback", final);
                    MonitorInfo afterColor = Selection.ById(final, id);
                    if (!afterColor.NvidiaColorState.HasValue || afterColor.NvidiaColorState.Value.Policy != 0)
                        throw new InvalidOperationException("NVIDIA did not retain the requested user output-color policy.");
                    if (!priorColor.NvidiaColorState.HasValue) throw new InvalidOperationException("NVIDIA color state became unreadable during the mode transition.");
                    NvidiaColor expectedColor = NvidiaApi.RangeRequest(priorColor.NvidiaColorState.Value, range);
                    expectedColor.Bpc = requestedColor.Bpc;
                    if (!NvidiaApi.SameColorExceptBpc(expectedColor, requestedColor) || !NvidiaApi.SameColorExceptBpc(requestedColor, afterColor.NvidiaColorState.Value))
                        throw new InvalidOperationException("Output range change unexpectedly changed NVIDIA encoding, colorimetry, or desktop depth. Before NVIDIA color: " + Describe(priorColor) + ". After: " + Describe(afterColor) + ".");
                    if (afterColor.ColorEncoding != priorColor.ColorEncoding ||
                        (afterColor.ColorMode != priorColor.ColorMode && !IsSdrDepthModeChange(priorColor, afterColor, preferredDepth.HasValue)) ||
                        afterColor.HdrEnabled != priorColor.HdrEnabled || afterColor.HdrActive != priorColor.HdrActive)
                        throw new InvalidOperationException("Output range change unexpectedly changed Windows encoding, color mode, or HDR state. Before NVIDIA color: " + Describe(priorColor) + ". After: " + Describe(afterColor) + ".");
                    if (afterColor.ColorMode != priorColor.ColorMode)
                        colorModeNote = "Windows changed the SDR Advanced Color mode from " + priorColor.ColorMode + " to " + afterColor.ColorMode +
                            " while changing output depth from " + Value(priorColor.NvidiaOutputBitsPerColorChannel) + " to " + Value(afterColor.NvidiaOutputBitsPerColorChannel) + " bits; HDR remains off.";
                    if (preferredDepth.HasValue && (requestedBits != preferredDepth || afterColor.BitsPerColorChannel != preferredDepth || afterColor.NvidiaOutputBitsPerColorChannel != preferredDepth))
                        depthFallback = (preferredRejected ? "NVIDIA rejected the preferred " : "The final mode did not retain the preferred ") + preferredDepth.Value +
                            "-bit output with the requested range and current encoding; kept the verified HDR/refresh/range settings. " + Describe(afterColor) + ".";
                    if (requestedBits.HasValue && (afterColor.BitsPerColorChannel != requestedBits || afterColor.NvidiaOutputBitsPerColorChannel != requestedBits))
                        depthFallback = "Requested " + requestedBits.Value + "-bit output was not confirmed by both readings within five seconds; kept the verified HDR/refresh/range settings. " + Describe(afterColor) + ".";
                    else if (!preferredDepth.HasValue && (priorColor.BitsPerColorChannel != afterColor.BitsPerColorChannel || priorColor.NvidiaOutputBitsPerColorChannel != afterColor.NvidiaOutputBitsPerColorChannel))
                        depthFallback = "Range-only action changed a reported output depth. Before: " + Describe(priorColor) + ". After: " + Describe(afterColor) + ".";
                }
                CheckLayout(original, final, id, rate.HasValue);
                if (!hdr.HasValue) {
                    MonitorInfo m = Selection.ById(final, id);
                    if (m.HdrEnabled != selected.HdrEnabled || m.HdrActive != selected.HdrActive ||
                        (m.ColorMode != selected.ColorMode && !IsSdrDepthModeChange(selected, m, preferredDepth.HasValue)))
                        throw new InvalidOperationException("Refresh change unexpectedly changed HDR/color mode. Before action: " + Describe(selected) + ". After: " + Describe(m) + ".");
                }
                MonitorInfo result = Selection.ById(final, id); result.ColorRangeEnforcedByAction = range != null;
                result.PreferredBitsPerColorChannel = preferredDepth; result.ColorDepthFallbackReason = depthFallback;
                result.ColorModeTransitionNote = colorModeNote;
                Record("Verified result", final);
                return result;
            } catch (Exception failure) {
                if (!dirty) throw;
                var restorationFailures = new List<string>();
                DisplayState current = null;
                try { current = backend.Capture(); Record("Failure before restoration", current); } catch (Exception e) { restorationFailures.Add("Read current settings: " + e.Message); }
                // Disable HDR that was originally off before restoring a potentially faster SDR timing.
                foreach (MonitorInfo old in original.Monitors.Where(m => m.HdrEnabled == false)) {
                    try {
                        if (current == null || Selection.ById(current, old.MonitorId).HdrEnabled != false) {
                            backend.SetHdr(old.MonitorId, false); WaitFor(old.MonitorId, false, null);
                        }
                    } catch (Exception e) { restorationFailures.Add("Restore HDR off: " + e.Message); }
                }
                try { backend.Restore(original); } catch (Exception e) { restorationFailures.Add("Restore display configuration: " + e.Message); }
                foreach (MonitorInfo old in original.Monitors.Where(m => m.HdrEnabled == true)) {
                    try {
                        if (Selection.ById(backend.Capture(), old.MonitorId).HdrEnabled != true) backend.SetHdr(old.MonitorId, true);
                        WaitFor(old.MonitorId, true, null);
                    } catch (Exception e) { restorationFailures.Add("Restore HDR on: " + e.Message); }
                }
                // Restoring HDR itself can reset timing; restore the saved timing once more if necessary.
                try {
                    DisplayState restored = backend.Capture();
                    if (TimingChanged(original, restored)) backend.Restore(original);
                } catch (Exception e) { restorationFailures.Add("Restore timing after HDR: " + e.Message); }
                if (colorBackend != null) {
                    foreach (MonitorInfo old in original.Monitors.Where(m => m.NvidiaColorState.HasValue)) {
                        try {
                            MonitorInfo now = Selection.ById(backend.Capture(), old.MonitorId);
                            if (!now.NvidiaColorState.HasValue || !NvidiaApi.SameColor(old.NvidiaColorState.Value, now.NvidiaColorState.Value))
                                colorBackend.RestoreColor(old.MonitorId, old.NvidiaColorState.Value);
                        } catch (Exception e) { restorationFailures.Add("Restore NVIDIA output color on " + old.MonitorName + ": " + e.Message); }
                    }
                }
                // Restoring NVIDIA color can reset temporary timings just as an
                // ordinary color change can. Restore those timings before verifying.
                try {
                    if (TimingChanged(original, backend.Capture())) backend.Restore(original);
                } catch (Exception e) { restorationFailures.Add("Restore timing after NVIDIA color: " + e.Message); }
                try {
                    DisplayState restored = backend.Capture(); Record("Restoration readback", restored); CheckLayout(original, restored, null, false);
                    foreach (MonitorInfo old in original.Monitors) {
                        MonitorInfo now = Selection.ById(restored, old.MonitorId);
                        if (now.HdrEnabled != old.HdrEnabled || now.HdrActive != old.HdrActive)
                            throw new InvalidOperationException("Original HDR state was not restored on " + old.MonitorName);
                        if (old.NvidiaColorState.HasValue && (!now.NvidiaColorState.HasValue || !NvidiaApi.SameColor(old.NvidiaColorState.Value, now.NvidiaColorState.Value)))
                            throw new InvalidOperationException("Original NVIDIA output color settings were not restored on " + old.MonitorName);
                    }
                } catch (Exception e) { restorationFailures.Add("Verify restoration: " + e.Message); }
                throw new InvalidOperationException(failure.Message + (restorationFailures.Count == 0 ? " Previous settings restored." :
                    " RESTORATION FAILED: " + String.Join(" | ", restorationFailures)), failure);
            }
        }
    }

    public sealed class NativeBackend : IDisplayBackend, IColorRangeBackend {
        public const int InteropVersion = 6;
        readonly bool useNvidia;
        public NativeBackend() : this(true) { }
        public NativeBackend(bool useNvidia) { this.useNvidia = useNvidia; }
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] DisplayPath[] pathArray,
            ref uint modes, [Out] DisplayMode[] modeArray, IntPtr topology);
        [DllImport("user32.dll")] static extern int SetDisplayConfig(uint paths, [In] DisplayPath[] pathArray,
            uint modes, [In] DisplayMode[] modeArray, uint flags);
        [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetSource(ref SourceName packet);
        [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetTarget(ref TargetName packet);
        [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetColor(ref ColorInfo packet);
        [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetColor2(ref ColorInfo2 packet);
        [DllImport("user32.dll", EntryPoint = "DisplayConfigSetDeviceInfo")] static extern int SetColor(ref HdrPacket packet);
        [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);

        static bool Unsupported(int code) { return code == 87 || code == 50 || code == 120; }
        static void Check(int code, string operation) {
            if (code == 0) return;
            string hint = code == 5 ? " Run in the local interactive desktop session (not a service or Remote Desktop session)." : "";
            throw new Win32Exception(code, operation + " failed (" + code + "): " + new Win32Exception(code).Message + hint);
        }
        static Header Packet(uint type, int size, Luid adapter, uint id) {
            return new Header { Type = type, Size = (uint)size, Adapter = adapter, Id = id };
        }
        static string Key(Luid luid, uint id) { return luid.High.ToString("X8") + luid.Low.ToString("X8") + ":" + id; }
        static uint SourceIndex(DisplayPath p) { return (p.Flags & 8) != 0 ? p.Source.ModeIndex >> 16 : p.Source.ModeIndex; }
        static uint TargetIndex(DisplayPath p) { return (p.Flags & 8) != 0 ? p.Target.ModeIndex >> 16 : p.Target.ModeIndex; }
        static string Encoding(uint encoding) {
            string[] names = { "RGB", "YCbCr444", "YCbCr422", "YCbCr420", "Intensity" };
            return encoding < names.Length ? names[encoding] : "Unknown (" + encoding + ")";
        }
        static void ReadColor(DisplayPath path, MonitorInfo monitor) {
            ColorInfo2 modern = new ColorInfo2 { Header = Packet(15, Marshal.SizeOf(typeof(ColorInfo2)), path.Target.Adapter, path.Target.Id) };
            int result = GetColor2(ref modern);
            if (result == 0) {
                monitor.HdrApi = "HdrState";
                monitor.HdrSupported = (modern.Flags & 16) != 0;
                monitor.HdrEnabled = (modern.Flags & 32) != 0;
                monitor.HdrActive = modern.Mode == 2;
                monitor.ColorLimitedByPolicy = (modern.Flags & 8) != 0;
                monitor.ColorMode = modern.Mode == 0 ? "SDR" : modern.Mode == 1 ? "WCG" : modern.Mode == 2 ? "HDR" : "Unknown";
                monitor.ColorEncoding = Encoding(modern.Encoding);
                monitor.BitsPerColorChannel = modern.Bits == 0 ? (uint?)null : modern.Bits;
                return;
            }
            if (!Unsupported(result)) Check(result, "Read HDR/color information");
            ColorInfo legacy = new ColorInfo { Header = Packet(9, Marshal.SizeOf(typeof(ColorInfo)), path.Target.Adapter, path.Target.Id) };
            result = GetColor(ref legacy);
            if (Unsupported(result)) { monitor.HdrApi = "Unavailable"; monitor.ColorMode = "Unknown"; monitor.ColorEncoding = "Unknown"; return; }
            Check(result, "Read legacy Advanced Color information");
            monitor.HdrApi = "AdvancedColor";
            monitor.ColorEncoding = Encoding(legacy.Encoding);
            monitor.BitsPerColorChannel = legacy.Bits == 0 ? (uint?)null : legacy.Bits;
            monitor.ColorLimitedByPolicy = (legacy.Flags & 8) != 0;
            if ((legacy.Flags & 4) != 0) {
                monitor.ColorMode = "WCG (legacy; HDR unknown)";
            } else {
                monitor.HdrSupported = (legacy.Flags & 1) != 0;
                monitor.HdrEnabled = (legacy.Flags & 2) != 0;
                monitor.HdrActive = monitor.HdrEnabled;
                monitor.ColorMode = monitor.HdrActive == true ? "HDR (legacy inference)" : "SDR";
            }
        }
        public DisplayState Capture() {
            uint flags = 0x52; // active paths, virtual modes, virtual/physical refresh awareness
            for (int attempt = 0; attempt < 8; attempt++) {
                uint paths, modes; int error = GetDisplayConfigBufferSizes(flags, out paths, out modes);
                if (Unsupported(error) && flags != 2) { flags = flags == 0x52 ? 0x12u : 2u; continue; }
                Check(error, "Get display configuration sizes");
                DisplayPath[] pa = new DisplayPath[paths]; DisplayMode[] ma = new DisplayMode[modes];
                error = QueryDisplayConfig(flags, ref paths, pa, ref modes, ma, IntPtr.Zero);
                if (error == 122) continue; // topology changed between size and read
                if (Unsupported(error) && flags != 2) { flags = flags == 0x52 ? 0x12u : 2u; continue; }
                Check(error, "Read display configuration");
                Array.Resize(ref pa, (int)paths); Array.Resize(ref ma, (int)modes);
                var monitors = new List<MonitorInfo>();
                for (int i = 0; i < pa.Length; i++) {
                    DisplayPath p = pa[i];
                    SourceName source = new SourceName { Header = Packet(1, Marshal.SizeOf(typeof(SourceName)), p.Source.Adapter, p.Source.Id) };
                    TargetName target = new TargetName { Header = Packet(2, Marshal.SizeOf(typeof(TargetName)), p.Target.Adapter, p.Target.Id) };
                    Check(GetSource(ref source), "Read display source name"); Check(GetTarget(ref target), "Read monitor name");
                    uint si = SourceIndex(p), ti = TargetIndex(p);
                    if (si >= ma.Length || ma[si].Type != 1 || ti >= ma.Length || ma[ti].Type != 2)
                        throw new InvalidOperationException("Active display has missing source/target modes; cannot safely change its configuration.");
                    SourceMode sm = ma[si].Source; Signal signal = ma[ti].Target;
                    MonitorInfo m = new MonitorInfo { MonitorName = String.IsNullOrWhiteSpace(target.Name) ? source.Name : target.Name,
                        MonitorId = String.IsNullOrWhiteSpace(target.DevicePath) ? Key(p.Target.Adapter, p.Target.Id) : target.DevicePath,
                        DisplayName = source.Name, Width = sm.Width, Height = sm.Height, X = sm.Position.X, Y = sm.Position.Y,
                        Rotation = p.Target.Rotation, Scaling = p.Target.Scaling, SignalWidth = signal.Active.Width, SignalHeight = signal.Active.Height,
                        ScanLine = signal.ScanLine, Refresh = p.Target.Refresh.Denominator == 0 ? signal.VSync : p.Target.Refresh,
                        PhysicalRefresh = signal.VSync, DynamicRefreshRate = (p.Flags & 0x10) != 0,
                        SourceKey = Key(p.Source.Adapter, p.Source.Id), PathIndex = i };
                    ReadColor(p, m); monitors.Add(m);
                }
                DisplayState state = new DisplayState { Paths = pa, Modes = ma, QueryFlags = flags, Monitors = monitors.ToArray() };
                foreach (MonitorInfo m in state.Monitors) {
                    if (useNvidia) NvidiaApi.Read(m, pa[m.PathIndex], Selection.IsDuplicated(state, m));
                    else {
                        m.ColorRangeUnavailableReason = "NVIDIA API disabled by -NoNvidiaApi."; m.VariableRefreshRateUnavailableReason = m.ColorRangeUnavailableReason;
                        m.VariableRefreshRateSupportUnavailableReason = m.ColorRangeUnavailableReason; m.NvidiaVrrUnavailableReason = m.ColorRangeUnavailableReason;
                    }
                }
                return state;
            }
            throw new InvalidOperationException("Display configuration kept changing; retry after connecting/disconnecting displays finishes.");
        }
        public void SetHdr(string id, bool enabled) {
            DisplayState state = Capture(); MonitorInfo monitor = Selection.ById(state, id); DisplayPath path = state.Paths[monitor.PathIndex];
            if (monitor.HdrApi == "Unavailable" || !monitor.HdrEnabled.HasValue) throw new InvalidOperationException("HDR control is unavailable for this display.");
            if (monitor.HdrApi == "AdvancedColor" && monitor.HdrSupported != true) {
                if (!enabled && monitor.HdrEnabled == false) return;
                throw new InvalidOperationException("Legacy Advanced Color cannot identify an HDR-capable display.");
            }
            HdrPacket packet = new HdrPacket { Header = Packet(monitor.HdrApi == "HdrState" ? 16u : 10u,
                Marshal.SizeOf(typeof(HdrPacket)), path.Target.Adapter, path.Target.Id), Enable = enabled ? 1u : 0u };
            // Do not fall back to Advanced Color on a modern WCG display if an HDR-specific setter fails.
            Check(SetColor(ref packet), "Set HDR " + (enabled ? "on" : "off"));
        }
        public static DisplayState BuildRefreshConfig(DisplayState current, string id, Rate rate) {
            MonitorInfo m = Selection.ById(current, id);
            if (Selection.IsDuplicated(current, m))
                throw new InvalidOperationException("Cannot change one duplicated display's refresh rate independently.");
            if (rate.Numerator == 0 || rate.Denominator == 0) throw new ArgumentException("Refresh rate must be positive.");
            DisplayState candidate = current.Copy(); DisplayPath path = candidate.Paths[m.PathIndex];
            path.Target.Refresh = rate;
            // A supplied target mode takes precedence over path.Refresh. Update its rational
            // VSync as well, retaining geometry and the virtual desktop-image/target indexes.
            // Clearing the target index in a virtual-mode configuration is rejected by Windows.
            uint ti = TargetIndex(path);
            if (ti >= candidate.Modes.Length || candidate.Modes[ti].Type != 2)
                throw new InvalidOperationException("Selected display has no usable target timing.");
            DisplayMode mode = candidate.Modes[ti]; mode.Target.VSync = rate; candidate.Modes[ti] = mode;
            path.Flags &= ~0x10u; // fixed refresh, not Windows Dynamic Refresh Rate
            candidate.Paths[m.PathIndex] = path;
            return candidate;
        }
        public static uint ApplyFlags(DisplayState state, bool validate) {
            uint flags = 0x20u | (validate ? 0x40u : 0x80u);
            if ((state.QueryFlags & 0x10) != 0) flags |= 0x8000;
            if ((state.QueryFlags & 0x40) != 0) flags |= 0x20000;
            return flags; // intentionally no SAVE_TO_DATABASE or ALLOW_CHANGES
        }
        static void ApplyConfig(DisplayState state, bool validate) {
            Check(SetDisplayConfig((uint)state.Paths.Length, state.Paths, (uint)state.Modes.Length, state.Modes, ApplyFlags(state, validate)),
                validate ? "Validate requested refresh/configuration" : "Apply temporary display configuration");
        }
        public void SetRefresh(string id, Rate rate) {
            DisplayState current = Capture();
            if (!Controller.RequiresRefreshSet(Selection.ById(current, id), rate)) return;
            DisplayState candidate = BuildRefreshConfig(current, id, rate);
            ApplyConfig(candidate, true); ApplyConfig(candidate, false);
        }
        public void Restore(DisplayState state) {
            DisplayState current = Capture();
            if (current.Monitors.Length != state.Monitors.Length || state.Monitors.Any(m => !current.Monitors.Any(n => n.MonitorId == m.MonitorId && n.SourceKey == m.SourceKey)))
                throw new InvalidOperationException("Monitor connections changed; refusing to restore stale paths.");
            ApplyConfig(state, true); ApplyConfig(state, false);
        }
        public void Wait(int milliseconds) { Thread.Sleep(milliseconds); }
        public NvidiaColor SetColorRange(string id, string range, uint? preferredBits) {
            DisplayState state = Capture(); MonitorInfo m = Selection.ById(state, id);
            if (!useNvidia || !m.NvidiaColorState.HasValue || m.ColorRange == "Unknown" || Selection.IsDuplicated(state, m))
                throw new InvalidOperationException("NVIDIA range control is unavailable or ambiguous for this output.");
            NvidiaColor desired = NvidiaApi.RangeRequest(m.NvidiaColorState.Value, range, preferredBits);
            if (!NvidiaApi.RequiresColorSet(m.NvidiaColorState.Value, desired)) return desired;
            NvidiaColor request = NvidiaApi.PrepareColor(m, state.Paths[m.PathIndex], range, preferredBits);
            if (NvidiaApi.RequiresColorSet(m.NvidiaColorState.Value, request)) NvidiaApi.Set(m, state.Paths[m.PathIndex], request, false);
            return request;
        }
        public void RestoreColor(string id, NvidiaColor original) {
            DisplayState state = Capture(); MonitorInfo m = Selection.ById(state, id);
            if (!useNvidia || Selection.IsDuplicated(state, m)) throw new InvalidOperationException("Cannot restore an ambiguous NVIDIA output.");
            NvidiaApi.Set(m, state.Paths[m.PathIndex], original, true);
        }

        // Raw COM vtable access avoids a dependency on managed DXGI packages. Every obtained
        // interface is released in finally; signatures and slot numbers follow the Windows SDK.
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumInterface(IntPtr self, uint index, out IntPtr result);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int QueryInterface(IntPtr self, ref Guid iid, out IntPtr result);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint ReleaseInterface(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDesc(IntPtr self, out OutputDesc desc);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetModes(IntPtr self, uint format, uint flags, ref uint count, IntPtr modes);
        static T Method<T>(IntPtr obj, int slot) where T : class {
            IntPtr table = Marshal.ReadIntPtr(obj);
            return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(table, slot * IntPtr.Size), typeof(T)) as T;
        }
        static void Release(IntPtr obj) { if (obj != IntPtr.Zero) Method<ReleaseInterface>(obj, 2)(obj); }
        static void HResult(int result, string operation) {
            if (result < 0) throw new COMException(operation + " failed (0x" + result.ToString("X8") + ").", result);
        }
        static List<DxgiMode> ReadModes(IntPtr output, uint format) {
            GetModes get = Method<GetModes>(output, 19); var result = new List<DxgiMode>();
            for (int attempt = 0; attempt < 4; attempt++) {
                uint count = 0; int hr = get(output, format, 3, ref count, IntPtr.Zero); // include scaling and interlaced modes
                if (hr == unchecked((int)0x887A0004)) return result; // this format is unsupported
                HResult(hr, "Enumerate display modes");
                if (count == 0) return result;
                int bytes = checked((int)count * Marshal.SizeOf(typeof(DxgiMode)));
                IntPtr memory = Marshal.AllocHGlobal(bytes);
                try {
                    hr = get(output, format, 3, ref count, memory);
                    if (hr == unchecked((int)0x887A0003)) continue; // DXGI_ERROR_MORE_DATA
                    HResult(hr, "Read display modes");
                    for (int i = 0; i < count; i++) result.Add((DxgiMode)Marshal.PtrToStructure(IntPtr.Add(memory, i * Marshal.SizeOf(typeof(DxgiMode))), typeof(DxgiMode)));
                    return result;
                } finally { Marshal.FreeHGlobal(memory); }
            }
            throw new InvalidOperationException("Display mode list kept changing; retry.");
        }
        public RateInfo[] ListRates(string id) {
            MonitorInfo monitor = Selection.ById(Capture(), id);
            Guid factoryId = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            Guid outputId = new Guid("00cddea8-939b-4b83-a340-a685226666cc");
            IntPtr factory = IntPtr.Zero;
            try {
                HResult(CreateDXGIFactory1(ref factoryId, out factory), "Create DXGI factory");
                for (uint ai = 0; ; ai++) {
                    IntPtr adapter = IntPtr.Zero; int hr = Method<EnumInterface>(factory, 12)(factory, ai, out adapter);
                    if (hr == unchecked((int)0x887A0002)) break;
                    HResult(hr, "Enumerate display adapters");
                    try {
                        for (uint oi = 0; ; oi++) {
                            IntPtr output = IntPtr.Zero; hr = Method<EnumInterface>(adapter, 7)(adapter, oi, out output);
                            if (hr == unchecked((int)0x887A0002)) break;
                            HResult(hr, "Enumerate display outputs");
                            try {
                                OutputDesc desc; HResult(Method<GetDesc>(output, 7)(output, out desc), "Read DXGI output name");
                                if (!String.Equals(desc.DeviceName, monitor.DisplayName, StringComparison.OrdinalIgnoreCase)) continue;
                                IntPtr output1 = IntPtr.Zero;
                                try {
                                    HResult(Method<QueryInterface>(output, 0)(output, ref outputId, out output1), "Get DXGI Output1");
                                    var modes = ReadModes(output1, 28); modes.AddRange(ReadModes(output1, 24)); // 8/10-bit rendering formats, not output-depth setters
                                    return modes.Where(m => m.Width == monitor.SignalWidth && m.Height == monitor.SignalHeight &&
                                        (m.ScanLine == monitor.ScanLine || (m.ScanLine == 0 && monitor.ScanLine == 1)) && m.Stereo == 0 && m.Refresh.Numerator != 0 && m.Refresh.Denominator != 0)
                                        .Select(m => { Rate r = new Rate(m.Refresh.Numerator, m.Refresh.Denominator);
                                            return new RateInfo { Width = m.Width, Height = m.Height, Numerator = r.Numerator, Denominator = r.Denominator }; })
                                        .GroupBy(r => r.RefreshRateFraction).Select(g => g.First()).OrderBy(r => r.RefreshRateHz).ToArray();
                                } finally { Release(output1); }
                            } finally { Release(output); }
                        }
                    } finally { Release(adapter); }
                }
                throw new InvalidOperationException("DXGI did not expose the selected display's mode list in this session.");
            } finally { Release(factory); }
        }
        public static void ValidateLayouts() {
            NvidiaApi.ValidateLayouts();
            var expected = new Dictionary<Type, int> { { typeof(Luid), 8 }, { typeof(Header), 20 }, { typeof(Rate), 8 },
                { typeof(PathSource), 20 }, { typeof(PathTarget), 48 }, { typeof(DisplayPath), 72 }, { typeof(Signal), 48 },
                { typeof(DisplayMode), 64 }, { typeof(SourceName), 84 }, { typeof(TargetName), 420 }, { typeof(ColorInfo), 32 },
                { typeof(ColorInfo2), 36 }, { typeof(HdrPacket), 24 }, { typeof(DxgiMode), 32 }, { typeof(OutputDesc), 96 } };
            foreach (var pair in expected) if (Marshal.SizeOf(pair.Key) != pair.Value)
                throw new InvalidOperationException("Native structure layout mismatch: " + pair.Key.Name);
            if (Marshal.OffsetOf(typeof(DisplayMode), "Target").ToInt32() != 16 || Marshal.OffsetOf(typeof(PathTarget), "Refresh").ToInt32() != 28)
                throw new InvalidOperationException("Native field offset mismatch.");
        }
    }
}
'@

function Initialize-MonitorInterop {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'This script requires Windows and 64-bit PowerShell in the local desktop session.'
    }
    if (-not ('MonitorControl.NativeBackend' -as [type])) {
        Add-Type -TypeDefinition $script:MonitorInteropSource -ErrorAction Stop
    } elseif (-not [MonitorControl.NativeBackend].GetField('InteropVersion') -or [MonitorControl.NativeBackend].GetField('InteropVersion').GetValue($null) -ne 6) {
        throw 'An older version of the monitor interop is loaded. Start a fresh PowerShell session to use the updated script.'
    }
    [MonitorControl.NativeBackend]::ValidateLayouts()
}

function Write-MonitorLog {
    param([string]$Path, [string]$Level, [string]$Message)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $directory = [IO.Path]::GetDirectoryName($fullPath)
        if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
        $line = '{0} [{1}] {2}{3}' -f [DateTimeOffset]::Now.ToString('o'), $Level, $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($fullPath, $line, [Text.UTF8Encoding]::new($false))
    }
}

function ConvertTo-MonitorStatus {
    param($Monitor)
    [pscustomobject][ordered]@{
        MonitorName = $Monitor.MonitorName
        MonitorId = $Monitor.MonitorId
        DisplayName = $Monitor.DisplayName
        Width = $Monitor.Width
        Height = $Monitor.Height
        PositionX = $Monitor.X
        PositionY = $Monitor.Y
        RotationDegrees = $(switch ($Monitor.Rotation) { 1 { 0 }; 2 { 90 }; 3 { 180 }; 4 { 270 }; default { $null } })
        RefreshRateHz = $Monitor.RefreshRateHz
        RefreshRateFraction = $Monitor.RefreshRateFraction
        PhysicalRefreshRateHz = $Monitor.PhysicalRefreshRateHz
        DynamicRefreshRate = $Monitor.DynamicRefreshRate
        WindowsDynamicRefreshRate = $Monitor.WindowsDynamicRefreshRate
        VariableRefreshRateSupported = $Monitor.VariableRefreshRateSupported
        VariableRefreshRateEnabled = $Monitor.VariableRefreshRateEnabled
        VariableRefreshRateActive = $Monitor.VariableRefreshRateActive
        VariableRefreshRateRequested = $Monitor.VariableRefreshRateRequested
        DisplayInVariableRefreshRateMode = $Monitor.DisplayInVariableRefreshRateMode
        VariableRefreshRateSource = $Monitor.VariableRefreshRateSource
        VariableRefreshRateUnavailableReason = $Monitor.VariableRefreshRateUnavailableReason
        VariableRefreshRateSupportUnavailableReason = $Monitor.VariableRefreshRateSupportUnavailableReason
        NvidiaReportedVrrModeActive = $Monitor.NvidiaReportedVrrModeActive
        NvidiaVrrRawFlags = $Monitor.NvidiaVrrRawFlags
        NvidiaVrrSource = $Monitor.NvidiaVrrSource
        NvidiaVrrUnavailableReason = $Monitor.NvidiaVrrUnavailableReason
        NvidiaVrrReportingNote = $Monitor.NvidiaVrrReportingNote
        HdrSupported = $Monitor.HdrSupported
        HdrEnabled = $Monitor.HdrEnabled
        HdrActive = $Monitor.HdrActive
        ColorMode = $Monitor.ColorMode
        ColorEncoding = $Monitor.ColorEncoding
        ColorRange = $Monitor.ColorRange
        ColorRangeSource = $Monitor.ColorRangeSource
        ColorRangeEnforcedByAction = $Monitor.ColorRangeEnforcedByAction
        ColorRangePolicy = $(if ($null -ne $Monitor.NvidiaColorState) { switch ($Monitor.NvidiaColorState.Policy) { 0 { 'User' }; 1 { 'BestQuality' }; default { 'Unknown' } } } else { 'Unknown' })
        ColorRangeUnavailableReason = $Monitor.ColorRangeUnavailableReason
        BitsPerColorChannel = $Monitor.BitsPerColorChannel
        WindowsBitsPerColorChannel = $Monitor.BitsPerColorChannel
        NvidiaOutputBitsPerColorChannel = $Monitor.NvidiaOutputBitsPerColorChannel
        ColorDepthReadingsAgree = $Monitor.ColorDepthReadingsAgree
        PreferredBitsPerColorChannel = $Monitor.PreferredBitsPerColorChannel
        ColorDepthFallbackReason = $Monitor.ColorDepthFallbackReason
        ColorModeTransitionNote = $Monitor.ColorModeTransitionNote
    }
}

function Invoke-MonitorCommand {
    param([System.Collections.IDictionary]$Arguments, $Caller)
    $hasName = -not [string]::IsNullOrWhiteSpace($Arguments['MonitorName'])
    $hasId = -not [string]::IsNullOrWhiteSpace($Arguments['MonitorId'])
    $hasHdr = $Arguments.ContainsKey('Hdr')
    $hasRate = $Arguments.ContainsKey('RefreshRate')
    $hasColor = $Arguments.ContainsKey('ColorRange')
    if ($Arguments['ListMonitors']) {
        if ($hasName -or $hasId -or $hasHdr -or $hasRate -or $hasColor -or $Arguments['ListRefreshRates']) {
            throw '-ListMonitors cannot be combined with a monitor selector, setting changes, or -ListRefreshRates.'
        }
    } else {
        if ($hasName -eq $hasId) { throw 'Supply exactly one of -MonitorName or -MonitorId (or use -ListMonitors).' }
        if ($Arguments['ListRefreshRates'] -and ($hasHdr -or $hasRate -or $hasColor)) { throw '-ListRefreshRates cannot be combined with setting changes.' }
    }
    Initialize-MonitorInterop
    $rate = $null
    if ($hasRate) { $rate = [MonitorControl.Rate]::Parse($Arguments['RefreshRate']) }
    $backend = [MonitorControl.NativeBackend]::new(-not [bool]$Arguments['NoNvidiaApi'])
    if ($Arguments['ListMonitors']) {
        $backend.Capture().Monitors | ForEach-Object { ConvertTo-MonitorStatus $_ }
        return
    }
    $selected = [MonitorControl.Selection]::Resolve($backend.Capture().Monitors, $Arguments['MonitorName'], $Arguments['MonitorId'])
    if ($Arguments['ListRefreshRates']) {
        $rates = @($backend.ListRates($selected.MonitorId))
        if ($rates.Count -eq 0) { Write-Warning 'DXGI exposed no matching modes at the current signal resolution and scan mode. A custom rate can still be validated by Windows.' }
        $rates
        return
    }
    if (-not $hasHdr -and -not $hasRate -and (-not $hasColor -or $Arguments['ColorRange'] -eq 'Keep')) { ConvertTo-MonitorStatus $selected; return }
    $desiredRange = if ($hasColor) { switch ($Arguments['ColorRange']) { 'Full' { 'Full' }; 'Limited' { 'Limited' } } } else { 'AutoFull' }
    $action = 'Apply temporary refresh rate {0}; HDR {1}; output range {2}' -f $(if ($hasRate) { $rate.ToString() + ' Hz' } else { 'unchanged' }), $(if ($hasHdr) { $Arguments['Hdr'] } else { 'unchanged' }), $(if ($desiredRange -eq 'AutoFull') { 'Full on supported NVIDIA outputs' } elseif ($desiredRange) { $desiredRange } else { 'driver-selected' })
    if ($desiredRange -and ($hasHdr -or $hasRate)) { $action += '; NVIDIA output depth prefer 10-bit HDR / 8-bit SDR' }
    if (-not $Caller.ShouldProcess($selected.MonitorName + ' [' + $selected.MonitorId + ']', $action)) { return }
    $mutex = [Threading.Mutex]::new($false, 'Local\MonitorControl.DisplaySettings.v1')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another monitor action is still running; timed out after 30 seconds.' }
        # Resolve again after waiting: do not target an outdated name/connection.
        $selected = [MonitorControl.Selection]::Resolve($backend.Capture().Monitors, $Arguments['MonitorName'], $Arguments['MonitorId'])
        $desiredHdr = $null
        if ($hasHdr) { $desiredHdr = $Arguments['Hdr'] -eq 'On' }
        Write-MonitorLog $Arguments['LogPath'] 'START' ($selected.MonitorName + ': ' + $action)
        $controller = [MonitorControl.Controller]::new($backend)
        try {
            $result = $controller.Apply($selected.MonitorId, $desiredHdr, $rate, $desiredRange)
        } finally {
            if (-not [string]::IsNullOrWhiteSpace($Arguments['LogPath'])) {
                try {
                    foreach ($entry in $controller.Diagnostics) { Write-MonitorLog $Arguments['LogPath'] 'DIAGNOSTIC' $entry }
                } catch { Write-Warning ('Cannot write diagnostic log: ' + $_.Exception.Message) }
            }
        }
        if ($result.ColorModeTransitionNote) {
            Write-MonitorLog $Arguments['LogPath'] 'WARNING' $result.ColorModeTransitionNote
            Write-Warning $result.ColorModeTransitionNote
        }
        if ($desiredRange -eq 'AutoFull' -and -not $result.ColorRangeEnforcedByAction) {
            $warning = 'Output range could not be enforced. ' + $selected.ColorRangeUnavailableReason
            Write-MonitorLog $Arguments['LogPath'] 'WARNING' $warning
            Write-Warning $warning
        }
        $expectedBits = if ($result.HdrActive -eq $true) { 10 } elseif ($result.HdrActive -eq $false) { 8 } else { $null }
        if ($null -eq $result.BitsPerColorChannel -or $null -eq $expectedBits) {
            $warning = 'Windows did not report enough information to verify output color depth.'
            Write-MonitorLog $Arguments['LogPath'] 'WARNING' $warning
            Write-Warning $warning
        } elseif ($result.BitsPerColorChannel -ne $expectedBits) {
            $warning = 'Output has {0} bits per color channel; expected {1} for the current HDR state.' -f $result.BitsPerColorChannel, $expectedBits
            Write-MonitorLog $Arguments['LogPath'] 'WARNING' $warning
            Write-Warning $warning
        }
        if ($result.ColorDepthFallbackReason -or $result.ColorDepthReadingsAgree -eq $false) {
            $warning = if ($result.ColorDepthFallbackReason) { $result.ColorDepthFallbackReason } else { 'Output-depth readings disagree: Windows={0}, NVIDIA={1}. Neither reading is hidden.' -f $result.BitsPerColorChannel, $result.NvidiaOutputBitsPerColorChannel }
            Write-MonitorLog $Arguments['LogPath'] 'WARNING' $warning
            Write-Warning $warning
        }
        $status = ConvertTo-MonitorStatus $result
        Write-MonitorLog $Arguments['LogPath'] 'SUCCESS' ($status | ConvertTo-Json -Compress)
        $status
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Dot-sourcing exposes the interop source/functions for tests without accessing or changing displays.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-MonitorCommand -Arguments $PSBoundParameters -Caller $PSCmdlet
    } catch {
        $failureMessage = $_.Exception.GetBaseException().Message
        # Preserve the outer exception's restoration report rather than only its original cause.
        if ($_.Exception.Message -match 'restored|RESTORATION FAILED') { $failureMessage = $_.Exception.Message }
        try { Write-MonitorLog $LogPath 'ERROR' $failureMessage } catch { Write-Warning ('Cannot write log: ' + $_.Exception.Message) }
        Write-Error -Message $failureMessage -ErrorAction Continue
        exit 1
    }
}

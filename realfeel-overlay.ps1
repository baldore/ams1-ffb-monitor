<#
.SYNOPSIS
  Labelled, always-current RealFeel FFB readout with peak-hold, drawn on top
  of Automobilista.

.DESCRIPTION
  RealFeel's own console prints one unlabelled line of numbers that scrolls
  away constantly. That format lives in RealFeelPlugin.dll and cannot be
  changed, so this reads the console's screen buffer and renders its own
  window instead:

    - every field labelled
    - always shows the LATEST line, held on screen, no scrolling
    - MAX GAIN: peak-hold of the output percentage, so you can drive a lap and
      then read off what the highest load actually was
    - clip counter: how many samples sat at or above the clip threshold

  Nothing is injected into the game and nothing is written back. It is a
  read-only view of text the game already prints.

  WHY THIS BUILDS AN EXE
  Reading another process's console requires AttachConsole(), and a process
  can only be attached to one console at a time - so it must FreeConsole()
  first. powershell.exe is a console application whose host exits when its
  console goes away, so a PowerShell-hosted overlay dies the moment it
  attaches. SetConsoleCtrlHandler does not help; the problem is structural.
  So the overlay is compiled to a Windows-subsystem exe, which never has a
  console to lose. The exe is rebuilt automatically whenever this script is
  newer than it.

  Requires ConsoleEnabled=True in RealFeelPlugin.ini and the game in
  borderless windowed mode (Config.ini: WindowedMode=1, WindowBorders=0).

.EXAMPLE
  .\realfeel-overlay.ps1

.EXAMPLE
  .\realfeel-overlay.ps1 -Corner BottomLeft

.EXAMPLE
  .\realfeel-overlay.ps1 -SelfTest -TestPid 1234
  Headless check of the reader and parser against another console.

.NOTES
  Drag         - move the window
  Double-click - reset peak and clip counter
  R            - reset peak
  Right-click  - menu
  Esc          - close
#>
[CmdletBinding()]
param(
    [ValidateSet('TopRight','TopLeft','BottomRight','BottomLeft')]
    [string]$Corner = 'TopRight',
    [int]$Margin = 12,
    [int]$ClipThreshold = 100,
    [int]$PollMs = 100,

    # Seconds to keep a clipping peak on screen before clearing it, so a lap
    # can be swept for every clipping point rather than only the first.
    [int]$ClipHoldSeconds = 4,

    # --- MOZA wheel rotation ------------------------------------------------
    # Profile Controller.ini AMS writes the car's rotation into.
    [string]$ProfileIni = 'C:\Users\acorn\OneDrive\Documents\Automobilista\userdata\Orregoso\Controller.ini',

    # Folder holding MOZA_API_CSharp.dll, MOZA_API_C.dll and MOZA_SDK.dll.
    [string]$MozaLib,

    # limitAngle is raised to this once so per-car values are never clamped.
    [int]$MaxLimit = 2000,
    [int]$RotationPollMs = 1000,

    # Show the rotation rows but never write to the base.
    [switch]$RotationDryRun,

    # Turn rotation control off entirely; the FFB monitor is unaffected.
    [switch]$NoRotation,

    # How long a probed key is held down. RealFeel polls with GetKeyState
    # roughly every 100ms, so the key must stay down longer than that or the
    # poll can miss it entirely.
    [int]$HoldMs = 150,

    # Start with the FFB control rows already open.
    [switch]$StartExpanded,

    # RealFeelPlugin.ini of the game. Only used to guess the car from its
    # MaxForceAtSteeringRack once "Vehicle acquired" has scrolled out of the
    # console. The script no longer lives in the game folder, hence the path.
    [string]$IniPath = 'C:\Program Files (x86)\Steam\steamapps\common\Automobilista\RealFeelPlugin.ini',

    # Read another process's console instead of AMS. For testing.
    [int]$TestPid = 0,

    # Headless check of the console reader + parser: attach, read, print what
    # was parsed, exit. Runs in-process; does not build or launch the exe.
    [switch]$SelfTest,

    # Rebuild the exe even if it looks current.
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

$Source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Text.RegularExpressions;
using System.Windows.Forms;

public class RfReader {
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec,
                                     uint disp, uint flags, IntPtr templ);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len,
                                                   COORD coord, out uint read);

    [StructLayout(LayoutKind.Sequential)] public struct COORD {
        public short X, Y;
        public COORD(short x, short y) { X = x; Y = y; }
    }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD dwSize;
        public COORD dwCursorPosition;
        public ushort wAttributes;
        public SMALL_RECT srWindow;
        public COORD dwMaximumWindowSize;
    }

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;

    IntPtr h = IntPtr.Zero;
    int attachedPid = 0;

    public int AttachedPid { get { return attachedPid; } }
    public bool IsAttached { get { return h != IntPtr.Zero; } }

    // Ignore console control events. AMS closing its console delivers
    // CTRL_CLOSE_EVENT to every attached process, and the default handler
    // terminates them - which would take the overlay down with the game.
    public static void IgnoreCtrlEvents() { SetConsoleCtrlHandler(IntPtr.Zero, true); }

    public void Detach() {
        if (h != IntPtr.Zero) { CloseHandle(h); h = IntPtr.Zero; }
        if (attachedPid != 0) { FreeConsole(); attachedPid = 0; }
    }

    // A process can be attached to only one console at a time, so drop ours first.
    public bool Attach(int pid) {
        IgnoreCtrlEvents();
        Detach();
        FreeConsole();
        if (!AttachConsole((uint)pid)) return false;
        IgnoreCtrlEvents();   // re-arm against the console we just joined
        h = CreateFileW("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                        OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == new IntPtr(-1)) { h = IntPtr.Zero; FreeConsole(); return false; }
        attachedPid = pid;
        return true;
    }

    // Last `maxLines` rows ending at the cursor. Null if the console is gone.
    public string[] ReadTail(int maxLines) {
        if (h == IntPtr.Zero) return null;
        CONSOLE_SCREEN_BUFFER_INFO info;
        if (!GetConsoleScreenBufferInfo(h, out info)) return null;
        int width = info.dwSize.X;
        if (width <= 0) return null;
        int endY   = info.dwCursorPosition.Y;
        int startY = Math.Max(0, endY - maxLines + 1);
        var lines = new List<string>();
        var buf = new char[width];
        for (int y = startY; y <= endY; y++) {
            uint read;
            if (!ReadConsoleOutputCharacterW(h, buf, (uint)width, new COORD(0, (short)y), out read))
                continue;
            lines.Add(new string(buf, 0, (int)read).TrimEnd());
        }
        return lines.ToArray();
    }
}

public class RfSample {
    public int MaxForce, Smoothing, Damper, Mix, InputMax, ForceRaw, ForceOut, OutPct;
    public double GripEffect, GripL, GripR;
    public bool Saturated;          // the "+++" marker
    public string Raw = "";
}

public class RfParser {
    // %.5i %.1i %.5i %.3i%% %.5i %.5i %.5i %.3i%% %.1f %.2f %.2f [+++]
    static readonly Regex Tele = new Regex(
        @"^\s*(-?\d+)\s+(\d+)\s+(-?\d+)\s+(\d+)%\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(\d+)%" +
        @"\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*(\+\+\+)?\s*$",
        RegexOptions.Compiled);

    static readonly Regex Veh = new Regex(@"Vehicle acquired\s*\[(.+?)\]", RegexOptions.Compiled);

    public static RfSample ParseLine(string line) {
        var m = Tele.Match(line);
        if (!m.Success) return null;
        var ci = System.Globalization.CultureInfo.InvariantCulture;
        var s = new RfSample();
        s.MaxForce   = int.Parse(m.Groups[1].Value, ci);
        s.Smoothing  = int.Parse(m.Groups[2].Value, ci);
        s.Damper     = int.Parse(m.Groups[3].Value, ci);
        s.Mix        = int.Parse(m.Groups[4].Value, ci);
        s.InputMax   = int.Parse(m.Groups[5].Value, ci);
        s.ForceRaw   = int.Parse(m.Groups[6].Value, ci);
        s.ForceOut   = int.Parse(m.Groups[7].Value, ci);
        s.OutPct     = int.Parse(m.Groups[8].Value, ci);
        s.GripEffect = double.Parse(m.Groups[9].Value, ci);
        s.GripL      = double.Parse(m.Groups[10].Value, ci);
        s.GripR      = double.Parse(m.Groups[11].Value, ci);
        s.Saturated  = m.Groups[12].Success;
        s.Raw        = line.Trim();
        return s;
    }

    public static RfSample LatestSample(string[] lines) {
        if (lines == null) return null;
        for (int i = lines.Length - 1; i >= 0; i--) {
            var s = ParseLine(lines[i]);
            if (s != null) return s;
        }
        return null;
    }

    public static string LatestVehicle(string[] lines) {
        if (lines == null) return null;
        for (int i = lines.Length - 1; i >= 0; i--) {
            var m = Veh.Match(lines[i]);
            if (m.Success) return m.Groups[1].Value.Trim();
        }
        return null;
    }

    // MaxForceAtSteeringRack -> section names using it. "Vehicle acquired"
    // prints once and scrolls out of the console buffer within seconds, so
    // when it is gone the car can still be guessed from its max-force value.
    // Not always unique: cars sharing a value are all listed.
    public static Dictionary<int, string> CarsByForce(string iniPath) {
        var map = new Dictionary<int, List<string>>();
        var flat = new Dictionary<int, string>();
        if (!File.Exists(iniPath)) return flat;
        string section = null;
        foreach (string raw in File.ReadAllLines(iniPath)) {
            string line = raw.Trim();
            if (line.StartsWith("[") && line.EndsWith("]")) {
                section = line.Substring(1, line.Length - 2);
                continue;
            }
            if (section == null || section == "General") continue;
            if (!line.StartsWith("MaxForceAtSteeringRack=")) continue;
            double d;
            if (!double.TryParse(line.Substring("MaxForceAtSteeringRack=".Length),
                                 System.Globalization.NumberStyles.Float,
                                 System.Globalization.CultureInfo.InvariantCulture, out d)) continue;
            int key = (int)Math.Round(d);
            if (!map.ContainsKey(key)) map[key] = new List<string>();
            if (!map[key].Contains(section)) map[key].Add(section);
        }
        foreach (var kv in map) flat[kv.Key] = string.Join(" / ", kv.Value.ToArray());
        return flat;
    }
}

// Synthetic Right-Ctrl + key, for driving RealFeel's hotkeys without a
// physical Right Ctrl.
//
// RealFeel reads the keyboard with GetKeyState and nothing else (verified
// against the DLL's imports). That dictates everything here:
//
//   - GetKeyState reads the FOREGROUND thread's key state, so AMS must be
//     foreground when the input lands. The overlay's WS_EX_NOACTIVATE means
//     clicking its buttons does not steal focus, which is what makes this
//     possible at all.
//   - PostMessage(WM_KEYDOWN) does NOT update the state GetKeyState reads,
//     so SendInput is the only mechanism that works.
//   - The key must stay down long enough for RealFeel to poll it at least
//     once (ConsoleRepeatDelay/KeyRepeatDelay are 0.1s), so press and
//     release are separated by HoldMs on a background thread rather than
//     sent as one burst.
public class RfKeys {
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT {
        public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT {
        public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] struct HARDWAREINPUT {
        public uint uMsg; public ushort wParamL, wParamH;
    }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)] struct INPUT {
        public uint type; public InputUnion U;
    }

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001;

    public const ushort VK_RCONTROL = 0xA3;   // extended
    public const ushort VK_LCONTROL = 0xA2;   // not extended

    // RealFeel's documented hotkey map. Numpad digits are NOT extended keys.
    // Right Ctrl is the fine step, Left Ctrl the coarse one.
    //
    //   Ctrl + Num 7/8/9  MaxForceAtSteeringRack  (down / reverse / up)
    //   Ctrl + Num 4/5/6  SteeringDamper          (down / reset  / up)
    //   Ctrl + Num 1/2/3  RealFeel mix            (-10% / toggle / +10%)
    //   RCtrl + Num 0/.   SmoothingLevel          (down / up)
    //
    // The sizes below are what the community sources state. They disagree with
    // themselves about the damper steps, so each button reports the delta it
    // actually produced rather than trusting the label.
    public class Action {
        public string Label;      // button text
        public string Group;      // row heading
        public ushort Mod;        // VK_RCONTROL or VK_LCONTROL
        public bool   ModExt;
        public ushort Vk;
        public Action(string label, string group, ushort mod, bool modExt, ushort vk) {
            Label = label; Group = group; Mod = mod; ModExt = modExt; Vk = vk;
        }
    }

    const ushort NUM0 = 0x60, NUM1 = 0x61, NUM2 = 0x62, NUM3 = 0x63, NUM4 = 0x64;
    const ushort NUM5 = 0x65, NUM6 = 0x66, NUM7 = 0x67, NUM8 = 0x68, NUM9 = 0x69;
    const ushort NUMDOT = 0x6E;

    public static Action[] Actions = new Action[] {
        new Action("-1000", "Max force", VK_LCONTROL, false, NUM7),
        new Action("-100",  "Max force", VK_RCONTROL, true,  NUM7),
        new Action("+100",  "Max force", VK_RCONTROL, true,  NUM9),
        new Action("+1000", "Max force", VK_LCONTROL, false, NUM9),

        new Action("-100",  "Damper",    VK_RCONTROL, true,  NUM4),
        new Action("-10",   "Damper",    VK_LCONTROL, false, NUM4),
        new Action("+10",   "Damper",    VK_LCONTROL, false, NUM6),
        new Action("+100",  "Damper",    VK_RCONTROL, true,  NUM6),

        new Action("-",     "Smoothing", VK_RCONTROL, true,  NUM0),
        new Action("+",     "Smoothing", VK_RCONTROL, true,  NUMDOT),

        new Action("-10%",  "Mix",       VK_RCONTROL, true,  NUM1),
        new Action("+10%",  "Mix",       VK_RCONTROL, true,  NUM3),
    };

    public static bool IsForeground(int pid) {
        uint fp; GetWindowThreadProcessId(GetForegroundWindow(), out fp);
        return (int)fp == pid;
    }

    static INPUT Key(ushort vk, bool extended, bool up) {
        uint flags = 0;
        if (extended) flags |= KEYEVENTF_EXTENDEDKEY;
        if (up)       flags |= KEYEVENTF_KEYUP;
        var i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.U.ki.wVk = vk;
        i.U.ki.dwFlags = flags;
        return i;
    }

    static void Send(params INPUT[] inputs) {
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // Press modifier+key, hold, release. Runs off the UI thread so the hold
    // does not freeze the overlay. Right Ctrl must carry the extended flag or
    // it arrives as Left Ctrl - which would silently apply the coarse step
    // instead of the fine one.
    public static void Tap(Action a, int holdMs) {
        var t = new System.Threading.Thread(delegate() {
            try {
                Send(Key(a.Mod, a.ModExt, false), Key(a.Vk, false, false));
                System.Threading.Thread.Sleep(holdMs);
                Send(Key(a.Vk, false, true), Key(a.Mod, a.ModExt, true));
            } catch { }
        });
        t.IsBackground = true;
        t.Start();
    }
}

// Keeps the MOZA wheelbase rotation matched to the car, and exposes a snapshot
// for the overlay to draw.
//
// AMS writes the car's rotation into the profile Controller.ini as "Steering
// Wheel Range", full lock-to-lock, within seconds of a car change. The same
// file is rewritten every few seconds with identical content, so this fires on
// the VALUE changing, never on the timestamp.
//
// The SDK is called by REFLECTION on purpose: a compile-time reference would
// make the whole overlay fail to build when the MOZA DLLs are absent or moved,
// which would take the FFB monitor down over an optional extra. Missing DLLs
// here just disable rotation and leave a note on screen.
public class RfRotation {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetDllDirectoryW(string p);

    readonly string iniPath, libPath, statePath;
    readonly int    maxLimit, pollMs;
    readonly bool   dryRun;

    Thread worker;
    volatile bool stopping;

    // SDK entry points, resolved once at startup.
    object   sdkType;   // System.Type for mozaAPI.mozaAPI
    Type     errType;   // mozaAPI.ERRORCODE
    MethodInfo miInstall, miRemove, miGet, miSet;

    readonly object gate = new object();
    bool   connected = false;
    int    baseLimit = 0, baseGameMax = 0, carRange = 0;
    string status = "starting";

    public RfRotation(string iniPath, string libPath, int maxLimit, int pollMs, bool dryRun, string statePath) {
        this.iniPath   = iniPath;
        this.libPath   = libPath;
        this.maxLimit  = maxLimit;
        this.pollMs    = pollMs;
        this.dryRun    = dryRun;
        this.statePath = statePath;
    }

    // Record what the base looked like before we touched it, once, so
    // rotation-watcher.ps1 -Restore has something truthful to write back.
    void SaveOriginal(int limit, int gameMax) {
        try {
            if (statePath.Length == 0 || File.Exists(statePath)) return;
            File.WriteAllText(statePath, string.Format(
                "{{\r\n    \"Saved\":  \"{0}\",\r\n    \"OrigGameMax\":  {1},\r\n    \"OrigLimit\":  {2}\r\n}}\r\n",
                DateTime.Now.ToString("s"), gameMax, limit));
        } catch { }
    }

    public void Snapshot(out bool conn, out int limit, out int gameMax, out int car, out string st) {
        lock (gate) { conn = connected; limit = baseLimit; gameMax = baseGameMax; car = carRange; st = status; }
    }
    void SetStatus(string s) { lock (gate) { status = s; } }

    public void Start() {
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }
    public void Stop() {
        stopping = true;
        try { if (miRemove != null) miRemove.Invoke(null, null); } catch { }
    }

    bool LoadSdk() {
        try {
            string dll = Path.Combine(libPath, "MOZA_API_CSharp.dll");
            if (!File.Exists(dll)) { SetStatus("no SDK in lib\\moza"); return false; }
            SetDllDirectoryW(libPath);                       // for the native halves
            Assembly asm = Assembly.LoadFrom(dll);
            Type t  = asm.GetType("mozaAPI.mozaAPI");
            errType = asm.GetType("mozaAPI.ERRORCODE");
            if (t == null || errType == null) { SetStatus("SDK types not found"); return false; }
            sdkType   = t;
            miInstall = t.GetMethod("installMozaSDK");
            miRemove  = t.GetMethod("removeMozaSDK");
            miGet     = t.GetMethod("getMotorLimitAngle");
            miSet     = t.GetMethod("setMotorLimitAngle");
            if (miInstall == null || miGet == null || miSet == null) { SetStatus("SDK methods not found"); return false; }
            return true;
        } catch (Exception ex) {
            SetStatus("SDK load failed: " + ex.GetType().Name);
            return false;
        }
    }

    // The base comes up through three states: NODEVICES, then NORMAL with
    // zeros, then NORMAL with the real value. The middle one lies, so anything
    // under the SDK's documented 90 degree minimum is not a real reading.
    bool TryRead(out int limit, out int gameMax) {
        limit = 0; gameMax = 0;
        try {
            // Sentinel rather than NORMAL: if the call never writes the ref,
            // a pre-set NORMAL would look like success.
            object err = Enum.Parse(errType, "PARAMETERERR");
            object[] args = new object[] { err };
            object res = miGet.Invoke(null, args);
            if (args[0] == null || args[0].ToString() != "NORMAL" || res == null) return false;
            Type tt = res.GetType();
            limit   = (int)tt.GetProperty("Item1").GetValue(res, null);
            gameMax = (int)tt.GetProperty("Item2").GetValue(res, null);
            return limit >= 90 && gameMax >= 90;
        } catch { return false; }
    }

    bool TryWrite(int limit, int gameMax) {
        try {
            object err = miSet.Invoke(null, new object[] { limit, gameMax });
            if (err == null || err.ToString() != "NORMAL") { SetStatus("set failed: " + err); return false; }
        } catch (Exception ex) { SetStatus("set threw: " + ex.GetType().Name); return false; }

        // MOZA's own sample calls setMotorLimitAngle(150,200), which breaks
        // their documented constraint, so trust only the read-back.
        Thread.Sleep(300);
        int l, g;
        for (int i = 0; i < 5 && !stopping; i++) {
            if (TryRead(out l, out g)) {
                if (l == limit && g == gameMax) { lock (gate) { baseLimit = l; baseGameMax = g; } return true; }
                SetStatus(string.Format("read-back {0}/{1}, asked {2}/{3}", l, g, limit, gameMax));
                return false;
            }
            Thread.Sleep(300);
        }
        SetStatus("read-back failed");
        return false;
    }

    public static int ReadCarRange(string path) {
        try {
            if (!File.Exists(path)) return 0;
            foreach (string raw in File.ReadAllLines(path)) {
                if (!raw.StartsWith("Steering Wheel Range=")) continue;
                int a = raw.IndexOf('"'), b = raw.IndexOf('"', a + 1);
                if (a < 0 || b < 0) return 0;
                int v;
                if (int.TryParse(raw.Substring(a + 1, b - a - 1), out v)) return v;
                return 0;
            }
        } catch { }
        return 0;
    }

    void Run() {
        if (!LoadSdk()) return;

        try { miInstall.Invoke(null, null); } catch (Exception ex) { SetStatus("install failed: " + ex.GetType().Name); return; }

        SetStatus("connecting");
        int limit = 0, gameMax = 0;
        DateTime deadline = DateTime.UtcNow.AddSeconds(30);
        while (!stopping && DateTime.UtcNow < deadline) {
            if (TryRead(out limit, out gameMax)) break;
            Thread.Sleep(500);
        }
        if (stopping) return;
        if (limit < 90) { SetStatus("base not found"); return; }

        lock (gate) { connected = true; baseLimit = limit; baseGameMax = gameMax; }
        SaveOriginal(limit, gameMax);
        SetStatus(dryRun ? "dry run" : "ready");

        // gameMaximumAngle can never exceed limitAngle, so lift the ceiling
        // once; a base left at 450 would clamp a 540 car silently.
        if (limit < maxLimit) {
            if (dryRun) { SetStatus("dry run (would raise limit)"); limit = maxLimit; }
            else if (TryWrite(maxLimit, gameMax)) { limit = maxLimit; SetStatus("ready"); }
            else SetStatus("limit stuck at " + limit);
        }

        int applied = -1;
        while (!stopping) {
            bool amsUp = Process.GetProcessesByName("AMS").Length > 0;
            int range = ReadCarRange(iniPath);
            lock (gate) { carRange = range; }

            if (amsUp && range > 0 && range != applied) {
                int target = Math.Min(range, limit);
                if (target < 90) target = 90;
                if (dryRun) {
                    SetStatus(string.Format("dry run: would set {0}", target));
                    applied = range;
                } else if (TryWrite(limit, target)) {
                    SetStatus(target == range ? "ready" : "clamped to " + target);
                    applied = range;
                }
            }
            if (!amsUp) applied = -1;
            Thread.Sleep(pollMs);
        }
    }
}

public class RfOverlay : Form {
    readonly RfReader reader = new RfReader();
    // Qualified: System.Threading is imported for the rotation worker, which
    // makes a bare Timer ambiguous.
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    readonly Label body = new Label();
    readonly Label peak = new Label();
    readonly Label status = new Label();

    readonly int clipThreshold;
    readonly int testPid;
    readonly int holdMs;
    readonly int clipHoldMs;
    readonly RfRotation rotation;     // null when rotation control is off
    Dictionary<int, string> carsByForce = new Dictionary<int, string>();

    int  peakPct = 0;
    int  peakForce = 0;
    long clipSamples = 0;

    // Clip hold: once a sample reaches the threshold the peak is frozen on
    // screen for a few seconds and then cleared, so a lap can be swept for
    // every clipping point instead of showing only the first one. The event
    // counter ticks on the rising edge, so one long slide counts once even
    // though the hold may expire and re-arm during it.
    int      clipEvents = 0;
    bool     holding = false;
    bool     wasClipping = false;
    DateTime holdUntil = DateTime.MinValue;
    string vehicle = null;
    bool justAttached = false;

    // Key-probe state. After sending a candidate we wait a few ticks, then
    // diff the tunable fields to see which one (if any) the key moved.
    readonly Label probeResult = new Label();
    readonly Panel controlsPanel = new Panel();
    Button toggleBtn = null;
    bool controlsShown = false;          // hidden by default
    const int ControlsHeight = 124;
    const int ToggleTop = 436;           // just under the status text
    const int PanelTop  = 464;           // controls hang below the toggle
    RfSample lastSample = null;
    RfSample probeBefore = null;
    string probeKeyName = null;
    int  probeTicksLeft = 0;

    Point dragFrom;
    bool dragging = false;

    // Never steal focus from the game.
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000008;   // WS_EX_TOPMOST
            return cp;
        }
    }

    public RfOverlay(int clipThreshold, int pollMs, int testPid, string iniPath, int holdMs, bool startExpanded, int clipHoldMs, RfRotation rotation) {
        this.clipThreshold = clipThreshold;
        this.testPid = testPid;
        this.holdMs = holdMs;
        this.clipHoldMs = clipHoldMs;
        this.rotation = rotation;
        try { carsByForce = RfParser.CarsByForce(iniPath); } catch { }

        FormBorderStyle = FormBorderStyle.None;
        TopMost         = true;
        ShowInTaskbar   = false;
        BackColor       = Color.FromArgb(16, 16, 20);
        Opacity         = 0.88;
        // Sized from a captured render: the body needs all 13 lines, and the
        // peak line needs room for "MAX GAIN  100%  (4000)" without clipping.
        Width           = 420;
        KeyPreview      = true;

        var mono  = new Font("Consolas", 10f, FontStyle.Regular);
        var small = new Font("Consolas", 8.5f, FontStyle.Regular);

        // --- toggle and controls sit BELOW the readout ---------------------
        // Keeping them at the bottom means the readout never moves when the
        // panel opens or closes - only the window's lower edge changes.
        toggleBtn = MakeButton("FFB controls  [+]", 12, ToggleTop, 150);
        toggleBtn.Click += delegate { SetControlsShown(!controlsShown); };
        Controls.Add(toggleBtn);

        // --- one labelled row per adjustable value, inside the panel -------
        controlsPanel.Location  = new Point(0, PanelTop);
        controlsPanel.Size      = new Size(420, ControlsHeight);
        controlsPanel.BackColor = Color.Transparent;

        string[] groups = new string[] { "Max force", "Damper", "Smoothing", "Mix" };
        int rowY = 2;
        foreach (string g in groups) {
            var lab = new Label();
            lab.Text      = g;
            lab.Font      = small;
            lab.ForeColor = Color.Gainsboro;
            lab.AutoSize  = false;
            lab.Location  = new Point(12, rowY + 4);
            lab.Size      = new Size(78, 20);
            lab.TextAlign = ContentAlignment.MiddleLeft;
            controlsPanel.Controls.Add(lab);

            int bx = 94;
            foreach (RfKeys.Action a in RfKeys.Actions) {
                if (a.Group != g) continue;
                RfKeys.Action captured = a;          // don't capture the loop variable
                var b = MakeButton(a.Label, bx, rowY, 70);
                b.Click += delegate { SendAction(captured); };
                controlsPanel.Controls.Add(b);
                bx += 76;
            }
            rowY += 30;
        }
        Controls.Add(controlsPanel);

        // Everything above the toggle has a fixed position now, so opening the
        // panel cannot shift the readout.
        probeResult.Font      = small;
        probeResult.ForeColor = Color.Gold;
        probeResult.AutoSize  = false;
        probeResult.Location  = new Point(12, 8);
        probeResult.Size      = new Size(396, 18);

        body.Font      = mono;
        body.ForeColor = Color.Gainsboro;
        body.AutoSize  = false;
        body.Location  = new Point(12, 30);
        body.Size      = new Size(396, 296);   // 13 base rows + the rotation block

        // 15pt, not 17: with the HOLD countdown appended the line reaches 33
        // characters, which wrapped into the status text at the larger size.
        peak.Font      = new Font("Consolas", 15f, FontStyle.Bold);
        peak.ForeColor = Color.LimeGreen;
        peak.AutoSize  = false;
        peak.Location  = new Point(12, 330);
        peak.Size      = new Size(396, 34);
        peak.TextAlign = ContentAlignment.MiddleLeft;

        status.Font      = small;
        status.ForeColor = Color.DimGray;
        status.AutoSize  = false;
        status.Location  = new Point(12, 370);
        status.Size      = new Size(396, 60);

        Controls.Add(probeResult);
        Controls.Add(body);
        Controls.Add(peak);
        Controls.Add(status);

        SetControlsShown(startExpanded);

        var menu = new ContextMenuStrip();
        menu.Items.Add("Reset peak", null, delegate { ResetPeak(); });
        menu.Items.Add("Close",      null, delegate { Close(); });
        ContextMenuStrip = menu;

        foreach (Control c in new Control[] { this, body, peak, status, probeResult }) {
            c.MouseDown   += OnDragStart;
            c.MouseMove   += OnDragMove;
            c.MouseUp     += OnDragEnd;
            c.DoubleClick += delegate { ResetPeak(); };
            c.ContextMenuStrip = menu;
        }

        KeyDown += delegate(object s, KeyEventArgs e) {
            if (e.KeyCode == Keys.Escape) Close();
            if (e.KeyCode == Keys.R)      ResetPeak();
        };

        timer.Interval = pollMs;
        timer.Tick += OnTick;
        timer.Start();

        Render(null, "starting...");
    }

    void OnDragStart(object s, MouseEventArgs e) {
        if (e.Button != MouseButtons.Left) return;
        dragging = true; dragFrom = e.Location;
    }
    void OnDragMove(object s, MouseEventArgs e) {
        if (!dragging) return;
        Location = new Point(Location.X + e.X - dragFrom.X, Location.Y + e.Y - dragFrom.Y);
    }
    void OnDragEnd(object s, MouseEventArgs e) { dragging = false; }

    public void ResetPeak() {
        peakPct = 0; peakForce = 0; clipSamples = 0;
        clipEvents = 0; holding = false; wasClipping = false;
    }

    Button MakeButton(string text, int x, int y, int w) {
        var b = new Button();
        b.Text      = text;
        b.Location  = new Point(x, y);
        b.Size      = new Size(w, 24);
        b.FlatStyle = FlatStyle.Flat;
        b.BackColor = Color.FromArgb(34, 34, 42);
        b.ForeColor = Color.Gainsboro;
        b.Font      = new Font("Consolas", 8.5f, FontStyle.Bold);
        b.TabStop   = false;      // never take focus from the game
        b.FlatAppearance.BorderColor = Color.DimGray;
        return b;
    }

    // The control rows live in a panel so the readout collapses back to its
    // original size when they are hidden - no dead space left behind. The
    // window grows downward, which suits the default top-right corner.
    void SetControlsShown(bool show) {
        controlsShown         = show;
        controlsPanel.Visible = show;
        toggleBtn.Text        = show ? "FFB controls  [-]" : "FFB controls  [+]";

        // Only the lower edge moves. Nothing above the toggle is repositioned.
        Height = (show ? PanelTop + ControlsHeight : ToggleTop + 24) + 12;
        ClampToScreen();
    }

    // Growing downward would push the panel off-screen when the overlay is
    // parked near the bottom, so pull the window back inside the work area
    // after any resize.
    void ClampToScreen() {
        try {
            var wa = Screen.FromControl(this).WorkingArea;
            int nx = Location.X, ny = Location.Y;
            if (ny + Height > wa.Bottom) ny = Math.Max(wa.Top,  wa.Bottom - Height);
            if (nx + Width  > wa.Right)  nx = Math.Max(wa.Left, wa.Right  - Width);
            if (nx != Location.X || ny != Location.Y) Location = new Point(nx, ny);
        } catch { }
    }

    // Snapshot the values, fire the hotkey, then report the delta it actually
    // produced a few ticks later. The reported delta is the source of truth -
    // the button labels come from community docs that contradict themselves
    // about the damper step sizes.
    void SendAction(RfKeys.Action a) {
        int pid = FindPid();
        if (pid == 0) {
            probeResult.ForeColor = Color.Tomato;
            probeResult.Text = "AMS is not running";
            return;
        }
        if (!RfKeys.IsForeground(pid)) {
            probeResult.ForeColor = Color.Tomato;
            probeResult.Text = "click the GAME window first - it must be focused";
            return;
        }
        if (lastSample == null) {
            probeResult.ForeColor = Color.Tomato;
            probeResult.Text = "no telemetry yet - RealFeel keys only work on track";
            return;
        }
        probeBefore    = lastSample;
        probeKeyName   = a.Group + " " + a.Label;
        probeTicksLeft = Math.Max(5, 500 / Math.Max(1, timer.Interval));
        probeResult.ForeColor = Color.Gold;
        probeResult.Text = probeKeyName + " ...";
        RfKeys.Tap(a, holdMs);
    }

    void EvaluateProbe(RfSample after) {
        if (probeBefore == null || after == null) return;
        var diffs = new List<string>();
        if (after.MaxForce  != probeBefore.MaxForce)  diffs.Add("MaxForce "  + probeBefore.MaxForce  + "->" + after.MaxForce);
        if (after.Damper    != probeBefore.Damper)    diffs.Add("Damper "    + probeBefore.Damper    + "->" + after.Damper);
        if (after.Smoothing != probeBefore.Smoothing) diffs.Add("Smoothing " + probeBefore.Smoothing + "->" + after.Smoothing);
        if (after.Mix       != probeBefore.Mix)       diffs.Add("Mix "       + probeBefore.Mix       + "->" + after.Mix);
        if (diffs.Count == 0) {
            probeResult.ForeColor = Color.DimGray;
            probeResult.Text = probeKeyName + ": no change";
        } else {
            probeResult.ForeColor = Color.LimeGreen;
            probeResult.Text = probeKeyName + ": " + string.Join(", ", diffs.ToArray());
        }
        probeBefore = null;
    }

    int FindPid() {
        if (testPid != 0) {
            try { Process.GetProcessById(testPid); return testPid; } catch { return 0; }
        }
        var p = Process.GetProcessesByName("AMS");
        return p.Length > 0 ? p[0].Id : 0;
    }

    void OnTick(object sender, EventArgs e) {
        int pid = FindPid();
        if (pid == 0) {
            if (reader.IsAttached) { reader.Detach(); ResetPeak(); vehicle = null; }
            Render(null, testPid != 0 ? "waiting for test pid..." : "waiting for AMS...");
            return;
        }
        if (!reader.IsAttached || reader.AttachedPid != pid) {
            ResetPeak(); vehicle = null;
            if (!reader.Attach(pid)) {
                Render(null, "found pid " + pid + ", cannot attach to its console");
                return;
            }
            justAttached = true;
        }

        // Sweep deeper on the first read, in case "Vehicle acquired" is still
        // in the buffer. It usually is not - the telemetry line prints about
        // ten times a second and pushes it out within seconds.
        var lines = reader.ReadTail(justAttached ? 4000 : 80);
        justAttached = false;
        if (lines == null) { reader.Detach(); Render(null, "console went away, retrying..."); return; }

        var v = RfParser.LatestVehicle(lines);
        if (v != null && v != vehicle) { vehicle = v; ResetPeak(); }

        var s = RfParser.LatestSample(lines);
        if (s == null) { Render(null, "attached to pid " + pid + ", no telemetry line yet"); return; }

        lastSample = s;
        if (probeTicksLeft > 0) {
            probeTicksLeft--;
            if (probeTicksLeft == 0) EvaluateProbe(s);
        }

        int  absOut     = Math.Abs(s.ForceOut);
        bool isClipping = (s.OutPct >= clipThreshold) || s.Saturated;

        // Expire a finished hold BEFORE this sample is folded in, so the new
        // excursion starts from a clean peak rather than inheriting the old one.
        if (holding && DateTime.UtcNow >= holdUntil) {
            peakPct = 0; peakForce = 0; holding = false;
        }

        if (s.OutPct > peakPct)  peakPct = s.OutPct;
        if (absOut  > peakForce) peakForce = absOut;
        if (isClipping) clipSamples++;

        if (isClipping && !wasClipping) clipEvents++;   // rising edge only
        if (isClipping) {
            holding   = true;
            holdUntil = DateTime.UtcNow.AddMilliseconds(clipHoldMs);
        }
        wasClipping = isClipping;

        Render(s, null);
    }

    static string Row(string label, string value) {
        return label.PadRight(20) + value.PadLeft(12);
    }

    // Wheel rotation: what the car asks for, and what the base is actually set
    // to. They should converge a second or so after a car change.
    void AppendRotation(StringBuilder sb) {
        if (rotation == null) return;
        bool conn; int limit, gameMax, car; string st;
        rotation.Snapshot(out conn, out limit, out gameMax, out car, out st);

        sb.AppendLine(new string('-', 32));
        sb.AppendLine(Row("Car rotation", car > 0 ? car + " deg" : "-"));
        if (conn) {
            sb.AppendLine(Row("Base rotation", gameMax + " / " + limit));
            // Free-form and often longer than Row's 12 character value column,
            // so left-align it instead of padding it ragged.
            if (st != "ready") sb.AppendLine("Rotation: " + st);
        } else {
            sb.AppendLine("Base rotation: " + st);
        }
    }

    // Name from the console if we caught it, otherwise inferred from the ini
    // and marked with "?" so a guess is never mistaken for a fact.
    string CarLabel(RfSample s) {
        if (vehicle != null) return vehicle;
        if (s == null) return null;
        string guess;
        if (carsByForce.TryGetValue(s.MaxForce, out guess)) return guess + " ?";
        return null;
    }

    void Render(RfSample s, string note) {
        string car  = CarLabel(s);
        string head = car != null ? "RealFeel - " + car : "RealFeel";
        var sb = new StringBuilder();
        sb.AppendLine(head);
        sb.AppendLine(new string('-', 32));

        if (s == null) {
            sb.AppendLine();
            sb.AppendLine("  " + (note ?? "no data"));
            body.Text      = sb.ToString();
            peak.Text      = "MAX GAIN   --";
            peak.ForeColor = Color.DimGray;
            status.Text    = "double-click or R resets peak\nright-click for menu, Esc closes";
            return;
        }

        sb.AppendLine(Row("Max force at rack", s.MaxForce.ToString()));
        sb.AppendLine(Row("Smoothing level",   s.Smoothing.ToString()));
        sb.AppendLine(Row("Steering damper",   s.Damper.ToString()));
        sb.AppendLine(Row("RealFeel mix",      s.Mix + "%"));
        sb.AppendLine(Row("Input max",         s.InputMax.ToString()));
        sb.AppendLine(new string('-', 32));
        sb.AppendLine(Row("Force (computed)",  s.ForceRaw.ToString()));
        sb.AppendLine(Row("Force (output)",    s.ForceOut.ToString()));
        sb.AppendLine(Row("Output now",        s.OutPct + "%" + (s.Saturated ? " +++" : "")));
        sb.AppendLine(new string('-', 32));
        // Invariant so the readout matches the dots the game's console prints,
        // rather than switching to commas on a Spanish system.
        var ci = System.Globalization.CultureInfo.InvariantCulture;
        sb.AppendLine(Row("Front grip L / R",  s.GripL.ToString("0.00", ci) + " / " + s.GripR.ToString("0.00", ci)));
        sb.AppendLine(Row("Front grip effect", s.GripEffect.ToString("0.0", ci)));
        AppendRotation(sb);
        body.Text = sb.ToString();

        string held = "";
        if (holding) {
            double left = (holdUntil - DateTime.UtcNow).TotalSeconds;
            if (left < 0) left = 0;
            held = string.Format(System.Globalization.CultureInfo.InvariantCulture, "  HOLD {0:0.0}s", left);
        }
        peak.Text = string.Format("MAX GAIN  {0,3}%  ({1}){2}", peakPct, peakForce, held);
        if (peakPct >= clipThreshold) peak.ForeColor = Color.Tomato;
        else if (peakPct >= 85)       peak.ForeColor = Color.Gold;
        else                          peak.ForeColor = Color.LimeGreen;

        status.Text = string.Format(
            "clip events: {0}   samples: {1}\ndouble-click or R resets peak\nright-click for menu, Esc closes",
            clipEvents, clipSamples);
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        timer.Stop();
        reader.Detach();
        if (rotation != null) rotation.Stop();   // releases the SDK's manager
        base.OnFormClosed(e);
    }
}

public static class RfMain {
    static int ArgInt(string[] a, string name, int fallback) {
        for (int i = 0; i < a.Length - 1; i++)
            if (a[i] == name) { int v; if (int.TryParse(a[i+1], out v)) return v; }
        return fallback;
    }
    static string ArgStr(string[] a, string name, string fallback) {
        for (int i = 0; i < a.Length - 1; i++)
            if (a[i] == name) return a[i+1];
        return fallback;
    }

    [STAThread]
    public static void Main(string[] args) {
        RfReader.IgnoreCtrlEvents();

        int    clip   = ArgInt(args, "--clip", 100);
        int    poll   = ArgInt(args, "--poll", 100);
        int    tpid   = ArgInt(args, "--testpid", 0);
        int    margin = ArgInt(args, "--margin", 12);
        int    hold   = ArgInt(args, "--hold", 150);
        int    expand = ArgInt(args, "--expanded", 0);
        int    cliphold = ArgInt(args, "--cliphold", 4000);
        string corner = ArgStr(args, "--corner", "TopRight");
        string ini    = ArgStr(args, "--ini", "");

        string prof    = ArgStr(args, "--profile", "");
        string mozalib = ArgStr(args, "--mozalib", "");
        int    maxlim  = ArgInt(args, "--maxlimit", 2000);
        int    rotpoll = ArgInt(args, "--rotpoll", 1000);
        int    norot   = ArgInt(args, "--norotation", 0);
        int    rotdry  = ArgInt(args, "--rotdryrun", 0);
        string statef  = ArgStr(args, "--statefile", "");

        // Rotation is optional: without a profile or the SDK the overlay is
        // still a working FFB monitor, just without the two rotation rows.
        RfRotation rot = null;
        if (norot == 0 && prof.Length > 0 && mozalib.Length > 0) {
            rot = new RfRotation(prof, mozalib, maxlim, rotpoll, rotdry != 0, statef);
            rot.Start();
        }

        Application.EnableVisualStyles();
        var f = new RfOverlay(clip, poll, tpid, ini, hold, expand != 0, cliphold, rot);

        var area = Screen.PrimaryScreen.WorkingArea;
        int x, y;
        switch (corner) {
            case "TopLeft":     x = area.Left  + margin;            y = area.Top + margin; break;
            case "BottomRight": x = area.Right - f.Width - margin;  y = area.Bottom - f.Height - margin; break;
            case "BottomLeft":  x = area.Left  + margin;            y = area.Bottom - f.Height - margin; break;
            default:            x = area.Right - f.Width - margin;  y = area.Top + margin; break;
        }
        f.StartPosition = FormStartPosition.Manual;
        f.Location = new Point(x, y);

        Application.Run(f);
    }
}
'@

$iniPath = $IniPath
if (-not $MozaLib) { $MozaLib = Join-Path $PSScriptRoot 'lib\moza' }
$mozaLib = $MozaLib

# --- headless self-test (in-process; no exe needed) --------------------------

if ($SelfTest) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $Source

    $targetPid = $TestPid
    if (-not $targetPid) {
        $ams = Get-Process -Name AMS -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ams) { Write-Warning 'SelfTest: no -TestPid given and AMS is not running.'; exit 1 }
        $targetPid = $ams.Id
    }

    $log  = New-Object System.Collections.Generic.List[string]
    $cars = [RfParser]::CarsByForce($iniPath)
    $log.Add("ini: $iniPath -> $($cars.Count) distinct max-force values")

    $r = New-Object RfReader
    if (-not $r.Attach($targetPid)) {
        $r.Detach(); Write-Warning "SelfTest: could not attach to console of pid $targetPid"; exit 1
    }

    $veh = $null
    for ($i = 0; $i -lt 5; $i++) {
        $lines = $r.ReadTail($(if ($i -eq 0) { 4000 } else { 80 }))
        if ($null -eq $lines) { $log.Add('ReadTail returned null'); break }
        $v = [RfParser]::LatestVehicle($lines)
        if ($v) { $veh = $v }
        $s = [RfParser]::LatestSample($lines)
        if ($null -eq $s) {
            $log.Add("[$i] lines=$($lines.Count) vehicle=$veh NO TELEMETRY LINE MATCHED")
        } else {
            $inferred = if ($cars.ContainsKey($s.MaxForce)) { $cars[$s.MaxForce] } else { '(no match)' }
            $log.Add(("[{0}] vehicle={1} inferred={2} maxForce={3} smooth={4} damper={5} mix={6}% inputMax={7} raw={8} out={9} pct={10}% grip={11}/{12} eff={13} sat={14}" -f `
                $i, $veh, $inferred, $s.MaxForce, $s.Smoothing, $s.Damper, $s.Mix, $s.InputMax,
                $s.ForceRaw, $s.ForceOut, $s.OutPct, $s.GripL, $s.GripR, $s.GripEffect, $s.Saturated))
        }
        Start-Sleep -Milliseconds 300
    }
    $r.Detach()
    $log | ForEach-Object { $_ }
    exit 0
}

# --- build the exe if needed, then launch it ---------------------------------

$exePath    = Join-Path $PSScriptRoot 'realfeel-overlay.exe'
$scriptPath = $PSCommandPath

$needsBuild = $Rebuild -or
              (-not (Test-Path $exePath)) -or
              ((Get-Item $scriptPath).LastWriteTimeUtc -gt (Get-Item $exePath).LastWriteTimeUtc)

if ($needsBuild) {
    Write-Host 'Building realfeel-overlay.exe ...'
    if (Test-Path $exePath) { Remove-Item $exePath -Force }
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing `
             -TypeDefinition $Source `
             -OutputAssembly $exePath -OutputType WindowsApplication
    if (-not (Test-Path $exePath)) { Write-Warning 'Build failed.'; exit 1 }
    Write-Host "Built $exePath"
}

$argList = @(
    '--corner', $Corner,
    '--margin', $Margin,
    '--clip',   $ClipThreshold,
    '--poll',   $PollMs,
    '--hold',   $HoldMs,
    '--expanded', $(if ($StartExpanded) { 1 } else { 0 }),
    '--cliphold', ($ClipHoldSeconds * 1000),
    '--ini',    $iniPath,
    '--profile', $ProfileIni,
    '--mozalib', $mozaLib,
    '--maxlimit', $MaxLimit,
    '--rotpoll', $RotationPollMs,
    '--norotation', $(if ($NoRotation) { 1 } else { 0 }),
    '--rotdryrun', $(if ($RotationDryRun) { 1 } else { 0 }),
    '--statefile', (Join-Path $PSScriptRoot 'rotation-watcher-state.json')
)
if ($TestPid) { $argList += @('--testpid', $TestPid) }

$p = Start-Process -FilePath $exePath -ArgumentList $argList -PassThru
Write-Host "Overlay started (pid $($p.Id)). Esc or right-click > Close to stop it."

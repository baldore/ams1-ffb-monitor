<#
.SYNOPSIS
  Pins the RealFeel console window on top of Automobilista so the FFB
  telemetry line stays readable while driving.

.DESCRIPTION
  RealFeel calls AllocConsole when ConsoleEnabled=True in RealFeelPlugin.ini.
  On a single monitor the resulting window sits behind the borderless game
  window and can never be seen. This finds it and makes it topmost, without
  stealing focus from the game.

  Two console hosts are possible, and they behave very differently:

    classic conhost  - window class ConsoleWindowClass, owned by a conhost.exe
                       child of AMS.exe. This is the Windows default and what
                       this machine currently uses.
    Windows Terminal - window class CASCADIA_HOSTING_WINDOW_CLASS, owned by
                       WindowsTerminal.exe, which is NOT a child of AMS (the
                       handoff goes through OpenConsole.exe). Ownership tells
                       us nothing, so it is matched on class alone. The console
                       may also be one TAB among several, in which case pinning
                       affects the whole Terminal window.

  Which one you get is set by Settings > System > For developers > Terminal,
  stored in HKCU:\Console\%%Startup (DelegationConsole / DelegationTerminal).

  Requires the game in BORDERLESS WINDOWED mode (Config.ini: WindowedMode=1,
  WindowBorders=0). In exclusive fullscreen (WindowedMode=0) the GPU owns the
  display and no topmost window can draw over it.

.EXAMPLE
  .\pin-realfeel-console.ps1
  Waits for the console, pins it to the top-right corner.

.EXAMPLE
  .\pin-realfeel-console.ps1 -Corner BottomLeft -Width 700 -Height 260

.EXAMPLE
  .\pin-realfeel-console.ps1 -Unpin
  Releases topmost so the window behaves normally again.
#>
[CmdletBinding()]
param(
    [ValidateSet('TopRight','TopLeft','BottomRight','BottomLeft')]
    [string]$Corner = 'TopRight',

    [int]$Width  = 620,
    [int]$Height = 200,
    [int]$Margin = 12,

    # How long to wait for AMS and its console to show up.
    [int]$TimeoutSeconds = 90,

    [switch]$Unpin
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class RfConsole {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    public static readonly IntPtr HWND_TOPMOST   = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOACTIVATE = 0x0010;   // keep input focus on the game
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOSIZE     = 0x0001;
    public const uint SWP_NOMOVE     = 0x0002;
    public const int  SW_SHOWNOACTIVATE = 4;

    // Set on a successful match so the caller can report which host served it.
    public static string LastClass = "";
    public static int    LastPid   = 0;

    static IntPtr Scan(int[] pids, string[] classes, bool anyPid) {
        IntPtr hit = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (!anyPid) {
                bool owned = false;
                foreach (int p in pids) if ((uint)p == wpid) { owned = true; break; }
                if (!owned) return true;
            }
            var cls = new StringBuilder(256);
            GetClassNameW(h, cls, 256);
            string c = cls.ToString();
            foreach (string want in classes) {
                if (c == want) { hit = h; LastClass = c; LastPid = (int)wpid; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return hit;
    }

    // Classic conhost: window owned by AMS or by a conhost child of it.
    public static IntPtr FindByPid(int[] pids, string[] classes) { return Scan(pids, classes, false); }

    // Windows Terminal: owned by an unrelated process, so match on class alone.
    public static IntPtr FindByClass(string[] classes) { return Scan(new int[0], classes, true); }
}
'@

$ClassicClass  = 'ConsoleWindowClass'
$TerminalClass = 'CASCADIA_HOSTING_WINDOW_CLASS'

function Get-AmsConsoleHandle {
    $ams = Get-Process -Name AMS -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ams) { return @{ Stage = 'no-ams'; Hwnd = [IntPtr]::Zero } }

    # 1. Classic conhost, by ownership: AMS itself or a conhost.exe child.
    $pids = @($ams.Id)
    $pids += (Get-CimInstance Win32_Process -Filter "Name='conhost.exe'" |
              Where-Object { $_.ParentProcessId -eq $ams.Id } |
              Select-Object -ExpandProperty ProcessId)

    $h = [RfConsole]::FindByPid([int[]]$pids, @($ClassicClass, $TerminalClass))
    if ($h -ne [IntPtr]::Zero) {
        return @{ Stage = 'ok'; Hwnd = $h; Ams = $ams.Id; Host = 'conhost (by ownership)';
                  Class = [RfConsole]::LastClass; OwnerPid = [RfConsole]::LastPid; Ambiguous = $false }
    }

    # 2. Windows Terminal, by class only. Ownership cannot help here.
    $h = [RfConsole]::FindByClass(@($TerminalClass))
    if ($h -ne [IntPtr]::Zero) {
        $wt = @(Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue)
        return @{ Stage = 'ok'; Hwnd = $h; Ams = $ams.Id; Host = 'Windows Terminal (by class)';
                  Class = [RfConsole]::LastClass; OwnerPid = [RfConsole]::LastPid;
                  Ambiguous = ($wt.Count -gt 1) }
    }

    return @{ Stage = 'no-console'; Hwnd = [IntPtr]::Zero; Ams = $ams.Id }
}

# --- wait for the window -----------------------------------------------------

$deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
$lastStage = ''
do {
    $r = Get-AmsConsoleHandle
    if ($r.Stage -eq 'ok') { break }
    if ($r.Stage -ne $lastStage) {
        switch ($r.Stage) {
            'no-ams'     { Write-Host 'Waiting for AMS.exe to start...' }
            'no-console' { Write-Host 'AMS is up; waiting for the RealFeel console...' }
        }
        $lastStage = $r.Stage
    }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)

if ($r.Stage -ne 'ok') {
    if ($r.Stage -eq 'no-ams') {
        Write-Warning 'Timed out: AMS.exe never started.'
    } else {
        Write-Warning "Timed out: AMS is running (PID $($r.Ams)) but no console window appeared."
        Write-Host 'Check that RealFeelPlugin.ini has ConsoleEnabled=True, and that the'
        Write-Host 'game was restarted after that change.'
    }
    exit 1
}

$hwnd = $r.Hwnd
Write-Host ("Found console: hwnd=0x{0:X} class={1} owner-pid={2} via {3} (AMS pid {4})" -f $hwnd.ToInt64(), $r.Class, $r.OwnerPid, $r.Host, $r.Ams)

if ($r.Class -eq $TerminalClass) {
    Write-Warning 'This is a Windows Terminal window. If the RealFeel console is one tab'
    Write-Warning 'among several, pinning affects the entire window, not just that tab.'
    if ($r.Ambiguous) {
        Write-Warning 'More than one WindowsTerminal.exe is running - the wrong window may have'
        Write-Warning 'been picked. Set Windows to use the classic console host to avoid this:'
        Write-Warning 'Settings > System > For developers > Terminal > Windows Console Host.'
    }
}

# --- unpin -------------------------------------------------------------------

if ($Unpin) {
    [void][RfConsole]::SetWindowPos($hwnd, [RfConsole]::HWND_NOTOPMOST, 0, 0, 0, 0,
        ([RfConsole]::SWP_NOSIZE -bor [RfConsole]::SWP_NOMOVE -bor [RfConsole]::SWP_NOACTIVATE))
    Write-Host 'Unpinned - the console is a normal window again.'
    exit 0
}

# --- position and pin --------------------------------------------------------

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

switch ($Corner) {
    'TopRight'    { $x = $area.Right - $Width - $Margin; $y = $area.Top + $Margin }
    'TopLeft'     { $x = $area.Left  + $Margin;          $y = $area.Top + $Margin }
    'BottomRight' { $x = $area.Right - $Width - $Margin; $y = $area.Bottom - $Height - $Margin }
    'BottomLeft'  { $x = $area.Left  + $Margin;          $y = $area.Bottom - $Height - $Margin }
}

if ([RfConsole]::IsIconic($hwnd)) {
    # Restore without activating, so the game keeps keyboard focus.
    [void][RfConsole]::ShowWindow($hwnd, [RfConsole]::SW_SHOWNOACTIVATE)
}

$ok = [RfConsole]::SetWindowPos(
    $hwnd, [RfConsole]::HWND_TOPMOST, $x, $y, $Width, $Height,
    ([RfConsole]::SWP_NOACTIVATE -bor [RfConsole]::SWP_SHOWWINDOW))

if (-not $ok) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Warning ("SetWindowPos failed: {0}" -f (New-Object ComponentModel.Win32Exception $code).Message)
    exit 1
}

Write-Host ("Pinned topmost at {0} ({1},{2}) {3}x{4}." -f $Corner, $x, $y, $Width, $Height)
Write-Host 'Focus stayed with the game. Re-run with -Unpin to release it.'

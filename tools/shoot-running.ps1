$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Shot2 {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
    public static IntPtr FindByPid(int pid) {
        IntPtr hit = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint w; GetWindowThreadProcessId(h, out w);
            if ((uint)pid == w && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                if (r.R - r.L > 50 && r.B - r.T > 50) { hit = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return hit;
    }
}
'@

$ov = Get-Process -Name realfeel-overlay -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ov) { 'FAIL: overlay not running'; exit 1 }

$h = [Shot2]::FindByPid($ov.Id)
if ($h -eq [IntPtr]::Zero) { 'FAIL: no visible window'; exit 1 }

$r = New-Object Shot2+RECT
[void][Shot2]::GetWindowRect($h, [ref]$r)
$w = $r.R - $r.L; $ht = $r.B - $r.T
"window $($r.L),$($r.T) ${w}x${ht}"

$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht))
$out = Join-Path $PSScriptRoot 'overlay-capture.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"saved $out"

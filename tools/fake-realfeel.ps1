# Fake RealFeel console producer: prints the same line format the plugin does,
# so the overlay's reader/parser can be tested without the game.
$host.UI.RawUI.WindowTitle = 'FAKE REALFEEL'

# The reader parses whole console rows, so keep the buffer wide enough that the
# ~57 character telemetry line never wraps.
try {
    $win = $host.UI.RawUI.WindowSize
    $w = [Math]::Max(120, $win.Width)
    $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($w, 3000)
} catch { Write-Host "buffer resize failed: $($_.Exception.Message)" }

Write-Host 'Vehicle acquired [SupV8]'

# The game writes this line from C under the C locale, so its decimals are
# dots. PowerShell would use the system locale (commas on a Spanish machine)
# and the parser would reject every line, so format invariantly.
$ci = [System.Globalization.CultureInfo]::InvariantCulture
$fmt = '{0} {1} {2} {3:000}% {4} {5} {6} {7:000}% {8:0.0} {9:0.00} {10:0.00}{11}'

$i = 0
while ($true) {
    # Sweep the output percentage up and down, crossing 100 so the clip path
    # and the "+++" marker both get exercised.
    $pct = [int](55 + 50 * [Math]::Sin($i / 9.0))
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }

    $maxForce = -4000
    $out      = [int](-1 * $maxForce * $pct / 100) * -1
    $raw      = $out - 80
    $gripL    = 0.95 - 0.10 * [Math]::Abs([Math]::Sin($i / 11.0))
    $gripR    = 0.92 - 0.12 * [Math]::Abs([Math]::Sin($i / 13.0))
    $sat      = if ($pct -ge 100) { ' +++' } else { '' }

    $line = [string]::Format($ci, $fmt,
        $maxForce.ToString('00000;-0000'),
        2,
        11500,
        100,
        11500,
        $raw.ToString('00000;-0000'),
        $out.ToString('00000;-0000'),
        $pct,
        0.0,
        $gripL,
        $gripR,
        $sat)

    Write-Host $line
    Start-Sleep -Milliseconds 100
    $i++
}

<#
.SYNOPSIS
  Sets the MOZA wheelbase rotation to match the car in Automobilista 1.

.DESCRIPTION
  AMS writes the current car's rotation into the PROFILE Controller.ini as
  "Steering Wheel Range", in full lock-to-lock degrees, and rewrites it within
  seconds of a car change while the game is running (observed 540 -> 450).
  That is the game's own computed value for the car, so no .hdv parsing or
  steering-ratio maths is needed.

  The same file is rewritten every few seconds with identical content, so this
  triggers on the VALUE changing, never on the modification time.

  MOZA's setMotorLimitAngle(limitAngle, gameMaximumAngle) takes two numbers and
  requires gameMaximumAngle <= limitAngle. The per-car value goes into
  gameMaximumAngle. limitAngle is raised once to -MaxLimit so it stops being a
  ceiling (a base left at 450 would silently clamp a 540 car); the original is
  saved to rotation-watcher-state.json and -Restore puts it back.

  MOZA's own example calls setMotorLimitAngle(150,200), which violates their
  documented constraint, so every write is read back and verified.

  Needs lib\moza\{MOZA_API_CSharp,MOZA_API_C,MOZA_SDK}.dll - see README.

.EXAMPLE
  .\rotation-watcher.ps1 -Probe      # read the base and exit, no writes
.EXAMPLE
  .\rotation-watcher.ps1 -DryRun     # watch and log, never write
.EXAMPLE
  .\rotation-watcher.ps1             # the real thing
.EXAMPLE
  .\rotation-watcher.ps1 -Restore    # put the base back as it was
#>
[CmdletBinding()]
param(
    [string]$ProfileIni = 'C:\Users\acorn\OneDrive\Documents\Automobilista\userdata\Orregoso\Controller.ini',
    [string]$LibPath,
    [int]$PollMs = 1000,

    # limitAngle is raised to this once so per-car values are never clamped.
    # The SDK documents 90-2000 for the setter.
    [int]$MaxLimit = 2000,

    [switch]$Probe,
    [switch]$DryRun,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
if (-not $LibPath) { $LibPath = Join-Path $PSScriptRoot 'lib\moza' }
$StateFile = Join-Path $PSScriptRoot 'rotation-watcher-state.json'
$LogFile   = Join-Path $PSScriptRoot 'rotation-watcher.log'

function Write-Log {
    param([string]$Msg, [string]$Level = 'info')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding utf8 } catch { }
}

# --- load the SDK -------------------------------------------------------------

if (-not (Test-Path (Join-Path $LibPath 'MOZA_API_CSharp.dll'))) {
    Write-Log "SDK not found in $LibPath - see README for the three DLLs" 'error'
    exit 1
}

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class MozaNative {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool SetDllDirectoryW(string p);
}
'@
[void][MozaNative]::SetDllDirectoryW($LibPath)
$env:PATH = "$LibPath;$env:PATH"
Add-Type -Path (Join-Path $LibPath 'MOZA_API_CSharp.dll')

# The base comes up through three states after installMozaSDK, measured on the
# R5:
#   err=NODEVICES limit=0            not enumerated yet
#   err=NORMAL    limit=0            reports success, values still zero
#   err=NORMAL    limit=450          actually ready
# The middle one is the trap: taking it at face value yields a "limit" of 0,
# which would then be saved as the original and later restored onto the base.
# The SDK's own documented minimum is 90, so anything below that is not a real
# reading regardless of the error code.
function Test-BaseReading {
    param($Reading)
    return ($null -ne $Reading) -and ($Reading.Limit -ge 90) -and ($Reading.GameMax -ge 90)
}

function Read-Base {
    param([int]$Attempts = 5)
    for ($i = 0; $i -lt $Attempts; $i++) {
        # Sentinel, not NORMAL: if the call never writes the ref, a pre-set
        # NORMAL would look like success.
        $err = [mozaAPI.ERRORCODE]::PARAMETERERR
        $pair = [mozaAPI.mozaAPI]::getMotorLimitAngle([ref]$err)
        if ($err -eq [mozaAPI.ERRORCODE]::NORMAL -and $pair) {
            $r = @{ Limit = $pair.Item1; GameMax = $pair.Item2 }
            if (Test-BaseReading $r) { return $r }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Connect-Base {
    param([int]$TimeoutSec = 30)
    [mozaAPI.mozaAPI]::installMozaSDK()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Milliseconds 500
        $r = Read-Base -Attempts 1
        if (Test-BaseReading $r) { return $r }
    } while ((Get-Date) -lt $deadline)
    Write-Log "base never reported a valid rotation within $TimeoutSec s" 'error'
    return $null
}

# Write, then read back - the SDK docs contradict their own example, so the
# only trustworthy confirmation is what the base reports afterwards.
function Set-Base {
    param([int]$Limit, [int]$GameMax)
    $err = [mozaAPI.mozaAPI]::setMotorLimitAngle($Limit, $GameMax)
    if ($err -ne [mozaAPI.ERRORCODE]::NORMAL) {
        Write-Log "setMotorLimitAngle($Limit,$GameMax) returned $err" 'error'
        return $false
    }
    Start-Sleep -Milliseconds 300
    $now = Read-Base
    if (-not $now) { Write-Log 'read-back failed after write' 'error'; return $false }
    if ($now.Limit -ne $Limit -or $now.GameMax -ne $GameMax) {
        Write-Log ("read-back mismatch: asked {0}/{1}, base reports {2}/{3}" -f $Limit, $GameMax, $now.Limit, $now.GameMax) 'error'
        return $false
    }
    return $true
}

function Get-CarRange {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $line = Select-String -Path $Path -Pattern '^Steering Wheel Range="(\d+)"' -List
        if ($line) { return [int]$line.Matches[0].Groups[1].Value }
    } catch { }
    return 0
}

# --- probe --------------------------------------------------------------------

if ($Probe) {
    $b = Connect-Base
    if ($b) { Write-Log ("base: limitAngle={0} gameMaximumAngle={1}" -f $b.Limit, $b.GameMax) }
    Write-Log ("car in {0}: Steering Wheel Range={1}" -f (Split-Path $ProfileIni -Leaf), (Get-CarRange $ProfileIni))
    [mozaAPI.mozaAPI]::removeMozaSDK()
    exit 0
}

# --- restore ------------------------------------------------------------------

if ($Restore) {
    if (-not (Test-Path $StateFile)) { Write-Log 'no state file - nothing to restore' 'warn'; exit 1 }
    $st = Get-Content $StateFile -Raw | ConvertFrom-Json
    $b = Connect-Base
    if (-not $b) { exit 1 }
    Write-Log ("restoring limitAngle={0} gameMaximumAngle={1} (base now {2}/{3})" -f $st.OrigLimit, $st.OrigGameMax, $b.Limit, $b.GameMax)
    if (Set-Base -Limit ([int]$st.OrigLimit) -GameMax ([int]$st.OrigGameMax)) {
        Write-Log 'restored'
        Remove-Item $StateFile -Force
    }
    [mozaAPI.mozaAPI]::removeMozaSDK()
    exit 0
}

# --- watch --------------------------------------------------------------------

$mode = ''
if ($DryRun) { $mode = ' (dry run)' }
Write-Log ("starting{0} - profile: {1}" -f $mode, $ProfileIni)

$base = Connect-Base
if (-not $base) { exit 1 }
Write-Log ("base on connect: limitAngle={0} gameMaximumAngle={1}" -f $base.Limit, $base.GameMax)

# Remember the original exactly once, so -Restore stays truthful across restarts.
if (-not (Test-Path $StateFile)) {
    @{ OrigLimit = $base.Limit; OrigGameMax = $base.GameMax; Saved = (Get-Date -Format 's') } |
        ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "saved original base settings to $(Split-Path $StateFile -Leaf)"
}

$limit = $base.Limit
if ($limit -lt $MaxLimit) {
    if ($DryRun) {
        Write-Log "would raise limitAngle $limit -> $MaxLimit (dry run)"
        $limit = $MaxLimit
    } elseif (Set-Base -Limit $MaxLimit -GameMax $base.GameMax) {
        Write-Log "raised limitAngle $limit -> $MaxLimit so per-car values are never clamped"
        $limit = $MaxLimit
    } else {
        Write-Log "could not raise limitAngle, staying at $limit - larger cars will clamp" 'warn'
    }
}

$applied = -1
$amsSeen = $false

# finally, so Ctrl+C or a kill still releases the SDK's global manager. Leaving
# it held makes the next run sit in the NODEVICES state far longer.
try {
    while ($true) {
        $ams = @(Get-Process -Name AMS -ErrorAction SilentlyContinue)
        if ($ams.Count -eq 0) {
            if ($amsSeen) { Write-Log 'AMS closed - idling'; $amsSeen = $false; $applied = -1 }
            Start-Sleep -Milliseconds $PollMs
            continue
        }
        if (-not $amsSeen) { Write-Log 'AMS running - watching for car changes'; $amsSeen = $true }

        $range = Get-CarRange $ProfileIni
        if ($range -gt 0 -and $range -ne $applied) {
            $target = [Math]::Min($range, $limit)
            if ($target -lt 90) { $target = 90 }
            if ($target -ne $range) { Write-Log "car wants $range but limitAngle is $limit - clamping to $target" 'warn' }

            if ($DryRun) {
                Write-Log "would set gameMaximumAngle -> $target (car range $range)"
                $applied = $range
            } elseif (Set-Base -Limit $limit -GameMax $target) {
                Write-Log "car range $range -> base gameMaximumAngle $target  (verified)"
                $applied = $range
            } else {
                Write-Log "failed to apply $target - will retry" 'warn'
            }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}
finally {
    Write-Log 'releasing SDK'
    try { [mozaAPI.mozaAPI]::removeMozaSDK() } catch { }
}

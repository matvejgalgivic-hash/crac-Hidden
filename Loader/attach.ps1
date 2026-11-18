#requires -version 5
<#
  attach.ps1 - game launch + overlay-attach verification for the ROB RUN loader chain.

  Called by start.bat after the crack runtime (RobRun.exe) is already up.
  Order is: crack -> driver -> game. This script starts the game second and
  then confirms the overlay window really attached.

  Params:
    -TimeoutSec  how long to wait for game + attach (default 240)
    -NoLaunch    do not start the game, only verify (used by status.bat)
    -GameExe     explicit path to "ROB RUN.exe" (skips Steam discovery)
#>
[CmdletBinding()]
param(
    [int]$TimeoutSec = 240,
    [int]$GraceSec   = 25,
    [switch]$NoLaunch,
    [string]$GameExe
)

$ErrorActionPreference = 'Stop'
$SteamAppId = 4262460
$GameProc   = 'ROB RUN'
$CrackProc  = 'RobRun'

function Info($m) { Write-Host ("[*] " + $m) -ForegroundColor Cyan }
function Ok($m)   { Write-Host ("[+] " + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ("[!] " + $m) -ForegroundColor Yellow }
function Bad($m)  { Write-Host ("[x] " + $m) -ForegroundColor Red }

# ---------------------------------------------------------------- windows api
if (-not ([System.Management.Automation.PSTypeName]'W32').Type) {
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class W32 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public static System.Collections.Generic.List<string> ForPid(uint want) {
        var res = new System.Collections.Generic.List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == want) {
                var c = new StringBuilder(256); GetClassName(h, c, c.Capacity);
                var t = new StringBuilder(256); GetWindowText(h, t, t.Capacity);
                res.Add(c.ToString() + "|" + t.ToString() + "|" + (IsWindowVisible(h) ? "vis" : "hid"));
            }
            return true;
        }, IntPtr.Zero);
        return res;
    }
}
"@
}

function Get-WindowsForPid([int]$ProcessId) {
    try { return [W32]::ForPid([uint32]$ProcessId) } catch { return @() }
}

# ------------------------------------------------------------ steam discovery
function Get-SteamRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    try {
        $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($p) { $roots.Add(($p -replace '/', '\')) }
    } catch {}
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = (Get-ItemProperty $k -ErrorAction Stop).InstallPath
            if ($p) { $roots.Add($p) }
        } catch {}
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        if (Test-Path $r) { $out.Add($r) }
        $lf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path $lf) {
            $txt = Get-Content $lf -Raw
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                if (Test-Path $lib) { $out.Add($lib) }
            }
        }
    }
    $out | Select-Object -Unique
}

function Resolve-GameExe {
    if ($GameExe -and (Test-Path $GameExe)) { return (Resolve-Path $GameExe).Path }
    foreach ($root in Get-SteamRoots) {
        $acf = Join-Path $root ("steamapps\appmanifest_{0}.acf" -f $SteamAppId)
        if (Test-Path $acf) {
            $dir = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
            if ($dir) {
                $exe = Join-Path $root ("steamapps\common\{0}\ROB RUN.exe" -f $dir)
                if (Test-Path $exe) { return $exe }
            }
        }
    }
    foreach ($root in Get-SteamRoots) {
        $common = Join-Path $root 'steamapps\common'
        if (Test-Path $common) {
            $hit = Get-ChildItem -Path $common -Recurse -Filter 'ROB RUN.exe' -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Get-GamePathPreferSteam {
    foreach ($root in Get-SteamRoots) {
        $exe = Join-Path $root ("steamapps\common\Rob Run\ROB RUN.exe")
        if (Test-Path $exe) { return $exe }
    }
    return (Resolve-GameExe)
}

# ------------------------------------------------------------------- launching
function Ensure-Steam {
    if (-not (Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) {
        $steam = $null
        try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe } catch {}
        if ($steam -and (Test-Path $steam)) { Info "starting Steam client"; Start-Process -FilePath $steam | Out-Null }
    }
}

function Start-Game {
    Ensure-Steam
    $exe = Get-GamePathPreferSteam
    if ($exe) {
        $wd = Split-Path $exe -Parent
        Info ("launching game: " + $exe)
        Start-Process -FilePath $exe -WorkingDirectory $wd | Out-Null
        return $true
    }
    Warn "ROB RUN.exe not found on disk; falling back to steam://rungameid/$SteamAppId"
    Start-Process ("steam://rungameid/{0}" -f $SteamAppId) | Out-Null
    return $true
}

# ---------------------------------------------------------------- attach probe
function Test-Attached {
    param([int[]]$CrackPids, [int[]]$GamePids)

    $hits = New-Object System.Collections.Generic.List[string]
    # NOTE: never name a loop variable $pid - $PID is a read-only automatic
    # variable (Constant, AllScope) and assigning it throws, which aborts the
    # whole script before the overlay is ever checked.
    foreach ($procId in @($CrackPids + $GamePids)) {
        if (-not $procId) { continue }
        foreach ($w in Get-WindowsForPid $procId) {
            if ($w -match '(?i)hidden|robrun|overlay') { $hits.Add($w) }
        }
    }
    return $hits
}

# ------------------------------------------------------------------- main flow
$deadline = (Get-Date).AddSeconds($TimeoutSec)

$crack = @(Get-Process -Name $CrackProc -ErrorAction SilentlyContinue)
if (-not $crack) { Bad "RobRun.exe runtime is not running - arm the crack first (start.bat)."; exit 1 }
Info ("runtime pid(s): " + (($crack | ForEach-Object { $_.Id }) -join ', '))

$game = @(Get-Process -Name $GameProc -ErrorAction SilentlyContinue)
if (-not $game -and -not $NoLaunch) {
    # RobRun.exe never starts the game itself, so this grace window only
    # catches the case where the user started it by hand right after the
    # runtime came up. If nothing shows up we start it ourselves below.
    Info ("waiting {0}s for an already-running game ..." -f $GraceSec)
    $grace = (Get-Date).AddSeconds($GraceSec)
    while ((Get-Date) -lt $grace) {
        Start-Sleep -Milliseconds 700
        $game = @(Get-Process -Name $GameProc -ErrorAction SilentlyContinue)
        if ($game) { break }
        if (-not (Get-Process -Name $CrackProc -ErrorAction SilentlyContinue)) {
            Bad "runtime died while waiting for the game - check loader_crack.log"; exit 1
        }
    }
}
if (-not $game) {
    if ($NoLaunch) { Bad "ROB RUN.exe is not running (-NoLaunch)."; exit 2 }
    Info "starting the game"
    Start-Game | Out-Null
    Info "waiting for ROB RUN.exe ..."
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $game = @(Get-Process -Name $GameProc -ErrorAction SilentlyContinue)
        if ($game) { break }
        if (-not (Get-Process -Name $CrackProc -ErrorAction SilentlyContinue)) {
            Bad "runtime died while waiting for the game - check loader_crack.log"; exit 1
        }
    }
}
if (-not $game) { Bad ("ROB RUN.exe did not start within {0}s." -f $TimeoutSec); exit 2 }
Ok ("game pid(s): " + (($game | ForEach-Object { $_.Id }) -join ', '))

Info "waiting for the overlay to attach ..."
$attached = $null
while ((Get-Date) -lt $deadline) {
    $crack = @(Get-Process -Name $CrackProc -ErrorAction SilentlyContinue)
    $game  = @(Get-Process -Name $GameProc -ErrorAction SilentlyContinue)
    if (-not $crack) { Bad "runtime exited - overlay lost. check loader_crack.log"; exit 1 }
    $hits = Test-Attached -CrackPids ($crack.Id) -GamePids ($game.Id)
    if ($hits.Count -gt 0) { $attached = $hits; break }
    Start-Sleep -Milliseconds 800
}

if ($attached) {
    Ok "overlay attached. windows:"
    foreach ($h in $attached) { Write-Host ("      " + $h) }
} else {
    Warn "overlay window not seen yet. runtime and game are both up;"
    Warn "if the menu (Insert) does not appear, re-read loader_crack.log."
}

# raw dump for the operator - every top-level window of both processes
Write-Host ""
Info "window dump (class|title|state):"
foreach ($p in @(Get-Process -Name $CrackProc, $GameProc -ErrorAction SilentlyContinue)) {
    Write-Host ("  {0} (pid {1})" -f $p.ProcessName, $p.Id)
    $ws = Get-WindowsForPid $p.Id
    if (-not $ws -or $ws.Count -eq 0) { Write-Host "      <no top-level windows>" }
    else { foreach ($w in $ws) { Write-Host ("      " + $w) } }
}

Write-Host ""
Ok "chain armed. Insert = menu, End = unload."
if ($attached) { exit 0 } else { exit 0 }

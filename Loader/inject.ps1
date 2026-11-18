#requires -version 5
<#
  inject.ps1 - direct injector for the ROB RUN runtime (RobRun.exe).

  Drop the loader UI out of the loop. This script does the whole launch
  handshake itself, exactly the way GameLoader.RobRunRuntime does it:

    1. get a fresh signed launch ticket
         - vendor:  POST https://<vendor>/api/v1/auth  ->  token
                    POST https://<vendor>/api/v1/games/1/launch  ->  ticket
         - or local api:  POST http://127.0.0.1:8765/api/v1/games/1/launch
    2. create the named pipe  RobRun.<guid>
    3. spawn RobRun.exe  --loader-pipe <name>   (elevated, output captured)
    4. wait for the client, verify its pid == the child pid
    5. write the bootstrap frame
         4-byte little-endian length + utf8 payload:
         "ROBRUN-SIG/1\n<server>\n<gameId>\n<ticket>\n<hwid>\n<issued>\n<expires>\n<signature>\n"
    6. read status frames: initializing / ready / waiting_game / error:...
    7. on "ready" launch the game, keep reading states, then verify the
       overlay attached (window probe, same as attach.ps1)

  Must run elevated: RobRun maps iqvw64e.sys via kdmapper and aborts
  with 0xC0000409 without an admin token.

  Params:
    -Runtime <exe>      RobRun.exe to run (default: extract packages\1.zip)
    -GameExe <exe>      ROB RUN.exe (default: Steam manifest discovery)
    -Vendor <url>       vendor base url (default https://95.85.230.17)
    -Key / -Hwid        license overrides (default: license.json)
    -LocalApi           take the ticket from 127.0.0.1:8765 instead of vendor
    -NoGame             handshake only, do not start the game
    -TimeoutSec <n>     handshake timeout (default 90)
#>
[CmdletBinding()]
param(
    [string]$Runtime,
    [string]$GameExe,
    [string]$Vendor = 'https://95.85.230.17',
    [string]$Key,
    [string]$Hwid,
    [switch]$LocalApi,
    [switch]$NoGame,
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Stop'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgZip     = Join-Path $root 'packages\1.zip'
$licenseJs  = Join-Path $root 'license.json'
$logDir     = Join-Path $root 'logs'
$procOut    = Join-Path $logDir 'rbrun.out.log'
$procErr    = Join-Path $logDir 'rbrun.err.log'
$sessionJs  = Join-Path $logDir 'inject_session.json'
$steamAppId = 4262460

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Info($m) { Write-Host ("[*] " + $m) -ForegroundColor Cyan }
function Ok($m)   { Write-Host ("[+] " + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ("[!] " + $m) -ForegroundColor Yellow }
function Bad($m)  { Write-Host ("[x] " + $m) -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------ win32 bits
if (-not ([System.Management.Automation.PSTypeName]'Inj32').Type) {
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Inj32 {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr hPipe, out uint pid);

    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);

    public static System.Collections.Generic.List<string> WindowsOf(uint want) {
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

# ------------------------------------------------------------- ticket / vendor
function Get-License {
    $k = $Key; $h = $Hwid
    if ((-not $k -or -not $h) -and (Test-Path $licenseJs)) {
        try { $j = Get-Content $licenseJs -Raw | ConvertFrom-Json } catch { $j = $null }
        if ($j) { if (-not $k) { $k = $j.key }; if (-not $h) { $h = $j.hwid } }
    }
    return @{ key = $k; hwid = $h }
}

function Invoke-Json($Uri, $Method, $Body, $Headers) {
    $p = @{ Uri = $Uri; Method = $Method; TimeoutSec = 20; UseBasicParsing = $true }
    if ($Headers) { $p.Headers = $Headers }
    if ($Body -ne $null) {
        $p.Body = ($Body | ConvertTo-Json -Compress)
        $p.ContentType = 'application/json'
    }
    $r = Invoke-WebRequest @p
    return ($r.Content | ConvertFrom-Json)
}

function Get-TicketVendor {
    $lic = Get-License
    if (-not $lic.key -or -not $lic.hwid) { throw "no license.json key/hwid and none passed" }
    Info ("auth -> " + $Vendor)
    $auth = Invoke-Json ($Vendor + '/api/v1/auth') 'POST' @{ key = $lic.key; hwid = $lic.hwid } @{ 'User-Agent' = 'GameLoader/1.0.14' }
    if (-not $auth.token) { throw "auth: no token (key rejected?)" }
    Info ("launch ticket -> " + $Vendor)
    $tick = Invoke-Json ($Vendor + '/api/v1/games/1/launch') 'POST' @{} @{ 'User-Agent' = 'GameLoader/1.0.14'; 'Authorization' = ('Bearer ' + $auth.token) }
    if (-not $tick.ticket) { throw "launch: no ticket" }
    return $tick
}

function Get-TicketLocal {
    Info "launch ticket -> http://127.0.0.1:8765 (local api)"
    $tick = Invoke-Json 'http://127.0.0.1:8765/api/v1/games/1/launch' 'POST' @{} $null
    if (-not $tick.ticket) { throw "local api: no ticket (is api.py running?)" }
    return $tick
}

# ------------------------------------------------------------------- runtime exe
function Resolve-Runtime {
    if ($Runtime) {
        if (-not (Test-Path $Runtime)) { throw "runtime not found: $Runtime" }
        return (Resolve-Path $Runtime).Path
    }
    # prefer an already-extracted copy to avoid a 16 MB copy every run
    $cache = Join-Path $env:TEMP 'RobRun_inject'
    $exe   = Join-Path $cache 'RobRun.exe'
    if (Test-Path $exe) { return $exe }
    if (-not (Test-Path $pkgZip)) { throw "packages\1.zip not found and no -Runtime given" }
    Info "extracting package -> $cache"
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    try { Remove-Item (Join-Path $cache '*') -Force -ErrorAction SilentlyContinue } catch {}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($pkgZip, $cache)
    if (-not (Test-Path $exe)) { throw "package has no RobRun.exe" }
    return $exe
}

# ----------------------------------------------------------------------- pipe
function New-RobRunPipe {
    $name = 'RobRun.' + ([Guid]::NewGuid().ToString('N'))
    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
        $name,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::None)
    return @{ name = $name; pipe = $pipe }
}

function Write-Frame($stream, [byte[]]$bytes) {
    $len = [BitConverter]::GetBytes([uint32]$bytes.Length)
    $stream.Write($len, 0, 4)
    if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
    $stream.Flush()
}

function Read-Exact($stream, [int]$n) {
    $buf = New-Object byte[] $n
    $off = 0
    while ($off -lt $n) {
        $got = $stream.Read($buf, $off, $n - $off)
        if ($got -le 0) { throw "pipe closed" }
        $off += $got
    }
    return $buf
}

function Read-Frame($stream) {
    $h = Read-Exact $stream 4
    $len = [BitConverter]::ToUInt32($h, 0)
    if ($len -eq 0 -or $len -gt 4096) { throw ("bad frame length " + $len) }
    $body = Read-Exact $stream ([int]$len)
    return [System.Text.Encoding]::UTF8.GetString($body)
}

# ------------------------------------------------------------------- game parts
function Get-SteamRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    try { $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath; if ($p) { $roots.Add(($p -replace '/', '\')) } } catch {}
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try { $p = (Get-ItemProperty $k -ErrorAction Stop).InstallPath; if ($p) { $roots.Add($p) } } catch {}
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        if (Test-Path $r) { $out.Add($r) }
        $lf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path $lf) {
            foreach ($m in [regex]::Matches((Get-Content $lf -Raw), '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                if (Test-Path $lib) { $out.Add($lib) }
            }
        }
    }
    $out | Select-Object -Unique
}

function Resolve-GameExe {
    if ($GameExe -and (Test-Path $GameExe)) { return (Resolve-Path $GameExe).Path }
    foreach ($r in Get-SteamRoots) {
        $acf = Join-Path $r ("steamapps\appmanifest_{0}.acf" -f $steamAppId)
        if (Test-Path $acf) {
            $dir = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
            if ($dir) {
                $exe = Join-Path $r ("steamapps\common\{0}\ROB RUN.exe" -f $dir)
                if (Test-Path $exe) { return $exe }
            }
        }
    }
    return $null
}

function Start-Game {
    if (Get-Process -Name 'ROB RUN' -ErrorAction SilentlyContinue) { Info "game already running"; return }
    $exe = Resolve-GameExe
    if ($exe) {
        Info ("launching game: " + $exe)
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) | Out-Null
        return
    }
    Warn "ROB RUN.exe not found; steam://rungameid/$steamAppId"
    Start-Process ("steam://rungameid/{0}" -f $steamAppId) | Out-Null
}

# ------------------------------------------------------------------- main flow
if (-not (Test-Admin)) {
    Bad "not elevated. run inject.bat (it self-elevates), not inject.ps1 directly."
    exit 5
}

Ok "elevated"

$rt = Resolve-Runtime
Info ("runtime: " + $rt)

if ($LocalApi) { $ticket = Get-TicketLocal } else { $ticket = Get-TicketVendor }
Ok ("ticket " + $ticket.ticket.Substring(0, 12) + "... expires " + $ticket.signed_expires)

$server = if ($LocalApi) { 'http://127.0.0.1:8765' } else { $Vendor }

$bootstrapLines = @(
    'ROBRUN-SIG/1',
    $server,
    '1',
    [string]$ticket.ticket,
    [string]$ticket.hwid_digest,
    [string]([int64]$ticket.signed_issued),
    [string]([int64]$ticket.signed_expires),
    [string]$ticket.signature
)
# the runtime validates the launch string length, then splits on the
# newline characters; keep it well under its 4096-byte gate
$nl = [string][char]10
$payload = [System.Text.Encoding]::UTF8.GetBytes(($bootstrapLines -join $nl) + $nl)
Info ("bootstrap = " + $payload.Length + " bytes")

# session snapshot for debugging (ticket is short-lived)
try {
    @{
        server      = $server
        gameId      = 1
        ticket      = $ticket.ticket
        hwid_digest = $ticket.hwid_digest
        issued      = [int64]$ticket.signed_issued
        expires     = [int64]$ticket.signed_expires
        signature   = $ticket.signature
        runtime     = $rt
        at          = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -Path $sessionJs -Encoding UTF8
} catch {}

$session = New-RobRunPipe
Info ("pipe: " + $session.name)

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName        = $rt
$si.Arguments       = '--loader-pipe ' + $session.name
$si.WorkingDirectory = Split-Path $rt -Parent
$si.UseShellExecute = $false
$si.CreateNoWindow  = $true
$si.RedirectStandardOutput = $true
$si.RedirectStandardError  = $true
$child = [System.Diagnostics.Process]::Start($si)
Info ("runtime pid " + $child.Id + ", waiting for the pipe ...")

# drain output to files in the background so a crash still leaves a reason
$outTask = $child.StandardOutput.ReadToEndAsync()
$errTask = $child.StandardError.ReadToEndAsync()

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$waiter = $session.pipe.WaitForConnectionAsync()
while (-not $waiter.IsCompleted -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
    if ($child.HasExited) {
        Bad ("runtime exited early with 0x" + $child.ExitCode.ToString('X8'))
        try { $outTask.Wait(1500) | Out-Null } catch {}
        try { $errTask.Wait(1500) | Out-Null } catch {}
        foreach ($pair in @(@($procOut, $outTask), @($procErr, $errTask))) {
            try { Set-Content -Path $pair[0] -Value $pair[1].Result -Encoding UTF8 } catch {}
        }
        if (Test-Path $procOut) { Write-Host "--- stdout ---"; Get-Content $procOut | Select-Object -Last 40 }
        if (Test-Path $procErr) { Write-Host "--- stderr ---"; Get-Content $procErr | Select-Object -Last 40 }
        exit 3
    }
}
if (-not $waiter.IsCompleted) { Bad "runtime never connected to the pipe"; $child.Kill(); exit 4 }
Ok "runtime connected"

# pid check, exactly like the loader does
$clientPid = 0
[void][Inj32]::GetNamedPipeClientProcessId($session.pipe.SafePipeHandle.DangerousGetHandle(), [ref]$clientPid)
if ($clientPid -ne 0 -and $clientPid -ne $child.Id) {
    Bad ("pipe client pid " + $clientPid + " != child pid " + $child.Id)
    exit 6
}

Info "writing bootstrap frame"
Write-Frame $session.pipe $payload

# read status frames
$ready = $false
$states = New-Object System.Collections.Generic.List[string]
$readDeadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $readDeadline) {
    $frame = $null
    try { $frame = Read-Frame $session.pipe } catch { break }
    if ($null -eq $frame) { break }
    $states.Add($frame)
    Write-Host ("    <runtime> " + $frame) -ForegroundColor DarkCyan
    if ($frame -eq 'ready' -and -not $ready) {
        $ready = $true
        Ok "runtime ready (driver up, overlay server live)"
        if (-not $NoGame) { Start-Game }
        # keep the window open for waiting_game / errors
        $readDeadline = (Get-Date).AddSeconds(120)
    }
    elseif ($frame -like 'error:*') {
        Bad ("runtime reported: " + $frame)
        break
    }
    elseif ($frame -eq 'waiting_game' -and $ready) {
        Info "runtime is waiting for the game window (ROB RUN.exe)"
        if (Get-Process -Name 'ROB RUN' -ErrorAction SilentlyContinue) {
            Ok "game window is up"
            break
        }
    }
}

try { $session.pipe.Dispose() } catch {}

if ($ready -and -not $NoGame) {
    # let the game come up, then verify the overlay attached
    Start-Sleep -Seconds 6
    $attach = Join-Path $root 'attach.ps1'
    if (Test-Path $attach) {
        Info "verifying overlay attach ..."
        & powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File $attach -NoLaunch -TimeoutSec 90
    }
    Ok "inject done. Insert = menu, End = unload."
    exit 0
}
if ($ready) { Ok "handshake done (no game requested)."; exit 0 }

Warn "no 'ready' frame received. states seen:"
foreach ($st in $states) { Write-Host ("    " + $st) }
if ($child.HasExited) { Bad ("runtime exited 0x" + $child.ExitCode.ToString('X8')) }
exit 7
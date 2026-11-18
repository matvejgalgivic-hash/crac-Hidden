@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title ROB RUN - inject

rem =====================================================================
rem  ROB RUN - full inject, started from THIS batch file.
rem
rem  PRIMARY PATH: direct pipe inject (inject.ps1)
rem    the loader UI is out of the loop. This does the handshake itself:
rem       ticket (local api 127.0.0.1:8765)
rem       -> named pipe RobRun.<guid>
rem       -> RobRun.exe --loader-pipe <name>
rem       -> bootstrap frame ROBRUN-SIG/1
rem       -> wait "ready" (driver mapped, overlay server live)
rem       -> launch game
rem       -> verify the overlay window attached
rem
rem  FALLBACK PATH: loader UI (LoaderCrack.exe --test-launch)
rem    only used when the direct path fails to start the runtime.
rem
rem  Order is fixed and it matters:
rem    1. elevate                     (kdmapper needs an admin token)
rem    2. stop leftovers              (old runtime / loader / game / api)
rem    3. start the local license api (api.py on 127.0.0.1:8765)
rem    4. inject                      (direct pipe; loader fallback)
rem    5. wait for RobRun.exe         (driver mapped, handshake done)
rem    6. start the game              AFTER the runtime is up
rem    7. verify the overlay attached
rem
rem  Flags (optional):
rem    norestart     do not close a game that is already running
rem    nopause       do not wait for a key press at the end
rem    loader        skip the direct path, use the loader UI
rem    nogame        handshake only, do not start the game
rem =====================================================================

set "LOGDIR=%~dp0logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>nul
set "CHAINLOG=%LOGDIR%\chain.log"
set "APIWAIT=40"
set "CRACKWAIT=150"
set "GAMEWAIT=240"
set "NOPAUSE=0"
set "NORESTART=0"
set "USELOADER=0"
set "NOGAME=0"
rem %* keeps the original command line forever, but %1 does not: the parse
rem loop below shifts it away. Grab it first so UAC can forward the flags.
set "ALLARGS=%*"

:parse
if "%~1"=="" goto :parsed
if /I "%~1"=="nopause"   set "NOPAUSE=1"
if /I "%~1"=="norestart" set "NORESTART=1"
if /I "%~1"=="loader"    set "USELOADER=1"
if /I "%~1"=="nogame"    set "NOGAME=1"
shift
goto :parse
:parsed

call :log "==== START %DATE% %TIME% ===="

rem ------------------------------------------------------------- 1. elevate
fsutil dirty query %SystemDrive% >nul 2>&1
if errorlevel 1 (
    echo [*] requesting administrator elevation...
    call :log "elevating"
    set "ELARGS="
    if not "!ALLARGS!"=="" set "ELARGS=-ArgumentList '!ALLARGS!'"
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs !ELARGS!"
    exit /b 0
)
echo [*] elevated: ok
call :log "elevated ok"
echo.

rem If a runtime from an earlier run is already up, do not tear it down -
rem just start the game and check the overlay (step 6 below).
tasklist /FI "IMAGENAME eq RobRun.exe" 2>nul | find /I "RobRun.exe" >nul
if not errorlevel 1 (
    echo [*] RobRun.exe is already running - game + overlay check only.
    call :log "runtime already up, skipping to attach"
    goto :startgame
)

rem ------------------------------------------------------------- 2. cleanup
rem the api that may still be running is an OLD copy of api.py, so it has to
rem go first - otherwise the loader talks to the stale server.
echo [*] stopping leftovers...
call :log "cleanup"
call "%~dp0stop.bat" >nul 2>&1
timeout /t 2 /nobreak >nul

rem ------------------------------------------------------- 3. license server
set "PY=pythonw"
where pythonw >nul 2>nul || set "PY=python"
where %PY% >nul 2>nul
if errorlevel 1 (
    echo [x] Python not found in PATH.
    echo     install Python or add it to PATH, then run start.bat again.
    call :log "FATAL: no python"
    goto :fail
)
echo [*] starting local license server (%PY%) ...
call :log "starting api with %PY%"
start "loader-api" /min "%PY%" "%~dp0api.py"

echo [*] waiting for http://127.0.0.1:8765 ...
call :log "waiting for api"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$d=(Get-Date).AddSeconds(%APIWAIT%); while((Get-Date) -lt $d){ try{ $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8765/api/v1/ping' -TimeoutSec 2; if($r.StatusCode -eq 200){exit 0} }catch{}; Start-Sleep -Milliseconds 250 }; exit 1"
if errorlevel 1 (
    echo [x] the license server did not come up on 8765.
    echo     see api.log / api_err.log
    call :log "FATAL: api never came up"
    goto :fail
)
echo [*] license server: up
call :log "api up"

rem sanity: the server must advertise the RobRun runtime protocol, otherwise
rem the runtime never gets a pipe and RobRun.exe dies on launch.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try{ $m=(Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/v1/me' -TimeoutSec 5).data; $g=$m.games | Where-Object { $_.id -eq 1 }; Write-Host ('    protocol=' + $g.runtime_protocol + '  run_steam=' + $g.run_steam + '  appid=' + $g.steam_appid + '  lifetime=' + $m.lifetime + '  days=' + $m.days); if($g.runtime_protocol -ne 'robrun-v1'){ exit 2 } }catch{ exit 3 }"
if errorlevel 1 (
    echo [x] license server is not serving the RobRun protocol.
    call :log "FATAL: runtime_protocol mismatch"
    goto :fail
)

rem --------------------------------------------------------- 4. start runtime
rem The runtime must be armed BEFORE the game: RobRun.exe only watches for a
rem "ROB RUN.exe" process, so a stale game would attach before the driver is
rem up. Close it first unless the caller asked to keep it.
if "!NORESTART!"=="0" (
    taskkill /F /IM "ROB RUN.exe" >nul 2>nul
)

rem PRIMARY: inject.ps1 mints a FRESH VENDOR ticket and hands RobRun exactly
rem what the real loader hands it:
rem     server = https://95.85.230.17      (GameLoader.Config::Servers[0])
rem Two traps this avoids:
rem  1. api.py caches real_ticket.json and refresh_ticket() reuses it for up to
rem     90s. A ticket the loader already consumed cannot be used twice, so the
rem     runtime answers "invalid launch data" and dies. Minting at the
rem     vendor skips that cache entirely.
rem  2. The local api would hand over "http://127.0.0.1:8765" as the server,
rem     not the vendor url the real loader always sends.
set "INJ=99"
if "!USELOADER!"=="0" (
    echo.
    echo [*] injecting through the direct pipe ^(vendor ticket^) ...
    call :log "inject.ps1 vendor"
    set "INJARGS=-ExecutionPolicy Bypass -NoLogo -File ""%~dp0inject.ps1"" -TimeoutSec %CRACKWAIT%"
    if "!NOGAME!"=="1" set "INJARGS=!INJARGS! -NoGame"
    powershell -NoProfile !INJARGS!
    set INJ=!errorlevel!
    >>"%CHAINLOG%" echo [%date% %time%] inject.ps1 vendor rc=!INJ!

    if not "!INJ!"=="0" (
        echo [x] vendor inject failed ^(rc=!INJ!^) - second attempt with a freshly minted ticket ...
        >>"%CHAINLOG%" echo [%date% %time%] retry inject.ps1 after dropping the ticket cache
        taskkill /F /IM RobRun.exe >nul 2>nul
        timeout /t 2 /nobreak >nul
        rem bust the 90s ticket cache: api.py re-mints from license.json, so the
        rem runtime gets a ticket nobody has used yet
        if exist "%~dp0real_ticket.json" del /f /q "%~dp0real_ticket.json" >nul 2>nul
        set "INJARGS2=-ExecutionPolicy Bypass -NoLogo -File ""%~dp0inject.ps1"" -LocalApi -TimeoutSec %CRACKWAIT%"
        if "!NOGAME!"=="1" set "INJARGS2=!INJARGS2! -NoGame"
        powershell -NoProfile !INJARGS2!
        set INJ=!errorlevel!
        >>"%CHAINLOG%" echo [%date% %time%] inject.ps1 local api rc=!INJ!
    )
)
if "!INJ!"=="0" (
    echo.
    echo [+] INJECT DONE.  Insert = menu,  End = unload.
    call :log "direct inject ok"
    goto :done
)
if "!USELOADER!"=="0" (
    echo [x] both direct attempts failed ^(rc=!INJ!^) - falling back to the loader UI.
    >>"%CHAINLOG%" echo [%date% %time%] direct inject failed rc=!INJ!, fallback to loader
    taskkill /F /IM RobRun.exe >nul 2>nul
    timeout /t 3 /nobreak >nul
)

rem FALLBACK: loader UI brings the runtime up; then start.bat opens the game.
echo.
echo [*] starting the loader ^(autologin + PLAY^) ...
call :log "starting LoaderCrack.exe --test-launch"
start "" "%~dp0LoaderCrack.exe" --test-launch

echo [*] waiting for the cheat runtime (RobRun.exe) ...
rem A runtime that is already dying must not count as "up": wait until the
rem process survives a few seconds, otherwise attach.ps1 runs against nothing
rem and reports "runtime is not running - arm the crack first".
set RC=
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$end=(Get-Date).AddSeconds(%CRACKWAIT%); while((Get-Date) -lt $end){ $p=Get-Process -Name 'RobRun' -ErrorAction SilentlyContinue; if($p){ foreach($q in $p){ try{ [void]$q.WaitForExit(3000) }catch{} }; if(Get-Process -Name 'RobRun' -ErrorAction SilentlyContinue){ exit 0 } }; if(-not (Get-Process -Name 'LoaderCrack' -ErrorAction SilentlyContinue)){ exit 3 }; Start-Sleep -Milliseconds 500 }; exit 1"
set RC=!errorlevel!
>>"%CHAINLOG%" echo [%date% %time%] loader wait rc=!RC!
if not "!RC!"=="0" goto :no_runtime
echo [+] runtime is up
call :log "runtime up"
timeout /t 3 /nobreak >nul

:startgame
rem --------------------------------------------------------- 6. start game
rem RobRun.exe only LOOKS for a "ROB RUN.exe" process - it never starts one.
rem The cheat must be armed before the game, so attach.ps1 brings the game up
rem here (through Steam when available, direct exe otherwise) and then waits
rem for the "Hidden" overlay window to appear.
if "!NORESTART!"=="0" (
    taskkill /F /IM "ROB RUN.exe" >nul 2>nul
)
echo.
echo [*] starting the game and checking the overlay ...
call :log "attach.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0attach.ps1" -TimeoutSec %GAMEWAIT% -GraceSec 8
set ATT=!errorlevel!
>>"%CHAINLOG%" echo [%date% %time%] attach.ps1 rc=!ATT!

if "!ATT!"=="0" (
    echo.
    echo [+] INJECT DONE.  Insert = menu,  End = unload.
    call :log "OK"
) else (
    echo.
    echo [x] inject did not finish cleanly ^(rc=!ATT!^).
    echo     look at the window dump above, loader_crack.log and api.log.
    call :log "FAILED" "rc=!ATT!"
)
goto :done

:no_runtime
if "!RC!"=="3" (
    echo [x] the loader closed before RobRun.exe started.
) else (
    echo [x] RobRun.exe did not start within %CRACKWAIT%s.
)
echo.
echo --- loader_crack.log (tail) ---
powershell -NoProfile -Command ^
  "Get-Content -LiteralPath '%~dp0loader_crack.log' -Tail 14 -ErrorAction SilentlyContinue | ForEach-Object { '    ' + $_ }"
echo.
echo --- api.log (tail) ---
powershell -NoProfile -Command ^
  "Get-Content -LiteralPath '%~dp0api.log' -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { '    ' + $_ }"
echo.
echo --- rbrun.err.log (tail) ---
powershell -NoProfile -Command ^
  "Get-Content -LiteralPath '%~dp0logs\rbrun.err.log' -Tail 14 -ErrorAction SilentlyContinue | ForEach-Object { '    ' + $_ }"
echo.
echo  most common causes:
echo    - UAC declined
echo    - antivirus/EDR removed iqvw64e.sys from %%TEMP%%
echo    - Windows core isolation (HVCI) or the vulnerable-driver blocklist is on
echo    - the vendor ticket was rejected by the runtime ^(key dead / ticket reused^)
echo    - the runtime got a server string other than https://95.85.230.17
call :log "FATAL: runtime never up" "rc=!RC!"
goto :fail

:done
if "!NOPAUSE!"=="0" pause
echo.
timeout /t 8 >nul
exit /b 0

:fail
echo.
if "!NOPAUSE!"=="0" pause
exit /b 1

:log
rem Two traps in one line, both real:
rem   1. echo to an already-open device handle drops everything after it, so
rem      the redirect has to come first: >>file echo ...
rem   2. ~1/~2 are expanded here, while !VAR! is expanded by the caller. Using
rem      them together (call :log "rc=!ATT!") makes cmd drop the ~1 text and
rem      write "rc=" alone. The caller quotes each piece separately.
set "TS=%date% %time%"
>>"%CHAINLOG%" echo [!TS!] %~1 %~2
goto :eof

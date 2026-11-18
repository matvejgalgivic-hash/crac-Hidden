@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title ROB RUN chain - loader

rem =====================================================================
rem  FULL CHAIN, CORRECT ORDER:
rem    1. elevate (kdmapper needs an admin token - filtered token dies
rem        with 0xC0000409 before the overlay even exists)
rem    2. kill leftovers (stale api, half-dead crack, running game)
rem    3. local license api on 127.0.0.1:8765
rem    4. crack runtime: LoaderCrack (il2cpp integrity -> ret, local
rem       server, autologin) -> auto-click PLAY -> RobRun.exe
rem    5. WAIT for RobRun.exe to be up (driver mapped, overlay server
rem       listening on its pipe)
rem    6. launch the game SECOND through Steam/direct exe
rem    7. verify the "Hidden" overlay actually attached
rem =====================================================================

set "LOGDIR=%~dp0logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>nul
set "CHAINLOG=%LOGDIR%\chain.log"
set "APIWAIT=30"
set "CRACKWAIT=120"
set "GAMEWAIT=240"

call :log "==== chain start %DATE% %TIME% ===="

rem ---------------------------------------------------------------- 1. elevate
fsutil dirty query %SystemDrive% >nul 2>&1
if errorlevel 1 (
    echo [*] requesting administrator elevation...
    call :log "elevating"
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b 0
)
echo [*] elevated: ok
call :log "elevated ok"

rem ---------------------------------------------------------------- 2. cleanup
echo [*] stopping leftovers...
call :log "cleanup: stop.bat"
call "%~dp0stop.bat" >nul 2>&1
rem stop.bat kills RobRun/LoaderCrack/Loader and the api port, plus the game
rem we added below. give the OS a moment to release the pipe and the port.
timeout /t 2 /nobreak >nul

rem ------------------------------------------------------- 3. local license api
set "PY=pythonw"
where pythonw >nul 2>nul || set "PY=python"
where %PY% >nul 2>nul
if errorlevel 1 (
    echo [!] no python found in PATH - api.py cannot serve the contract.
    echo     install python or add it to PATH, then run start.bat again.
    call :log "FATAL: no python"
    pause
    exit /b 1
)
echo [*] starting local license api (%PY%) ...
call :log "starting api with %PY%"
start "loader-api" /min "%PY%" "%~dp0api.py"

echo [*] waiting for api on 127.0.0.1:8765 ...
call :log "waiting for api"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$d=(Get-Date).AddSeconds(%APIWAIT%); while((Get-Date) -lt $d){ try{ $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8765/api/v1/ping' -TimeoutSec 2; if($r.StatusCode -eq 200){exit 0} }catch{}; Start-Sleep -Milliseconds 250 }; exit 1"
if errorlevel 1 (
    echo [!] api.py did not come up on 8765.
    echo     read api_err.log and api.log, then run start.bat again.
    call :log "FATAL: api never came up"
    pause
    exit /b 1
)
echo [*] api: up
call :log "api up"

rem ------------------------------------------------------ 4. crack -> runtime
rem LoaderCrack is already elevated (this script is), so RobRun.exe inherits
rem an admin token and kdmapper can map its driver. --test-launch makes the
rem shim fill the key, submit, and click PLAY automatically.
echo [*] arming crack (loader -> autologin -> play) ...
call :log "starting LoaderCrack --test-launch"
start "" "%~dp0LoaderCrack.exe" --test-launch

rem loaders take several seconds to boot WebView2 + login + click play.
rem poll; if the runtime is not up in CRACKWAIT seconds, dump the log tail.
echo [*] waiting for crack runtime (RobRun.exe) ...
set "CRACKUP="
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$end=(Get-Date).AddSeconds(%CRACKWAIT%); while((Get-Date) -lt $end){ if(Get-Process -Name 'RobRun' -ErrorAction SilentlyContinue){ exit 0 }; if(-not (Get-Process -Name 'LoaderCrack' -ErrorAction SilentlyContinue)){ exit 3 }; Start-Sleep -Milliseconds 500 }; exit 1"
set "RC=!errorlevel!"
if "!RC!"=="0" goto :crack_ok
if "!RC!"=="3" (
    echo [!] LoaderCrack.exe exited before the runtime came up.
) else (
    echo [!] RobRun.exe never came up inside %CRACKWAIT%s.
)
echo.
echo --- loader_crack.log (tail) ---
powershell -NoProfile -Command ^
  "Get-Content -LiteralPath '%~dp0loader_crack.log' -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { '    ' + $_ }"
echo.
echo  most common causes:
echo    - UAC declined
echo    - antivirus/EDR quarantined iqvw64e.sys from %%TEMP%%
echo    - Windows core isolation (HVCI) or the vulnerable-driver blocklist is on
echo    - the crack log says the driver failed to map
call :log "FATAL: runtime never up, rc=!RC!"
pause
exit /b 1

:crack_ok
echo [*] crack runtime: up
call :log "runtime up"
timeout /t 2 /nobreak >nul

rem --------------------------------------------- 5+6+7. game + attach + verify
rem attach.ps1: discovers the game through the Steam manifest (appid 4262460),
rem starts it AFTER the runtime, then confirms the "Hidden" overlay attached.
echo [*] launching game and verifying overlay attach ...
call :log "attach.ps1 start"
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0attach.ps1" -TimeoutSec %GAMEWAIT%
set "ATT=!errorlevel!"
call :log "attach.ps1 rc=!ATT!"

if not "!ATT!"=="0" (
    echo [!] attach verification did not finish cleanly (rc=!ATT!).
    echo     see the window dump above and loader_crack.log.
)

echo.
echo [*] chain armed. Insert = menu, End = unload.
echo [*] logs: loader_crack.log, api.log, !CHAINLOG!
call :log "==== chain end ===="
echo.
timeout /t 6 >nul
exit /b 0

:log
echo [%date% %time%] %~1>>"%CHAINLOG%"
goto :eof
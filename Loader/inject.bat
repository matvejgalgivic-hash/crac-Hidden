@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title ROB RUN - direct inject

rem ==============================================================
rem  Direct injector. No loader UI. This bat only elevates and
rem  hands off to inject.ps1, which does the real work:
rem    vendor ticket -> named pipe -> RobRun.exe -> bootstrap
rem    -> game -> overlay verify
rem
rem  Flags (pass through):
rem    --local          take the ticket from the local api (127.0.0.1:8765)
rem    --no-game        handshake only, do not start the game
rem    --timeout N      handshake timeout seconds (default 90)
rem ==============================================================

fsutil dirty query %SystemDrive% >nul 2>&1
if errorlevel 1 (
    echo [*] requesting administrator elevation...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b 0
)

set "PSARGS="
set "WANT_LOCAL=0"
set "WANT_NOGAME=0"
set "WANT_TIMEOUT="
:args
if "%~1"=="" goto :argsdone
if /I "%~1"=="--local"   set "WANT_LOCAL=1"
if /I "%~1"=="--no-game" set "WANT_NOGAME=1"
if /I "%~1"=="--timeout" set "WANT_TIMEOUT=%~2"
shift
goto :args
:argsdone

set "PSARGS=-ExecutionPolicy Bypass -NoLogo -File ""%~dp0inject.ps1"""
if "%WANT_LOCAL%"=="1"  set "PSARGS=%PSARGS% -LocalApi"
if "%WANT_NOGAME%"=="1" set "PSARGS=%PSARGS% -NoGame"
if not "%WANT_TIMEOUT%"=="" set "PSARGS=%PSARGS% -TimeoutSec %WANT_TIMEOUT%"

echo [*] injecting ...
powershell -NoProfile %PSARGS%
set "RC=!errorlevel!"

echo.
if "!RC!"=="0" (
    echo [+] inject complete.
) else (
    echo [!] inject failed, rc=!RC!.
    echo     logs: logs\rbrun.out.log, logs\rbrun.err.log, logs\inject_session.json
    echo     also: loader_crack.log ^(if the loader path was used^)
)
echo.
pause
exit /b !RC!
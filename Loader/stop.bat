@echo off
setlocal EnableExtensions
title ROB RUN chain - stop

rem ==============================================================
rem  Tears the whole chain down: cheat runtime, game, shim,
rem  original loader, local api server, and the temp driver file
rem  kdmapper dropped (iqvw64e.sys) if it is still around.
rem  Order matters: runtime first, then game, then the rest.
rem  Elevate first: the shim maps a driver with an admin token, so a
rem  filtered token cannot kill it (access denied).
rem ==============================================================

fsutil dirty query %SystemDrive% >nul 2>&1
if errorlevel 1 (
    echo [*] requesting administrator elevation...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b 0
)

echo [*] stopping cheat runtime RobRun.exe ...
taskkill /F /IM RobRun.exe >nul 2>nul

echo [*] closing game ROB RUN.exe ...
taskkill /F /IM "ROB RUN.exe" >nul 2>nul

echo [*] stopping crack shim / loader ...
taskkill /F /IM LoaderCrack.exe >nul 2>nul
taskkill /F /IM Loader.exe      >nul 2>nul

echo [*] stopping local api on port 8765 ...
powershell -NoProfile -Command ^
  "Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }" >nul 2>nul

rem wait until the port is really free - start.bat relaunches api.py right after
powershell -NoProfile -Command ^
  "$d=(Get-Date).AddSeconds(10); while((Get-Date) -lt $d){ if(-not (Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue)){ exit 0 }; Start-Sleep -Milliseconds 250 }; exit 1" >nul 2>nul
if errorlevel 1 (
    echo [!] port 8765 is still busy - an old license server may keep running.
    echo     the loader could talk to a stale api.py; reboot if it persists.
)

rem pythonw launcher sometimes leaves the api python running without the port
powershell -NoProfile -Command ^
  "Get-CimInstance Win32_Process -Filter \"Name='pythonw.exe' OR Name='python.exe'\" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*api.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>nul

echo [*] removing leftover driver file from %%TEMP%% ...
del /f /q "%TEMP%\iqvw64e.sys" >nul 2>nul

echo stopped.
timeout /t 2 >nul
exit /b 0
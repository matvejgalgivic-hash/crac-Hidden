@echo off
setlocal EnableExtensions
title ROB RUN chain - status

echo ============================================================
echo   ROB RUN chain status
echo ============================================================
echo.

rem --- api server ---
powershell -NoProfile -Command ^
  "try { $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8765/api/v1/ping' -TimeoutSec 2; Write-Host ('[+] api          : up (HTTP ' + $r.StatusCode + ')') -ForegroundColor Green } catch { Write-Host '[x] api          : down' -ForegroundColor Red }"

rem --- processes ---
for %%N in (LoaderCrack.exe Loader.exe RobRun.exe "ROB RUN.exe") do (
    tasklist /FI "IMAGENAME eq %%~N" 2>nul | find /I "%%~N" >nul && (
        echo [+] process      : %%~N running
    ) || (
        echo [-] process      : %%~N not running
    )
)

echo.
echo --- runtime ^> game overlay attach check ---
if exist "%~dp0attach.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0attach.ps1" -NoLaunch -TimeoutSec 5
) else (
    echo [!] attach.ps1 missing.
)

echo.
echo ============================================================
timeout /t 8 >nul
exit /b 0
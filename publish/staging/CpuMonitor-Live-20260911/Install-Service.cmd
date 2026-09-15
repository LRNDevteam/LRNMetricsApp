@echo off
setlocal

rem ---------------------------------------------------------------------------
rem  Installs the LRN CPU Monitor as a Windows service.
rem
rem  Batch rather than PowerShell so the execution policy never gets in the way,
rem  and because "sc" in PowerShell resolves to the Set-Content alias instead of
rem  sc.exe, which silently does the wrong thing.
rem
rem  The service runs FROM WHEREVER THIS FILE IS. Extract the zip to its final
rem  location first, then right-click this file and choose "Run as administrator".
rem ---------------------------------------------------------------------------

set "SERVICE_NAME=LRN - CPU Monitor"
set "EXE_PATH=%~dp0CpuMonitor\LRN.CpuMonitor.exe"

echo.
echo  Service : %SERVICE_NAME%
echo  Binary  : %EXE_PATH%
echo.

rem Creating a service requires elevation; check before doing anything.
net session >nul 2>&1
if errorlevel 1 (
    echo  ERROR: Not running as Administrator.
    echo         Right-click Install-Service.cmd and choose "Run as administrator".
    echo.
    pause
    exit /b 1
)

if not exist "%EXE_PATH%" (
    echo  ERROR: Binary not found at the path above.
    echo         Extract the whole zip, keeping the CpuMonitor folder next to
    echo         this script, then run this again.
    echo.
    pause
    exit /b 1
)

rem Remove any half-installed copy so this file is safe to re-run.
sc query "%SERVICE_NAME%" >nul 2>&1
if not errorlevel 1 (
    echo  Existing service found - stopping and removing it first...
    sc stop "%SERVICE_NAME%" >nul 2>&1
    timeout /t 5 /nobreak >nul
    sc delete "%SERVICE_NAME%" >nul 2>&1
    timeout /t 2 /nobreak >nul
)

rem LocalSystem is what lets the service read the image path and command line of
rem processes owned by other accounts. Without it you still get CPU figures for
rem every process, but identity for only your own.
echo  Creating service...
sc create "%SERVICE_NAME%" binPath= "%EXE_PATH%" start= auto obj= LocalSystem
if errorlevel 1 goto :failed

echo  Setting description...
sc description "%SERVICE_NAME%" "Logs any process whose CPU exceeds the configured threshold, with its name, path, PID, owner and launching process. Also logs the top consumers when total machine CPU is high. Attributes SQL Server load to the calling application."

echo  Setting crash recovery (restart after 60s, three attempts)...
sc failure "%SERVICE_NAME%" reset= 86400 actions= restart/60000/restart/60000/restart/60000

echo.
echo  Starting service...
sc start "%SERVICE_NAME%"
if errorlevel 1 goto :failed

echo.
echo  ----------------------------------------------------------------
sc qc "%SERVICE_NAME%"
echo  ----------------------------------------------------------------
sc query "%SERVICE_NAME%" | find "STATE"
echo  ----------------------------------------------------------------
echo.
echo  Installed. SERVICE_START_NAME above must read LocalSystem.
echo.
echo  Logs:   %~dp0CpuMonitor\Logs\
echo            cpu-breaches-^<date^>.txt   threshold breaches only
echo            cpu-monitor-^<date^>.txt    everything
echo            cpu-breaches.jsonl        same breaches as JSON
echo.
echo  Config: %~dp0CpuMonitor\appsettings.json
echo          Re-read live; no restart needed to change a threshold.
echo.
echo  Within 10 minutes the main log gets a "Heartbeat:" line listing the
echo  top consumers. That is how you confirm it is alive when nothing is
echo  breaching. If you never see one, the service is not running.
echo.
pause
exit /b 0

:failed
echo.
echo  FAILED - see the sc error above.
echo    5    = access denied (not elevated)
echo    1073 = service already exists
echo    1053 = did not start in time; check CpuMonitor\Logs\cpu-monitor-*.txt
echo.
pause
exit /b 1

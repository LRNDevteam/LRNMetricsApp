@echo off
setlocal EnableExtensions

title Extended Safe C: Cleanup
color 0E

echo.
echo  EXTENDED CLEANUP - frees more than basic temp-only script
echo  Run as Administrator. Type YES to confirm.
echo.
set /p CONFIRM=Type YES to continue: 
if /I not "%CONFIRM%"=="YES" exit /b 1

echo.
echo [1] Temp folders...
call :CleanDir "%TEMP%"
call :CleanDir "%LOCALAPPDATA%\Temp"
call :CleanDir "C:\Windows\Temp"

echo [2] Prefetch + thumbnails...
if exist "C:\Windows\Prefetch" del /f /s /q "C:\Windows\Prefetch\*.*" >nul 2>&1
del /f /q "%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db" >nul 2>&1

echo [3] Windows Update cache...
net stop wuauserv >nul 2>&1
net stop bits >nul 2>&1
call :CleanDir "C:\Windows\SoftwareDistribution\Download"
net start bits >nul 2>&1
net start wuauserv >nul 2>&1

echo [4] DISM component cleanup (5-15 min, needs admin)...
Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase

echo [5] Dev caches (NuGet, npm, pip)...
dotnet nuget locals all --clear >nul 2>&1
npm cache clean --force >nul 2>&1
pip cache purge >nul 2>&1

echo [6] Cursor / VS Code logs...
call :CleanDir "%APPDATA%\Cursor\logs"
call :CleanDir "%APPDATA%\Cursor\CachedData"
call :CleanDir "%LOCALAPPDATA%\Temp\cursor"

echo [7] Recycle Bin...
PowerShell -NoProfile -Command "Clear-RecycleBin -Force -ErrorAction SilentlyContinue" >nul 2>&1

echo.
echo IMPORTANT - often 10-30 GB more in Windows Settings:
echo   Settings ^> System ^> Storage ^> Temporary files
echo   Check: Previous Windows installation, Windows Update Cleanup
echo.
set /p RUNCLEAN=Run Disk Cleanup now? (Y/N): 
if /I "%RUNCLEAN%"=="Y" cleanmgr /d C: /VERYLOWDISK

echo Done. Run Analyze-C-Drive.ps1 to see remaining large folders.
pause
exit /b 0

:CleanDir
if not exist "%~1" goto :eof
del /f /s /q "%~1\*.*" >nul 2>&1
for /d %%D in ("%~1\*") do rd /s /q "%%D" >nul 2>&1
goto :eof

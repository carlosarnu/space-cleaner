@echo off
title Space Cleaner - Libera espacio en tu PC
setlocal enabledelayedexpansion

rem ------------------------------------------------------------------
rem  Carpeta de la aplicacion = la propia donde esta este .bat.
rem  Asi funciona igual en cualquier equipo y para cualquier usuario,
rem  sin rutas fijas de nadie.
rem ------------------------------------------------------------------
set "APPDIR=%~dp0"
if "%APPDIR:~-1%"=="\" set "APPDIR=%APPDIR:~0,-1%"
set "PORT="

if exist "%APPDIR%\port.txt" set /p PORT=<"%APPDIR%\port.txt"
if defined PORT goto CHECK

:START
if exist "%APPDIR%\port.txt" del /q "%APPDIR%\port.txt"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APPDIR%\server.ps1"
for /l %%i in (1,1,60) do (
  if exist "%APPDIR%\port.txt" goto WAIT
  ping -n 2 127.0.0.1 >nul 2>&1
)
echo [ERROR] El servidor no arranco.
pause
exit /b 1

:WAIT
for /l %%i in (1,1,60) do (
  if not exist "%APPDIR%\port.txt" goto START
  set /p PORT=<"%APPDIR%\port.txt"
  powershell -NoProfile -Command "try{$null=Invoke-WebRequest -Uri 'http://localhost:!PORT!/api/disks' -TimeoutSec 2 -UseBasicParsing;exit 0}catch{exit 1}" >nul 2>&1
  if not errorlevel 1 goto OPEN
  ping -n 2 127.0.0.1 >nul 2>&1
)
goto START

:CHECK
powershell -NoProfile -Command "try{$null=Invoke-WebRequest -Uri 'http://localhost:%PORT%/api/disks' -TimeoutSec 2 -UseBasicParsing;exit 0}catch{exit 1}" >nul 2>&1
if not errorlevel 1 goto OPEN
goto START

:OPEN
rem -- Edge, luego Chrome; si no hay ninguno, el navegador por defecto --
set "BROWSER="
if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set "BROWSER=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not defined BROWSER if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" set "BROWSER=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if not defined BROWSER if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "BROWSER=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined BROWSER if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "BROWSER=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"

if defined BROWSER (
  start "" "%BROWSER%" --app="http://localhost:%PORT%/" --window-size=1440,900
) else (
  start "" "http://localhost:%PORT%/"
)
exit /b 0

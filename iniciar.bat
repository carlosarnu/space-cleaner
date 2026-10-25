@echo off
title Limpiador Inteligente de Espacio
setlocal enabledelayedexpansion
set "APPDIR=%LOCALAPPDATA%\LimpiadorPC"
set "PORT="
if exist "%APPDIR%\port.txt" set /p PORT=<"%APPDIR%\port.txt"
if defined PORT goto CHECK
:START
if exist "%APPDIR%\port.txt" del /q "%APPDIR%\port.txt"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APPDIR%\server.ps1"
for /l %%i in (1,1,50) do (
  if exist "%APPDIR%\port.txt" goto WAIT
  timeout /t 1 /nobreak >nul
)
echo [ERROR] El servidor no arranco.
pause
exit /b 1
:WAIT
for /l %%i in (1,1,50) do (
  if not exist "%APPDIR%\port.txt" goto START
  set /p PORT=<"%APPDIR%\port.txt"
  powershell -NoProfile -Command "try{$null=Invoke-WebRequest -Uri 'http://localhost:!PORT!/api/disks' -TimeoutSec 2 -UseBasicParsing;exit 0}catch{exit 1}" >nul 2>&1
  if not errorlevel 1 goto OPEN
  timeout /t 1 /nobreak >nul
)
goto START
:CHECK
powershell -NoProfile -Command "try{$null=Invoke-WebRequest -Uri 'http://localhost:%PORT%/api/disks' -TimeoutSec 2 -UseBasicParsing;exit 0}catch{exit 1}" >nul 2>&1
if not errorlevel 1 goto OPEN
goto START
:OPEN
start "" "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --app="http://localhost:%PORT%/" --window-size=1440,900 --lang=es
exit /b 0
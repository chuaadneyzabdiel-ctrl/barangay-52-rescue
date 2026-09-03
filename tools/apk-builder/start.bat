@echo off
title Barangay 52 APK Builder
cd /d "%~dp0..\.."

python -c "import socket; s=socket.socket(); s.settimeout(0.4); r=s.connect_ex(('127.0.0.1',8787)); s.close(); raise SystemExit(0 if r==0 else 1)" >nul 2>&1
if %errorlevel%==0 (
  start "" http://127.0.0.1:8787
  echo APK builder is already running at http://127.0.0.1:8787
  pause
  exit /b 0
)

echo Starting APK builder...
start "" cmd /c "timeout /t 2 /nobreak >nul & start http://127.0.0.1:8787"
python -u tools\apk-builder\server.py
if errorlevel 1 pause

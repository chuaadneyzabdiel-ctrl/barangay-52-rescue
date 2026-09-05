@echo off
title Barangay Admin
cd /d "%~dp0..\.."

python -c "import socket; s=socket.socket(); s.settimeout(0.4); r=s.connect_ex(('127.0.0.1',8788)); s.close(); raise SystemExit(0 if r==0 else 1)" >nul 2>&1
if %errorlevel%==0 (
  start "" http://127.0.0.1:8788
  echo Barangay admin is already running at http://127.0.0.1:8788
  pause
  exit /b 0
)

echo Starting barangay admin...
start "" cmd /c "timeout /t 2 /nobreak >nul & start http://127.0.0.1:8788"
python -u tools\barangay-admin\server.py
if errorlevel 1 pause

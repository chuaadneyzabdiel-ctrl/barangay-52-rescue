@echo off
cd /d "%~dp0"
title Responder GPS Joystick - Debug

set "APP_DIR=%~dp0..\..\RESPONDER\responderv3"
if not exist "%APP_DIR%\pubspec.yaml" (
  echo Could not find RESPONDER\responderv3 from tools\responder-gps-joystick.
  echo Expected: %APP_DIR%
  pause
  exit /b 1
)

set "FLUTTER=D:\school\CAPSTONE\src\flutter\bin\flutter.bat"
if not exist "%FLUTTER%" (
  where flutter >nul 2>&1
  if errorlevel 1 (
    echo Flutter was not found.
    echo Expected: D:\school\CAPSTONE\src\flutter\bin\flutter.bat
    pause
    exit /b 1
  )
  set "FLUTTER=flutter"
)

cd /d "%APP_DIR%"

echo Starting Responder GPS Joystick (debug only^)...
echo Spoof stays OFF until you enable it in the tool.
echo App folder: %CD%
echo Close this window or press Q in it to stop the app.
echo.

"%FLUTTER%" run -d chrome --dart-define=OPEN_GPS_JOYSTICK=true
if errorlevel 1 pause

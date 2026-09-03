@echo off
cd /d "%~dp0"
title LGU Command Center - Chrome

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

echo Starting LGU Command Center in Chrome...
echo Close this window or press Q in it to stop the app.
echo.

"%FLUTTER%" run -d chrome
if errorlevel 1 pause

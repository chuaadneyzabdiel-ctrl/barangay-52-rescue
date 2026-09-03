@echo off
REM Run "flutter build web --release" first, then double-click this file.
REM Requires Python 3 on PATH (python -m http.server).
REM Edit Chrome path below if installed elsewhere. Edge alternative:
REM   "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --app=http://localhost:8765/ --start-fullscreen

setlocal
set "ROOT=%~dp0"
set "WEB=%ROOT%build\web"
set PORT=8765

if not exist "%WEB%\index.html" (
  echo Missing build\web\index.html — run: flutter build web --release
  pause
  exit /b 1
)

start "rescue-web-server" /MIN /D "%WEB%" python -m http.server %PORT%

timeout /t 2 /nobreak >nul

start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" --app=http://localhost:%PORT%/ --start-fullscreen

endlocal

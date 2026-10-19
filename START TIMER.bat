@echo off
REM Always open in a real console window, not a Windows Terminal tab.
if /I "%~1"=="--inner" goto :inner
start "MC Restart Timer" "%SystemRoot%\System32\conhost.exe" cmd.exe /k "%~f0" --inner
exit /b 0

:inner
chcp 65001 >nul
cd /d "%~dp0"
title MC Restart Timer
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0mc-restart-timer.ps1"
echo.
pause
exit

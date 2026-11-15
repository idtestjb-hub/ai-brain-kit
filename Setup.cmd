@echo off
rem Double-click to set up or manage the shared AI brain on this Windows PC.
setlocal
set "KITDIR=%~dp0"
rem Respect an organisation's script policy: never try to get around it.
powershell -NoProfile -Command "if ((Get-ExecutionPolicy -Scope MachinePolicy) -ne 'Undefined' -or (Get-ExecutionPolicy -Scope UserPolicy) -ne 'Undefined') { exit 3 }"
if errorlevel 3 (
  echo.
  echo Your organisation controls which PowerShell scripts may run on this PC.
  echo This kit will not try to get around that: ask your IT team to approve or sign it.
  echo.
  pause
  exit /b 3
)
rem Files downloaded from the internet are blocked until unblocked once.
powershell -NoProfile -Command "Get-ChildItem -LiteralPath $env:KITDIR -Recurse -File | Unblock-File"
powershell -NoProfile -ExecutionPolicy Bypass -File "%KITDIR%tools\setup.ps1"
echo.
pause

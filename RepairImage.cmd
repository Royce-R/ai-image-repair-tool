@echo off
setlocal

cd /d "%~dp0"

set "INPUT=%~1"
if "%INPUT%"=="" (
  set "INPUT=.\resource"
)

echo AI Image Repair Tool
echo Input: %INPUT%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ImageRepairTool.ps1" -Input "%INPUT%" -Open
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo Failed with exit code %EXIT_CODE%.
  echo Check the messages above, or run:
  echo   powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ImageRepairTool.ps1" -Help
  pause
)

exit /b %EXIT_CODE%

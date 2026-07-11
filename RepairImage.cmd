@echo off
setlocal EnableExtensions

cd /d "%~dp0"

set "SCRIPT=%~dp0ImageRepairTool.ps1"
set "INTERACTIVE=0"

if not "%~1"=="" (
  set "INPUT=%~1"
  goto RUN_OPEN
)

:MENU
set "INTERACTIVE=1"
cls
echo AI Image Repair Tool
echo.
echo 1. Process default resource folder
echo 2. Enter image or folder path
echo 3. Check environment
echo 4. Show help
echo Q. Quit
echo.
choice /C 1234Q /N /M "Choose: "
if errorlevel 5 exit /b 0
if errorlevel 4 goto SHOW_HELP
if errorlevel 3 goto RUN_CHECK
if errorlevel 2 goto ASK_PATH
if errorlevel 1 (
  set "INPUT=.\resource"
  goto RUN_OPEN
)

:ASK_PATH
set "INPUT="
set /P "INPUT=Drop/paste image or folder path, then press Enter: "
if "%INPUT%"=="" goto MENU
set "INPUT=%INPUT:"=%"
goto RUN_OPEN

:RUN_OPEN
echo.
echo Input: %INPUT%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Input "%INPUT%" -Open
set "EXIT_CODE=%ERRORLEVEL%"
goto HANDLE_RESULT

:RUN_CHECK
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Check
set "EXIT_CODE=%ERRORLEVEL%"
if "%INTERACTIVE%"=="1" (
  echo.
  pause
  goto MENU
)
exit /b %EXIT_CODE%

:SHOW_HELP
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Help
echo.
pause
goto MENU

:HANDLE_RESULT
echo.
if not "%EXIT_CODE%"=="0" (
  echo Failed with exit code %EXIT_CODE%.
  echo Check the messages above, or run:
  echo   powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Help
  echo.
  pause
)

if "%INTERACTIVE%"=="1" (
  echo Done.
  echo.
  pause
)

exit /b %EXIT_CODE%

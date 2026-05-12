@echo off
setlocal
call "%~dp0config.bat"

if "%REMOTE_USER%"=="" (
    set "TARGET=%REMOTE_HOST%"
) else (
    set "TARGET=%REMOTE_USER%@%REMOTE_HOST%"
)

set "P_ARG="
if not "%REMOTE_PORT%"=="" set "P_ARG=-p %REMOTE_PORT%"

echo Aborting remote encode on %REMOTE_HOST%...
ssh %P_ARG% %TARGET% "sudo /srv/ffmpeg-automation/abort.sh"

echo.
pause

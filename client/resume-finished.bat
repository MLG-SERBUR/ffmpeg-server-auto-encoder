@echo off
setlocal
cd /d "%~dp0"
if not exist "config.bat" (
    echo ERROR: config.bat not found.
    pause
    exit /b
)
call "config.bat"
powershell.exe -ExecutionPolicy Bypass -File "client-resume.ps1" -RemoteHost "%REMOTE_HOST%"
pause

@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

REM =========================================================
REM CONFIGURATION
REM =========================================================
if not exist "%~dp0config.bat" (
    echo ERROR: config.bat not found. Please create it.
    pause
    exit /b
)
call "%~dp0config.bat"
REM =========================================================

title Remote FFmpeg Encoder (Parallel SSH)

if "%~1" == "" (
    echo.
    echo Usage: Drag and drop files onto this script to encode them remotely.
    echo.
    pause
    exit /b
)

if defined VIDEO_ENCODER (
    set "SELECTED_PRESET_NAME=Dynamic"
    goto loop
)

if defined SELECTED_PRESET_FILE (
    for %%F in ("%SELECTED_PRESET_FILE%") do (
        set "SELECTED_PRESET_NAME=%%~nF"
        if /i "%%~xF" == ".bat" (
            call "%%~F" %*
            exit /b
        )
    )
    goto loop
)

echo.
echo =========================================================
echo SELECT PRESET
echo =========================================================
set count=0
for %%f in ("%~dp0presets\*.bat") do (
    set /a count+=1
    set "preset_name[!count!]=%%~nf"
    set "preset_file[!count!]=%%~f"
    echo [!count!] %%~nf
)

if %count% equ 0 (
    echo ERROR: No presets found in %~dp0presets
    pause
    exit /b
)

if %count% equ 1 (
    set "choice=1"
    echo Auto-selecting only available preset: !preset_name[1]!
) else (
    set /p choice="Select preset [1-%count%]: "
)

set "SELECTED_PRESET_NAME=!preset_name[%choice%]!"
set "SELECTED_PRESET_FILE=!preset_file[%choice%]!"

if "!SELECTED_PRESET_FILE!" == "" (
    echo Invalid choice.
    pause
    exit /b
)

REM Execute the batch preset to set environment variables
call "!SELECTED_PRESET_FILE!" %*
exit /b

:loop
if "%~1" == "" goto end

echo.
echo =========================================================
echo Processing: "%~nx1"
echo Preset: %SELECTED_PRESET_NAME%
echo =========================================================

powershell.exe -ExecutionPolicy Bypass -File "%~dp0client-sync.ps1" -LocalFile "%~1" -RemoteHost "%REMOTE_HOST%"

if %errorlevel% neq 0 (
    color 0c
    echo.
    echo #########################################################
    echo ERROR: Failed to process "%~nx1"
    echo #########################################################
    pause
    color 07
    exit /b %errorlevel%
) else (
    echo.
    echo [SUCCESS] "%~nx1" finished.
)

shift
goto loop

:end
echo.
echo =========================================================
echo All files processed sequentially.
echo =========================================================
pause
exit /b

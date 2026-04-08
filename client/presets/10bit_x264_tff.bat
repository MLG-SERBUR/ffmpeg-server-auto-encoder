@echo off
set "SELECTED_PRESET_FILE=%~dp010bit_x264_tff.ps1"
call "%~dp0..\remote-encode.bat" %*

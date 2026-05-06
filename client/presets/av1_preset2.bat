@echo off
set "VIDEO_ENCODER=-c:v libsvtav1 -preset 2 -crf 38"
set "AUDIO_ENCODER=-c:a libopus -b:a 96k -vbr on"
set "OUTPUT_SUFFIX=-av1"
set "FINAL_EXT=.mp4"
set "MOV_FLAGS=-movflags +faststart"

call "%~dp0..\remote-encode.bat" %*

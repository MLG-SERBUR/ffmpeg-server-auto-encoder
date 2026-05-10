@echo off
REM AV1 preset for repairing VFR game captures (Game DVR broken timestamps)
REM -fflags +genpts regenerates PTS, -fps_mode passthrough preserves VFR
set "INPUT_OPTIONS=-fflags +genpts"
set "VIDEO_ENCODER=-c:v libsvtav1 -preset 2 -crf 38 -fps_mode passthrough"
set "AUDIO_ENCODER=-c:a libopus -b:a 96k -vbr on"
set "OUTPUT_SUFFIX=-av1"
set "FINAL_EXT=.mp4"
set "MOV_FLAGS=-movflags +faststart"

call "%~dp0..\remote-encode.bat" %*

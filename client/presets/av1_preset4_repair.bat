@echo off
REM AV1 preset for preserving VFR game captures
REM -copyts and related flags ensure exact timestamp preservation
set "INPUT_OPTIONS="
set "VIDEO_ENCODER=-c:v libsvtav1 -preset 4 -crf 40 -copyts -copytb 1 -enc_time_base demux -fps_mode passthrough -video_track_timescale 90000"
set "AUDIO_ENCODER=-c:a libopus -b:a 96k -vbr on"
set "OUTPUT_SUFFIX=-av1"
set "FINAL_EXT=.mp4"
set "MOV_FLAGS=-movflags +faststart"

call "%~dp0..\remote-encode.bat" %*

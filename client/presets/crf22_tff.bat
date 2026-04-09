@echo off
set "VIDEO_ENCODER=-c:v libx264 -crf 22 -preset veryslow -tune film -flags +ilme+ildct -x264-params open-gop=1:tff=1 -vf setfield=tff -pix_fmt yuv422p10le -profile:v high422"
set "AUDIO_ENCODER=-c:a libopus -b:a 96k -vbr on"
set "OUTPUT_SUFFIX=-10bit-crf22"
set "FINAL_EXT=.mp4"
set "MOV_FLAGS=-movflags +faststart"

call "%~dp0..\remote-encode.bat" %*

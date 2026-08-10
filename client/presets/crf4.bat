@echo off
REM CRF 4 interlaced mezzanine/archival preset
REM -g 1: all-intra for maximum fidelity and editability
REM -pix_fmt yuv422p: 4:2:2 chroma subsampling
REM -flags +ildct+ilme -top 1: interlaced flags (TFF)
set "VIDEO_ENCODER=-c:v libx264 -preset veryslow -crf 4 -g 1 -x264-params aq-mode=2:no-fast-pskip=1:no-dct-decimate=1 -pix_fmt yuv422p -flags +ildct+ilme -top 1"
set "AUDIO_ENCODER=-c:a libopus -b:a 96k -vbr on"
set "OUTPUT_SUFFIX=-crf4"
set "FINAL_EXT=.mp4"
set "MOV_FLAGS=-movflags +faststart"

call "%~dp0..\remote-encode.bat" %*

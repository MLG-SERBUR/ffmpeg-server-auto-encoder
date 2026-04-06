#!/usr/bin/env bash
# Preset: 20crf x264 TFF 4:2:2 10-bit
VIDEO_ENCODER="-c:v libx264 -crf 20 -preset veryslow -tune film -flags +ilme+ildct -x264-params open-gop=1:tff=1 -vf setfield=tff -pix_fmt yuv422p10le -profile:v high422"
AUDIO_ENCODER="-c:a libopus -b:a 96k"
OUTPUT_SUFFIX="-10bit"
FINAL_EXT=".mp4"
MOV_FLAGS="-movflags +faststart"

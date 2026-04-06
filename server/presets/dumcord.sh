#!/usr/bin/env bash
# Preset: Dumcord-like delivery (single-pass conservative settings)
VIDEO_ENCODER="-c:v libx264 -crf 23 -preset medium -tune film"
AUDIO_ENCODER="-c:a aac -b:a 96k"
OUTPUT_SUFFIX="-dumcord"
FINAL_EXT=".mp4"
MOV_FLAGS="-movflags +faststart"

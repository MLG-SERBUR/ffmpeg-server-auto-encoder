#!/usr/bin/env bash
set -euo pipefail

# delivery.sh - portable POSIX port of delivery.cmd
# Usage: delivery.sh <input-file>
# Environment variables:
#   VIDEO_ENCODER - full ffmpeg video options (including -c:v ...). Default: -c:v libx264 -crf 22 -preset veryslow -tune film
#   AUDIO_ENCODER - full ffmpeg audio options (including -c:a ...). Default: -c:a aac -b:a 192k
#   OUTPUT_SUFFIX - suffix appended to basename (default "-encoded")
#   FINAL_EXT - extension including leading dot (default ".mp4")
#   OUTPUT_DIR - output dir (default ./finished)
#   MOV_FLAGS - extra ffmpeg flags such as "-movflags +faststart"
#   INPUT_OPTIONS - extra global input options (default empty)

if [ $# -lt 1 ]; then
  echo "Usage: $0 <input-file>"
  exit 2
fi

INPUT="$1"

if [ ! -f "$INPUT" ]; then
  echo "Input file not found: $INPUT"
  exit 2
fi

# defaults
VIDEO_ENCODER_DEFAULT="-c:v libx264 -crf 22 -preset veryslow -tune film"
AUDIO_ENCODER_DEFAULT="-c:a aac -b:a 192k"
OUTPUT_SUFFIX_DEFAULT="-encoded"
FINAL_EXT_DEFAULT=".mp4"
OUTPUT_DIR_DEFAULT="./finished"
MOV_FLAGS_DEFAULT="-movflags +faststart"
INPUT_OPTIONS_DEFAULT=""

VIDEO_ENCODER="${VIDEO_ENCODER:-$VIDEO_ENCODER_DEFAULT}"
AUDIO_ENCODER="${AUDIO_ENCODER:-$AUDIO_ENCODER_DEFAULT}"
OUTPUT_SUFFIX="${OUTPUT_SUFFIX:-$OUTPUT_SUFFIX_DEFAULT}"
FINAL_EXT="${FINAL_EXT:-$FINAL_EXT_DEFAULT}"
OUTPUT_DIR="${OUTPUT_DIR:-$OUTPUT_DIR_DEFAULT}"
MOV_FLAGS="${MOV_FLAGS:-$MOV_FLAGS_DEFAULT}"
INPUT_OPTIONS="${INPUT_OPTIONS:-$INPUT_OPTIONS_DEFAULT}"

mkdir -p "$OUTPUT_DIR"

BASENAME=$(basename "$INPUT")
NAME="${BASENAME%.*}"
OUTPUT_PATH="$OUTPUT_DIR/${NAME}${OUTPUT_SUFFIX}${FINAL_EXT}"

echo "[$(date -Is)] delivery.sh starting"
echo "Input: $INPUT"
echo "Output: $OUTPUT_PATH"
echo "VIDEO_ENCODER: $VIDEO_ENCODER"
echo "AUDIO_ENCODER: $AUDIO_ENCODER"
echo "MOV_FLAGS: $MOV_FLAGS"

# Split option strings into arrays to avoid word-splitting pitfalls
read -r -a INPUT_ARR <<< "$INPUT_OPTIONS"
read -r -a VIDEO_ARR <<< "$VIDEO_ENCODER"
read -r -a AUDIO_ARR <<< "$AUDIO_ENCODER"
read -r -a MOV_ARR <<< "$MOV_FLAGS"

# Build ffmpeg command as an array
CMD=(ffmpeg -hide_banner -y)
if [ ${#INPUT_ARR[@]} -gt 0 ]; then
  CMD+=("${INPUT_ARR[@]}")
fi
CMD+=(-i "$INPUT" -map_metadata 0)
if [ ${#VIDEO_ARR[@]} -gt 0 ]; then
  CMD+=("${VIDEO_ARR[@]}")
fi
if [ ${#AUDIO_ARR[@]} -gt 0 ]; then
  CMD+=("${AUDIO_ARR[@]}")
fi
if [ ${#MOV_ARR[@]} -gt 0 ]; then
  CMD+=("${MOV_ARR[@]}")
fi
CMD+=("$OUTPUT_PATH")

# print command for debugging
echo "Running: ${CMD[*]}"

# Run command
"${CMD[@]}"
EXIT=$?

if [ $EXIT -eq 0 ]; then
  echo "Encode succeeded: $OUTPUT_PATH"
else
  echo "Encode failed (exit $EXIT)"
fi

exit $EXIT

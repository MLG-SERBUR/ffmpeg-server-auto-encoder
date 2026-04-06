#!/usr/bin/env bash
set -euo pipefail

# worker.sh - simple single-worker ffmpeg job processor
# It watches $BASE_DIR/incoming for new files and processes them one at a time.
# Configuration via environment variables:
#   FFMPEG_AUTO_ROOT - root path for incoming/processing/finished/failed/logs (default: ./data)
#   DEFAULT_PRESET - preset name (file in ./presets) to use if none supplied (default: 20crf_x264_tff_422_10bit)
#   MIN_FREE_BYTES - minimum free bytes required to start a job (default: 1073741824 == 1GiB)
#   KEEP_INPUT_ON_SUCCESS - if "true", move input to archive instead of deleting (default: "false")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${FFMPEG_AUTO_ROOT:-$SCRIPT_DIR/data}"
INCOMING="$BASE_DIR/incoming"
PROCESSING="$BASE_DIR/processing"
FINISHED="$BASE_DIR/finished"
FAILED="$BASE_DIR/failed"
LOGS="$BASE_DIR/logs"
PRESETS_DIR="$SCRIPT_DIR/presets"
ARCHIVE="$BASE_DIR/archive"

DEFAULT_PRESET="${DEFAULT_PRESET:-20crf_x264_tff_422_10bit}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-1073741824}"
KEEP_INPUT_ON_SUCCESS="${KEEP_INPUT_ON_SUCCESS:-false}"

mkdir -p "$INCOMING" "$PROCESSING" "$FINISHED" "$FAILED" "$LOGS" "$PRESETS_DIR" "$ARCHIVE"

log() {
  echo "[$(date -Is)] $*"
}

check_disk() {
  # returns 0 when ok
  avail_bytes=$(df -P "$BASE_DIR" | awk 'NR==2 {print $4 * 1024}')
  if [ -z "$avail_bytes" ]; then
    # fallback: assume ok
    return 0
  fi
  if [ "$avail_bytes" -lt "$MIN_FREE_BYTES" ]; then
    log "Insufficient free space ($avail_bytes bytes < $MIN_FREE_BYTES). Sleeping."
    return 1
  fi
  return 0
}

process_job() {
  local input_path="$1"
  local filename="$(basename "$input_path")"
  local name="${filename%.*}"
  local logfile="$LOGS/${name}_$(date +%Y%m%dT%H%M%S).log"

  log "Processing $input_path -> logfile $logfile"
  # Move any preset file alongside the input from incoming to processing
  if [ -f "$INCOMING/${name}.preset" ]; then
    mv "$INCOMING/${name}.preset" "$PROCESSING/${name}.preset" || true
  fi

  # Determine preset
  preset_name="$DEFAULT_PRESET"
  if [ -f "$PROCESSING/${name}.preset" ]; then
    preset_name="$(cat "$PROCESSING/${name}.preset" | tr -d '\r\n')"
    log "Found preset file: $preset_name"
  else
    log "No preset provided; using default preset: $preset_name"
  fi

  # Source preset if available
  if [ -f "$PRESETS_DIR/${preset_name}.sh" ]; then
    # reset variables to defaults
    unset VIDEO_ENCODER AUDIO_ENCODER OUTPUT_SUFFIX FINAL_EXT MOV_FLAGS INPUT_OPTIONS || true
    # shellcheck source=/dev/null
    source "$PRESETS_DIR/${preset_name}.sh"
    log "Loaded preset $preset_name"
  else
    log "Preset file not found: $PRESETS_DIR/${preset_name}.sh"
    # fall back to built-in defaults - delivery.sh will handle defaults too
  fi

  # Ensure OUTPUT_SUFFIX and FINAL_EXT have defaults
  OUTPUT_SUFFIX="${OUTPUT_SUFFIX:--encoded}"
  FINAL_EXT="${FINAL_EXT:-.mp4}"

  # Ensure output dir is the FINISHED dir
  export OUTPUT_DIR="$FINISHED"

  # Run delivery.sh
  "$SCRIPT_DIR/delivery.sh" "$PROCESSING/$filename" > "$logfile" 2>&1
  ret=$?

  if [ $ret -eq 0 ]; then
    # Expecting output file at FINISHED/name+OUTPUT_SUFFIX+FINAL_EXT
    expected_output="$FINISHED/${name}${OUTPUT_SUFFIX}${FINAL_EXT}"
    if [ ! -f "$expected_output" ]; then
      # try to find any file that starts with name
      match=$(find "$FINISHED" -maxdepth 1 -type f -iname "${name}*" | head -n 1 || true)
      if [ -n "$match" ]; then
        expected_output="$match"
      fi
    fi

    if [ -f "$expected_output" ]; then
      sha=$(sha256sum "$expected_output" | awk '{print $1}')
      echo "{\"output\":\"$(basename "$expected_output")\",\"sha256\":\"$sha\"}" > "$FINISHED/${name}.done"
      log "Job succeeded: output=$(basename "$expected_output") sha256=$sha"
      if [ "$KEEP_INPUT_ON_SUCCESS" = "true" ]; then
        mkdir -p "$ARCHIVE"
        mv "$PROCESSING/$filename" "$ARCHIVE/" || true
      else
        rm -f "$PROCESSING/$filename" || true
      fi
    else
      log "Encode reported success but no output file found for $name"
      mv "$PROCESSING/$filename" "$FAILED/" || true
      echo "{\"error\":\"no-output\"}" > "$FAILED/${name}.failed"
    fi
  else
    log "Job failed (exit $ret). Moving to failed/"
    mv "$PROCESSING/$filename" "$FAILED/" || true
    echo "{\"exit\":$ret}" > "$FAILED/${name}.failed"
  fi
}

log "ffmpeg-worker started (base dir: $BASE_DIR). Default preset: $DEFAULT_PRESET"

while true; do
  # check disk
  if ! check_disk; then
    sleep 10
    continue
  fi

  jobfile=""
  for f in "$INCOMING"/*; do
    [ -e "$f" ] || continue
    # skip partials and hidden files and preset metadata files
    bn=$(basename "$f")
    case "$bn" in
      *.partial|.*|*.preset) continue ;;
    esac
    [ -f "$f" ] || continue
    # try to atomically move to processing
    if mv "$f" "$PROCESSING/"; then
      jobfile="$PROCESSING/$(basename "$f")"
      break
    fi
  done

  if [ -z "${jobfile-}" ]; then
    sleep 3
    continue
  fi

  process_job "$jobfile"
done

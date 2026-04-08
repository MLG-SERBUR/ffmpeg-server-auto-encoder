#!/usr/bin/env bash
set -euo pipefail

# FFmpeg Automation - Server Installation Script
# This script sets up the directory structure and creates the necessary scripts.

TARGET_DIR="/srv/ffmpeg-automation"
USER_NAME="ffmpeg"

echo "=== FFmpeg Server Auto-Encoder Setup ==="

# 1. Create directory structure
sudo mkdir -p "$TARGET_DIR"/{incoming,processing,finished,failed,logs,presets,archive}

# 2. Create worker.sh
cat << 'EOF_WORKER' | sudo tee "$TARGET_DIR/worker.sh" > /dev/null
#!/usr/bin/env bash
set -euo pipefail

# worker.sh - simple single-worker ffmpeg job processor
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${FFMPEG_AUTO_ROOT:-$SCRIPT_DIR}"
INCOMING="$BASE_DIR/incoming"
PROCESSING="$BASE_DIR/processing"
FINISHED="$BASE_DIR/finished"
FAILED="$BASE_DIR/failed"
LOGS="$BASE_DIR/logs"
PRESETS_DIR="$SCRIPT_DIR/presets"
ARCHIVE="$BASE_DIR/archive"

DEFAULT_PRESET="${DEFAULT_PRESET:-default}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-1073741824}"
KEEP_INPUT_ON_SUCCESS="${KEEP_INPUT_ON_SUCCESS:-false}"

log() { echo "[$(date -Is)] $*"; }

check_disk() {
  avail_bytes=$(df -P "$BASE_DIR" | awk 'NR==2 {print $4 * 1024}')
  if [ "${avail_bytes:-0}" -lt "$MIN_FREE_BYTES" ]; then
    log "Insufficient free space. Sleeping."
    return 1
  fi
  return 0
}

process_job() {
  local input_path="$1"
  local filename="$(basename "$input_path")"
  local name="${filename%.*}"
  local logfile="$LOGS/${name}_$(date +%Y%m%dT%H%M%S).log"

  log "Processing $input_path"
  
  if [ -f "$INCOMING/${name}.preset" ]; then
    mv "$INCOMING/${name}.preset" "$PROCESSING/${name}.preset" || true
  fi

  # Reset variables
  unset VIDEO_ENCODER AUDIO_ENCODER OUTPUT_SUFFIX FINAL_EXT MOV_FLAGS INPUT_OPTIONS || true

  # Determine preset
  if [ -f "$PROCESSING/${name}.preset" ]; then
    if grep -q "=" "$PROCESSING/${name}.preset"; then
      log "Found dynamic parameters; sourcing."
      source "$PROCESSING/${name}.preset"
    else
      preset_name="$(cat "$PROCESSING/${name}.preset" | tr -d '\r\n')"
      [ -f "$PRESETS_DIR/${preset_name}.sh" ] && source "$PRESETS_DIR/${preset_name}.sh"
    fi
  else
    [ -f "$PRESETS_DIR/${DEFAULT_PRESET}.sh" ] && source "$PRESETS_DIR/${DEFAULT_PRESET}.sh"
  fi

  export OUTPUT_DIR="$FINISHED"
  "$SCRIPT_DIR/delivery.sh" "$PROCESSING/$filename" > "$logfile" 2>&1
  ret=$?

  if [ $ret -eq 0 ]; then
    expected_output=$(find "$FINISHED" -maxdepth 1 -type f -iname "${name}*" | head -n 1)
    if [ -n "$expected_output" ]; then
      sha=$(sha256sum "$expected_output" | awk '{print $1}')
      echo "{\"output\":\"$(basename "$expected_output")\",\"sha256\":\"$sha\"}" > "$FINISHED/${name}.done"
      log "Job succeeded."
      if [ "$KEEP_INPUT_ON_SUCCESS" = "true" ]; then
        mv "$PROCESSING/$filename" "$ARCHIVE/"
      else
        rm -f "$PROCESSING/$filename"
      fi
    fi
  else
    log "Job failed (exit $ret)."
    mv "$PROCESSING/$filename" "$FAILED/"
    echo "{\"error\":$ret}" > "$FAILED/${name}.failed"
  fi
  rm -f "$PROCESSING/${name}.preset" || true
}

log "ffmpeg-worker started (target: $BASE_DIR)"
while true; do
  check_disk || { sleep 10; continue; }
  jobfile=""
  for f in "$INCOMING"/*; do
    [ -e "$f" ] || continue
    bn=$(basename "$f")
    [[ "$bn" =~ \.(partial|preset)$ ]] && continue
    if mv "$f" "$PROCESSING/"; then
      jobfile="$PROCESSING/$(basename "$f")"
      break
    fi
  done
  if [ -z "$jobfile" ]; then sleep 3; continue; fi
  process_job "$jobfile"
done
EOF_WORKER

# 3. Create delivery.sh
cat << 'EOF_DELIVERY' | sudo tee "$TARGET_DIR/delivery.sh" > /dev/null
#!/usr/bin/env bash
set -euo pipefail
INPUT="$1"
# defaults
VIDEO_ENCODER="${VIDEO_ENCODER:--c:v libx264 -crf 22 -preset veryslow -tune film}"
AUDIO_ENCODER="${AUDIO_ENCODER:--c:a libopus -b:a 96k}"
OUTPUT_SUFFIX="${OUTPUT_SUFFIX:--encoded}"
FINAL_EXT="${FINAL_EXT:-.mp4}"
OUTPUT_DIR="${OUTPUT_DIR:-./finished}"
MOV_FLAGS="${MOV_FLAGS:--movflags +faststart}"

OUTPUT_PATH="$OUTPUT_DIR/$(basename "${INPUT%.*}")${OUTPUT_SUFFIX}${FINAL_EXT}"

echo "Running FFmpeg..."
ffmpeg -hide_banner -y -i "$INPUT" -map_metadata 0 \
  $VIDEO_ENCODER $AUDIO_ENCODER $MOV_FLAGS "$OUTPUT_PATH"
EOF_DELIVERY

# 4. Create default preset
cat << 'EOF_PRESET' | sudo tee "$TARGET_DIR/presets/default.sh" > /dev/null
VIDEO_ENCODER="-c:v libx264 -crf 22 -preset veryslow -tune film"
AUDIO_ENCODER="-c:a libopus -b:a 96k"
OUTPUT_SUFFIX="-encoded"
FINAL_EXT=".mp4"
MOV_FLAGS="-movflags +faststart"
EOF_PRESET

# 5. Permissions
sudo chmod +x "$TARGET_DIR"/*.sh
if ! id "$USER_NAME" >/dev/null 2>&1; then
    sudo useradd -r -s /usr/sbin/nologin "$USER_NAME" || true
fi
sudo chown -R "$USER_NAME":"$USER_NAME" "$TARGET_DIR"

# 6. Systemd Service
cat << EOF_SERVICE | sudo tee /etc/systemd/system/ffmpeg-worker.service > /dev/null
[Unit]
Description=FFmpeg Automation Worker
After=network.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$TARGET_DIR
ExecStart=/usr/bin/bash $TARGET_DIR/worker.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

sudo systemctl daemon-reload
echo "DONE! Setup complete in $TARGET_DIR"
echo "To start the service: sudo systemctl enable --now ffmpeg-worker"
echo "To view logs: journalctl -u ffmpeg-worker -f"

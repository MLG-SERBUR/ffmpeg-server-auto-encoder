# FFmpeg Automation - Server Setup

This server handles single-worker sequential FFmpeg processing. It accepts video files and configuration "presets" from the client, encodes them, and provides a completion manifest.

## Installation (Interactive Copy-Paste)

If your server has no external internet access (IPv6 only or restricted), copy the entire block below and paste it into your SSH terminal:

```bash
cat << 'EOF' > install.sh
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

# Robust logging
log() {
  local timestamp
  timestamp=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date || echo "unknown")
  echo "[$timestamp] $*"
}

# Error trap
failure() {
  local lineno=$1
  log "CRITICAL: Script failed at line $lineno. Exiting."
}
trap 'failure $LINENO' ERR

check_disk() {
  local avail_bytes
  # df -P is POSIX standard format
  avail_bytes=$(df -P "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')
  if [ -z "$avail_bytes" ]; then
    log "Warning: Could not determine disk space. Assuming enough."
    return 0
  fi
  
  if [ "$avail_bytes" -lt "$MIN_FREE_BYTES" ]; then
    log "Insufficient free space ($((avail_bytes / 1024 / 1024)) MB available). Sleeping."
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
  
  # Move preset if it exists
  if [ -f "$INCOMING/${name}.preset" ]; then
    mv "$INCOMING/${name}.preset" "$PROCESSING/${name}.preset" || true
  fi

  # Reset variables to ensure clean slate for each job
  unset VIDEO_ENCODER AUDIO_ENCODER OUTPUT_SUFFIX FINAL_EXT MOV_FLAGS INPUT_OPTIONS || true

  # Determine preset
  if [ -f "$PROCESSING/${name}.preset" ]; then
    if grep -q "=" "$PROCESSING/${name}.preset"; then
      log "Found dynamic parameters; sourcing."
      # Source in a subshell or check for errors
      if ! source "$PROCESSING/${name}.preset"; then
         log "Error: Failed to source dynamic preset. Using defaults."
      fi
    else
      local preset_name
      preset_name=$(cat "$PROCESSING/${name}.preset" | tr -d '\r\n')
      if [ -f "$PRESETS_DIR/${preset_name}.sh" ]; then
        source "$PRESETS_DIR/${preset_name}.sh"
      else
        log "Preset '$preset_name' not found."
      fi
    fi
  else
    if [ -f "$PRESETS_DIR/${DEFAULT_PRESET}.sh" ]; then
      source "$PRESETS_DIR/${DEFAULT_PRESET}.sh"
    fi
  fi

  export OUTPUT_DIR="$FINISHED"
  
  if [ ! -x "$SCRIPT_DIR/delivery.sh" ]; then
    log "Error: delivery.sh not found or not executable!"
    mv "$PROCESSING/$filename" "$FAILED/"
    return 1
  fi

  log "Starting delivery script for $filename..."
  "$SCRIPT_DIR/delivery.sh" "$PROCESSING/$filename" > "$logfile" 2>&1
  local ret=$?

  if [ $ret -eq 0 ]; then
    local expected_output
    expected_output=$(find "$FINISHED" -maxdepth 1 -type f -iname "${name}*" | head -n 1)
    if [ -n "$expected_output" ]; then
      local sha
      sha=$(sha256sum "$expected_output" | awk '{print $1}')
      echo "{\"output\":\"$(basename "$expected_output")\",\"sha256\":\"$sha\"}" > "$FINISHED/${name}.done"
      log "Job succeeded: $(basename "$expected_output")"
      if [ "$KEEP_INPUT_ON_SUCCESS" = "true" ]; then
        mv "$PROCESSING/$filename" "$ARCHIVE/"
      else
        rm -f "$PROCESSING/$filename"
      fi
    else
      log "Error: FFmpeg finished but output file not found."
      mv "$PROCESSING/$filename" "$FAILED/"
    fi
  else
    log "Job failed (exit $ret). Check logs: $logfile"
    mv "$PROCESSING/$filename" "$FAILED/"
    echo "{\"error\":$ret}" > "$FAILED/${name}.failed"
  fi
  rm -f "$PROCESSING/${name}.preset" || true
}

log "ffmpeg-worker starting (target: $BASE_DIR)"
if ! command -v ffmpeg >/dev/null 2>&1; then
  log "CRITICAL: ffmpeg command not found in PATH!"
fi

poll_count=0
while true; do
  check_disk || { sleep 10; continue; }
  
  jobfile=""
  # Use nullglob to avoid literal '*' if no files
  shopt -s nullglob
  for f in "$INCOMING"/*; do
    bn=$(basename "$f")
    [[ "$bn" =~ \.(partial|preset)$ ]] && continue
    
    log "Detected file: $bn. Attempting to claim..."
    if mv "$f" "$PROCESSING/"; then
      jobfile="$PROCESSING/$bn"
      break
    else
      log "Warning: Failed to move $bn (permissions? or already claimed?)"
    fi
  done
  shopt -u nullglob

  if [ -z "$jobfile" ]; then
    ((poll_count++))
    if [ $((poll_count % 100)) -eq 0 ]; then
      log "Heartbeat: Polling $INCOMING (attempt $poll_count)..."
    fi
    sleep 3
    continue
  fi
  
  poll_count=0 # Reset on job
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
EOF
chmod +x install.sh
./install.sh
```

> [!TIP]
> Since you are viewing this in your editor, you can just select the full content of `server/install.sh`, paste it into the block above, and run it. The script will handle directory creation, permissions, and systemd setup for you.

## How it Works

1. **Incoming**: Files arrive in `incoming/`.
2. **Presets**: The server checks for a `.preset` file alongside the video. 
   - **Dynamic**: If it contains FFmpeg flags (sent by new clients), it uses them immediately.
   - **Named**: If it contains a name, it looks in `presets/`.
3. **Sequential Processing**: Jobs are processed one-at-a-time to save disk space.
4. **Completion**: A `.done` file is created in `finished/` containing the file hash and output metadata.

## FAQs

### Are the presets in the server folder necessary?
**No.** With the new dynamic preset system, the client sends all necessary flags to the server at runtime. The `presets/` folder on the server is now only used as a fallback or for "legacy" named presets.

### Manual Operation
The service runs under `ffmpeg-worker.service`.
- **Start**: `sudo systemctl start ffmpeg-worker`
- **Logs**: `journalctl -u ffmpeg-worker -f`

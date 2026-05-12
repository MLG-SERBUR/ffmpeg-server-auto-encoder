#!/usr/bin/env bash
# abort.sh - Abort current encoding job and stop the worker service

TARGET_DIR="/srv/ffmpeg-automation"
PROCESSING="$TARGET_DIR/processing"
FAILED="$TARGET_DIR/failed"

echo "Aborting current FFmpeg process..."
# Kill ffmpeg first to stop the active encode immediately
sudo pkill -9 ffmpeg || echo "No ffmpeg process found."

echo "Stopping ffmpeg-worker service..."
sudo systemctl stop ffmpeg-worker

echo "Cleaning up processing directory..."
# Move any files from processing to failed so they don't restart automatically
if [ -d "$PROCESSING" ]; then
    for f in "$PROCESSING"/*; do
        if [ -e "$f" ]; then
            echo "Moving $(basename "$f") to failed/"
            sudo mv "$f" "$FAILED/"
        fi
    done
fi

echo "Done. Encode aborted and service stopped."
echo "To resume other jobs: sudo systemctl start ffmpeg-worker"

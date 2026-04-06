# FFmpeg Automation - Server

This folder contains a small single-worker implementation for processing incoming uploads and producing encoded outputs.

Quick start (on a Linux server):

1. Copy the `server` folder to `/srv/ffmpeg-automation` (or install as you prefer):

   sudo mkdir -p /srv/ffmpeg-automation
   sudo cp -r server/* /srv/ffmpeg-automation/

2. Create a user to run the worker (recommended):

   sudo useradd -r -s /usr/sbin/nologin ffmpeg
   sudo chown -R ffmpeg:ffmpeg /srv/ffmpeg-automation

3. Make scripts executable:

   sudo chmod +x /srv/ffmpeg-automation/delivery.sh
   sudo chmod +x /srv/ffmpeg-automation/worker.sh

4. Install the systemd unit (edit paths if you installed elsewhere):

   sudo cp server/systemd/ffmpeg-worker.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now ffmpeg-worker

5. Upload files to `/srv/ffmpeg-automation/incoming` (use the Windows client script in `client/` or `scp`).

Notes:
- Presets are in `presets/` and map directly to environment variables used by `delivery.sh`.
- The worker writes `.done` JSON files in `finished/` with `output` and `sha256` fields which clients can poll.
- By default the worker deletes the original input on success to free space; change `KEEP_INPUT_ON_SUCCESS` in `worker.sh` to keep archives.

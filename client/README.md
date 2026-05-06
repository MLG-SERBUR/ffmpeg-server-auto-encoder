# Remote FFmpeg Automation - Client

High-speed remote video encoding using parallel SSH streams.

## Setup

1. **Configuration**: 
   - Ensure `config.bat` exists and is correctly configured.
   - Set `REMOTE_HOST` to your server's IP address or hostname.
   - Adjust `THREADS` for speed (default is 12).
3. **Presets**: Add any custom PowerShell presets to the `presets/` folder.

## Usage

1. **Drag and Drop**: Drag one or more video files onto `remote-encode.bat` or onto a preset in the presets/` folder.
2. **Select Preset**: Choose the encoding profile when prompted.
3. **Wait**: The client will:
   - Perform a parallel multipart upload (using `dd` via SSH).
   - Verify integrity with SHA256.
   - Poll the server until the encode is finished.
   - Perform a parallel multipart download of the result.
   - Verify the final checksum.
   - Archive the local source file.
2. **Resume/Recovery**: If you shut down during an encode, run `resume-finished.bat` later. It will scan the server, download finished results to their original directories, and recycle source files.

## Requirements

- **Windows**: PowerShell 5.1+ (Standard on Win10/11).
- **SSH**: OpenSSH Client (Standard on Win10/11).

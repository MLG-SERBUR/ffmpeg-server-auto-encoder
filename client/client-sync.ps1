param(
    [Parameter(Mandatory=$true)][string]$LocalFile,
    [Parameter(Mandatory=$true)][string]$RemoteHost,
    [string]$RemoteIncomingPath = "/srv/ffmpeg-automation/incoming",
    [string]$RemoteFinishedPath = "/srv/ffmpeg-automation/finished",
    [string]$PresetFile = "",
    [string]$NamedPreset = "",
    [int]$PollInterval = 30,
    [switch]$RemoveRemoteAfterDownload
)

function Write-Log { param($m) Write-Host "[client] $m" -ForegroundColor Cyan }

if (-not (Test-Path $LocalFile)) { Write-Error "Local file not found: $LocalFile"; exit 2 }

$fullLocal = (Resolve-Path $LocalFile).Path
$baseName = [System.IO.Path]::GetFileName($fullLocal)
$nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fullLocal)

$remotePart = "$RemoteIncomingPath/$baseName.partial"
$remoteFinal = "$RemoteIncomingPath/$baseName"
$remotePreset = "$RemoteIncomingPath/$nameNoExt.preset"
$remoteDone = "$RemoteFinishedPath/$nameNoExt.done"

# 1. Prepare Preset
$tmpPreset = [System.IO.Path]::GetTempFileName()
if ($PresetFile -and (Test-Path $PresetFile)) {
    Write-Log "Loading dynamic preset from $PresetFile"
    . $PresetFile
    # Convert PS variables to Shell variables for the server
    $presetContent = "VIDEO_ENCODER='$VIDEO_ENCODER'`nAUDIO_ENCODER='$AUDIO_ENCODER'`nOUTPUT_SUFFIX='$OUTPUT_SUFFIX'`nFINAL_EXT='$FINAL_EXT'`nMOV_FLAGS='$MOV_FLAGS'"
    Set-Content -Path $tmpPreset -Value $presetContent -Encoding ASCII
} elseif ($NamedPreset) {
    Write-Log "Using named preset: $NamedPreset"
    Set-Content -Path $tmpPreset -Value $NamedPreset -Encoding ASCII
} else {
    $tmpPreset = $null
}

# 2. Upload Video using rclone
Write-Log "Uploading $baseName to $RemoteHost (using rclone)..."
& rclone copyto "$fullLocal" "${RemoteHost}:${remotePart}" --progress --sftp-chunk-size 64k
if ($LASTEXITCODE -ne 0) { Write-Error "rclone upload failed"; exit 3 }

# 3. Upload Preset
if ($tmpPreset) {
    & rclone copyto "$tmpPreset" "${RemoteHost}:${remotePreset}.partial"
    if ($LASTEXITCODE -ne 0) { Write-Error "Preset upload failed"; exit 4 }
    Remove-Item $tmpPreset -ErrorAction SilentlyContinue
}

# 4. Finalize (Atomic rename on server)
Write-Log "Finalizing upload..."
$mvcmd = "mv '$remotePart' '$remoteFinal'"
if ($tmpPreset) { $mvcmd += " && mv '${remotePreset}.partial' '$remotePreset'" }
& ssh "$RemoteHost" $mvcmd
if ($LASTEXITCODE -ne 0) { Write-Error "Remote finalize failed"; exit 5 }

Write-Log "Upload complete. Waiting for encoding..."

# 5. Poll for completion
$startTime = Get-Date
while ($true) {
    $check = & ssh "$RemoteHost" "test -f '$remoteDone' && echo OK || echo NO" 2>$null
    if ($check -and $check.Trim() -eq 'OK') { 
        Write-Log "Encoding finished!"
        break 
    }
    
    $elapsed = New-TimeSpan -Start $startTime -End (Get-Date)
    Write-Log "Encoding in progress (Elapsed: $($elapsed.ToString('hh\:mm\:ss'))). Checking again in $($PollInterval)s..."
    Start-Sleep -Seconds $PollInterval
}

# 6. Retrieve .done metadata
$tmpDone = [System.IO.Path]::GetTempFileName()
& rclone copyto "${RemoteHost}:$remoteDone" "$tmpDone"
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to download .done file"; exit 6 }

$doneJson = Get-Content $tmpDone -Raw | ConvertFrom-Json
$outName = $doneJson.output
$remoteOutputPath = "$RemoteFinishedPath/$outName"

Write-Log "Downloading result: $outName"
& rclone copyto "${RemoteHost}:$remoteOutputPath" "./$outName" --progress
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to download output file"; exit 7 }

# 7. Verify Checksum
$localOut = Join-Path (Get-Location) $outName
$localSha = (Get-FileHash -Algorithm SHA256 $localOut).Hash.ToLower()
if ($localSha -ne $doneJson.sha256.ToLower()) {
    Write-Error "Checksum mismatch! local=$localSha remote=$($doneJson.sha256)"
    exit 8
}

Write-Log "Verification successful (hash matches)."

# 8. Cleanup
if ($RemoveRemoteAfterDownload) {
    Write-Log "Cleaning up server storage..."
    & ssh "$RemoteHost" "rm -f '$remoteOutputPath' '$remoteDone'"
}

# 9. Local Archive/Delete
try {
    Write-Log "Archiving local source..."
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($fullLocal, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
} catch {
    $delDir = Join-Path (Split-Path $fullLocal -Parent) 'done'
    if (-not (Test-Path $delDir)) { New-Item -ItemType Directory $delDir }
    Move-Item -Path $fullLocal -Destination $delDir -Force
}

Write-Log "Job Finished Successfully."

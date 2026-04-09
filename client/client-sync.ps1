param(
    [Parameter(Mandatory=$true)][string]$LocalFile,
    [Parameter(Mandatory=$true)][string]$RemoteHost,
    [string]$RemotePort,
    [string]$RemoteUser,
    [string]$RemoteIncomingPath,
    [string]$RemoteFinishedPath,
    [string]$VideoEncoder,
    [string]$AudioEncoder,
    [string]$OutputSuffix,
    [string]$FinalExt,
    [string]$MovFlags,
    [string]$NamedPreset,
    [int]$PollInterval,
    [int]$Threads,
    [switch]$RemoveRemoteAfterDownload
)

# Manual Default Initialization & Sanitization
# Using Environment Variables for complex strings is the "Sigma" way to bypass PowerShell's buggy command-line parser.
if (-not $VideoEncoder) { $VideoEncoder = $env:VIDEO_ENCODER }
if (-not $AudioEncoder) { $AudioEncoder = $env:AUDIO_ENCODER }
if (-not $OutputSuffix) { $OutputSuffix = $env:OUTPUT_SUFFIX }
if (-not $FinalExt) { $FinalExt = $env:FINAL_EXT }
if (-not $MovFlags) { $MovFlags = $env:MOV_FLAGS }
if (-not $NamedPreset) { $NamedPreset = $env:SELECTED_PRESET_NAME }

# Cleanup any trailing padding or misbound names
foreach ($p in @("RemotePort", "RemoteUser", "VideoEncoder", "AudioEncoder", "OutputSuffix", "FinalExt", "MovFlags", "NamedPreset", "Threads", "PollInterval")) {
    $val = Get-Variable $p -ValueOnly
    if ($null -eq $val -or $val -isnot [string]) { continue }
    $val = $val.Trim()
    if ($val.StartsWith("-") -and $val.EndsWith(":")) { Set-Variable $p "" }
    else { Set-Variable $p $val }
}

if (-not $RemotePort) { $RemotePort = $env:REMOTE_PORT }
if (-not $RemoteUser) { $RemoteUser = $env:REMOTE_USER }
if (-not $RemoteIncomingPath) { $RemoteIncomingPath = "/srv/ffmpeg-automation/incoming" }
if (-not $RemoteFinishedPath) { $RemoteFinishedPath = "/srv/ffmpeg-automation/finished" }
if (-not $RemoteFailedPath) { $RemoteFailedPath = "/srv/ffmpeg-automation/failed" }
if (-not $PollInterval) { $PollInterval = if ($env:POLL_INTERVAL) { [int]$env:POLL_INTERVAL } else { 30 } }
if (-not $Threads) { $Threads = if ($env:THREADS) { [int]$env:THREADS } else { 6 } }

# Define target for SSH/SCP calls in the main script body
$target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }

function Write-Log { param($m) Write-Host "[client] $m" -ForegroundColor Cyan }

function Invoke-SSH {
    param($cmd, $maxRetries = 20)
    $target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }
    $sshArgs = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes")
    $pArgs = if ($RemotePort) { @("-p", $RemotePort) } else { @() }
    
    $attempt = 0
    while ($attempt -lt $maxRetries) {
        $attempt++
        $result = & ssh @pArgs @sshArgs $target $cmd
        if ($LASTEXITCODE -eq 0) { return $result }
        
        if ($attempt -lt $maxRetries) {
            Write-Warning "[ssh] Connection lost or command failed (attempt $attempt/$maxRetries). Retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    }
    throw "SSH command failed after $maxRetries attempts: $cmd"
}

function Invoke-SCP {
    param($src, $dest, $maxRetries = 20)
    $target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }
    $pArgs = if ($RemotePort) { @("-P", $RemotePort) } else { @() }
    $scpArgs = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15", "-o", "BatchMode=yes")
    
    $attempt = 0
    while ($attempt -lt $maxRetries) {
        $attempt++
        & scp @pArgs @scpArgs "$src" "$dest"
        if ($LASTEXITCODE -eq 0) { return }
        
        if ($attempt -lt $maxRetries) {
            Write-Warning "[scp] Transfer failed (attempt $attempt/$maxRetries). Retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    }
    throw "SCP failed after $maxRetries attempts: $src -> $dest"
}

if (-not (Test-Path $LocalFile)) { Write-Error "Local file not found: $LocalFile"; Read-Host "Press Enter to exit..."; exit 2 }

$fullLocal = (Resolve-Path $LocalFile).Path
$baseName = [System.IO.Path]::GetFileName($fullLocal)
$nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fullLocal)

# 0. Get Duration (for progress tracking)
$totalSeconds = 0
try {
    $durationStr = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$fullLocal"
    if ($durationStr -match '^\d+(\.\d+)?$') {
        $totalSeconds = [double]$durationStr
        Write-Log "Source Duration: $([TimeSpan]::FromSeconds($totalSeconds).ToString('hh\:mm\:ss'))"
    }
} catch {
    Write-Log "Warning: Could not determine source duration with ffprobe."
}

$remotePart = "$RemoteIncomingPath/$baseName.partial"
$remoteFinal = "$RemoteIncomingPath/$baseName"
$remotePreset = "$RemoteIncomingPath/$nameNoExt.preset"
$remoteDone = "$RemoteFinishedPath/$nameNoExt.done"
$remoteFailed = "$RemoteFailedPath/$nameNoExt.failed"

function Get-ShellSafe {
    param($val)
    if ($null -eq $val) { return "''" }
    return "'" + $val.ToString().Replace("'", "'\''") + "'"
}

# 1. Prepare Preset
$tmpPreset = [System.IO.Path]::GetTempFileName()
if ($VideoEncoder) {
    Write-Log "Generating dynamic remote preset..."
    # Convert PS variables to Shell variables for the server
    $presetContent = "export VIDEO_ENCODER=$(Get-ShellSafe $VideoEncoder)`n" +
                     "export AUDIO_ENCODER=$(Get-ShellSafe $AudioEncoder)`n" +
                     "export OUTPUT_SUFFIX=$(Get-ShellSafe $OutputSuffix)`n" +
                     "export FINAL_EXT=$(Get-ShellSafe $FinalExt)`n" +
                     "export MOV_FLAGS=$(Get-ShellSafe $MovFlags)"
    Set-Content -Path $tmpPreset -Value $presetContent -Encoding ASCII
} elseif ($NamedPreset) {
    Write-Log "Using named remote preset: $NamedPreset"
    $namedContent = "PRESET_NAME=$(Get-ShellSafe $NamedPreset)"
    Set-Content -Path $tmpPreset -Value $namedContent -Encoding ASCII
} else {
    $tmpPreset = $null
}

function Invoke-ParallelUpload {
    param($LocalPath, $RemotePath, $NumThreads=6)
    
    $fileSize = (Get-Item $LocalPath).Length
    Write-Log "Initializing remote file: $baseName ($([Math]::Round($fileSize / 1GB, 2)) GB)"
    Invoke-SSH "truncate -s $fileSize '$RemotePath'"
    
    $blockSize = 1MB
    $totalBlocks = [Math]::Ceiling($fileSize / $blockSize)
    $blocksPerThread = [Math]::Ceiling($totalBlocks / $NumThreads)
    
    # Initialize chunks to upload
    $chunks = New-Object System.Collections.Generic.List[PSObject]
    for ($i=0; $i -lt $NumThreads; $i++) {
        $startBlock = $i * $blocksPerThread
        if ($startBlock -ge $totalBlocks) { break }
        $endBlock = [Math]::Min(($i + 1) * $blocksPerThread - 1, $totalBlocks - 1)
        $numBlocks = $endBlock - $startBlock + 1
        $chunks.Add([PSCustomObject]@{ StartBlock = $startBlock; NumBlocks = $numBlocks; Status = "Pending" })
    }

    $attempt = 0
    $maxAttempts = 10
    
    while (($chunks | Where-Object { $_.Status -ne "Success" }).Count -gt 0 -and $attempt -lt $maxAttempts) {
        $attempt++
        $toUpload = $chunks | Where-Object { $_.Status -ne "Success" }
        if ($attempt -gt 1) {
            Write-Warning "[upload] Retrying $($toUpload.Count) chunks (Attempt $attempt)..."
            Start-Sleep -Seconds 5
        }

        $jobs = foreach ($chunk in $toUpload) {
            Start-Job -ScriptBlock {
                param($path, $remoteHost, $remotePort, $remoteUser, $remotePath, $startBlock, $numBlocks, $blockSize)
                
                try {
                    $byteOffset = [Int64]$startBlock * $blockSize
                    $bytesRemaining = [Int64]$numBlocks * $blockSize
                    $totalSize = (Get-Item $path).Length
                    if ($byteOffset + $bytesRemaining -gt $totalSize) { $bytesRemaining = $totalSize - $byteOffset }

                    $target = if ($remoteUser) { "${remoteUser}@${remoteHost}" } else { $remoteHost }
                    $pArr = if ($remotePort) { @("-p", $remotePort) } else { @() }
                    $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes")
                    $remoteCmd = "dd of='$remotePath' bs=$blockSize seek=$startBlock conv=notrunc"
                    
                    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $procInfo.FileName = "ssh"
                    # Combine all arguments safely
                    $allArgs = ($pArr + $sshOpts + @($target, "`"$remoteCmd`"")) -join " "
                    $procInfo.Arguments = $allArgs
                    $procInfo.UseShellExecute = $false; $procInfo.RedirectStandardInput = $true; $procInfo.RedirectStandardError = $true; $procInfo.CreateNoWindow = $true
                    
                    $p = [System.Diagnostics.Process]::Start($procInfo)
                    $stdin = $p.StandardInput.BaseStream
                    $file = [System.IO.File]::OpenRead($path)
                    $file.Seek($byteOffset, 0)
                    
                    $bufSize = 256KB
                    $buffer = New-Object byte[] $bufSize
                    while ($bytesRemaining -gt 0) {
                        $toRead = if ($bytesRemaining -lt $bufSize) { $bytesRemaining } else { $bufSize }
                        $read = $file.Read($buffer, 0, $toRead)
                        if ($read -le 0) { break }
                        $stdin.Write($buffer, 0, $read)
                        $bytesRemaining -= $read
                    }
                    $stdin.Close(); $file.Close(); $p.WaitForExit()
                    
                    if ($p.ExitCode -ne 0) { return "Error: $($p.StandardError.ReadToEnd())" }
                    return "OK"
                } catch { return "Worker Error: $($_.Exception.Message)" }
            } -ArgumentList $LocalPath, $RemoteHost, $RemotePort, $RemoteUser, $RemotePath, $chunk.StartBlock, $chunk.NumBlocks, $blockSize
        }

        Write-Log "Uploading with $NumThreads streams..."
        while ($true) {
            $stats = $jobs | Get-Job
            $running = ($stats | Where-Object { $_.State -eq 'Running' }).Count
            $finished = ($stats | Where-Object { $_.State -ne 'Running' }).Count
            Write-Host -NoNewline "`r[client] Parallel Upload: $finished/$($jobs.Count) chunks finished ($running active)          "
            if ($running -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        Write-Host ""

        # Update status based on results
        for ($i=0; $i -lt $jobs.Count; $i++) {
            $res = $jobs[$i] | Receive-Job
            if ($res -eq "OK") {
                $toUpload[$i].Status = "Success"
            } else {
                Write-Warning "[upload] Chunk $($toUpload[$i].StartBlock) failed: $res"
                $toUpload[$i].Status = "Failed"
            }
        }
        $jobs | Remove-Job
    }

    if (($chunks | Where-Object { $_.Status -ne "Success" }).Count -gt 0) {
        throw "Parallel upload failed after maximum retries."
    }
}

function Invoke-ParallelDownload {
    param($RemotePath, $LocalPath, $NumThreads=6)
    
    $fileSizeStr = Invoke-SSH "stat -c%s '$RemotePath'"
    $fileSize = [Int64]$fileSizeStr
    Write-Log "Initializing local file: $([System.IO.Path]::GetFileName($LocalPath)) ($([Math]::Round($fileSize / 1GB, 2)) GB)"
    
    if (-not (Test-Path $LocalPath)) {
        $fs = [System.IO.File]::Create($LocalPath)
        $fs.SetLength($fileSize)
        $fs.Close()
    }
    
    $blockSize = 1MB
    $totalBlocks = [Math]::Ceiling($fileSize / $blockSize)
    $blocksPerThread = [Math]::Ceiling($totalBlocks / $NumThreads)
    
    # Initialize chunks to download
    $chunks = New-Object System.Collections.Generic.List[PSObject]
    for ($i=0; $i -lt $NumThreads; $i++) {
        $startBlock = $i * $blocksPerThread
        if ($startBlock -ge $totalBlocks) { break }
        $endBlock = [Math]::Min(($i + 1) * $blocksPerThread - 1, $totalBlocks - 1)
        $numBlocks = $endBlock - $startBlock + 1
        $chunks.Add([PSCustomObject]@{ StartBlock = $startBlock; NumBlocks = $numBlocks; Status = "Pending" })
    }

    $attempt = 0
    $maxAttempts = 10
    
    while (($chunks | Where-Object { $_.Status -ne "Success" }).Count -gt 0 -and $attempt -lt $maxAttempts) {
        $attempt++
        $toDownload = $chunks | Where-Object { $_.Status -ne "Success" }
        if ($attempt -gt 1) {
            Write-Warning "[download] Retrying $($toDownload.Count) chunks (Attempt $attempt)..."
            Start-Sleep -Seconds 5
        }

        $jobs = foreach ($chunk in $toDownload) {
            Start-Job -ScriptBlock {
                param($localPath, $remoteHost, $remotePort, $remoteUser, $remotePath, $startBlock, $numBlocks, $blockSize)
                
                try {
                    $byteOffset = [Int64]$startBlock * $blockSize
                    $target = if ($remoteUser) { "${remoteUser}@${remoteHost}" } else { $remoteHost }
                    $pArr = if ($remotePort) { @("-p", $remotePort) } else { @() }
                    $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes")
                    $remoteCmd = "dd if='$remotePath' bs=$blockSize skip=$startBlock count=$numBlocks status=none"
                    
                    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $procInfo.FileName = "ssh"
                    $allArgs = ($pArr + $sshOpts + @($target, "`"$remoteCmd`"")) -join " "
                    $procInfo.Arguments = $allArgs
                    $procInfo.UseShellExecute = $false; $procInfo.RedirectStandardOutput = $true; $procInfo.CreateNoWindow = $true
                    
                    $p = [System.Diagnostics.Process]::Start($procInfo)
                    $stdout = $p.StandardOutput.BaseStream
                    $file = [System.IO.File]::Open($localPath,[System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
                    $file.Seek($byteOffset, 0)
                    
                    $bufSize = 256KB
                    $buffer = New-Object byte[] $bufSize
                    while ($true) {
                        $read = $stdout.Read($buffer, 0, $bufSize)
                        if ($read -le 0) { break }
                        $file.Write($buffer, 0, $read)
                    }
                    $file.Close(); $p.WaitForExit()
                    if ($p.ExitCode -ne 0) { return "Error: Exit $($p.ExitCode)" }
                    return "OK"
                } catch { return "Worker Error: $($_.Exception.Message)" }
            } -ArgumentList $LocalPath, $RemoteHost, $RemotePort, $RemoteUser, $RemotePath, $chunk.StartBlock, $chunk.NumBlocks, $blockSize
        }

        Write-Log "Downloading with $NumThreads streams..."
        while ($true) {
            $stats = $jobs | Get-Job
            $running = ($stats | Where-Object { $_.State -eq 'Running' }).Count
            $finished = ($stats | Where-Object { $_.State -ne 'Running' }).Count
            Write-Host -NoNewline "`r[client] Parallel Download: $finished/$($jobs.Count) chunks finished ($running active)          "
            if ($running -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        Write-Host ""

        # Update status based on results
        for ($i=0; $i -lt $jobs.Count; $i++) {
            $res = $jobs[$i] | Receive-Job
            if ($res -eq "OK") {
                $toDownload[$i].Status = "Success"
            } else {
                Write-Warning "[download] Chunk $($toDownload[$i].StartBlock) failed: $res"
                $toDownload[$i].Status = "Failed"
            }
        }
        $jobs | Remove-Job
    }

    if (($chunks | Where-Object { $_.Status -ne "Success" }).Count -gt 0) {
        throw "Parallel download failed after maximum retries."
    }
}

try {
    # 2. Upload Video using Parallel Block Writer
    Write-Log "Starting Parallel Block Upload..."
    Invoke-ParallelUpload -LocalPath "$fullLocal" -RemotePath "$remotePart" -NumThreads $Threads

    # 3. Upload Preset (Tiny file, use Invoke-SCP)
    if ($tmpPreset) {
        Invoke-SCP -src "$tmpPreset" -dest "${target}:${remotePreset}.partial"
        Remove-Item $tmpPreset -ErrorAction SilentlyContinue
    }

    # 4. Finalize & Verify Hash
    Write-Log "Verifying integrity on server..."
    $localHash = (Get-FileHash "$fullLocal" -Algorithm SHA256).Hash.ToLower()
    $remoteHash = (Invoke-SSH "sha256sum '$remotePart'").Split(' ')[0].Trim().ToLower()
    
    if ($localHash -ne $remoteHash) {
        throw "INTEGRITY FAILURE! Local: $localHash, Remote: $remoteHash"
    }
    Write-Log "Integrity check passed (SHA256: $localHash)"

    Write-Log "Finalizing upload..."
    $mvcmd = "mv '$remotePart' '$remoteFinal'"
    if ($tmpPreset) { $mvcmd += " && mv '${remotePreset}.partial' '$remotePreset'" }
    Invoke-SSH $mvcmd
    if ($LASTEXITCODE -ne 0) { throw "Remote finalize failed" }

    Write-Log "Upload complete. Waiting for encoding..."

    # 5. Poll for completion with live progress
    $startTime = Get-Date
    $remoteLogPath = ""
    $lastStatusUpdate = Get-Date
    $serverFailed = $false
    
    while ($true) {
        try {
            # Check for completion or failure
            $completionCheck = Invoke-SSH "if [ -f '$remoteDone' ]; then echo DONE; fi; if [ -f '$remoteFailed' ]; then echo FAILED; fi; exit 0" -maxRetries 2
            if ($completionCheck -match 'DONE') { 
                Write-Host "" # Clear line
                Write-Log "Encoding finished successfully!"
                break 
            }
            if ($completionCheck -match 'FAILED') {
                Write-Host ""
                $serverFailed = $true
                break
            }
            
            # Try to find the log file if we don't have it yet
            if (-not $remoteLogPath) {
                $logDir = [System.IO.Path]::GetDirectoryName($RemoteIncomingPath) + "/logs"
                $logDir = $logDir.Replace('\', '/')
                
                $foundLog = Invoke-SSH "find '$logDir' -maxdepth 1 -type f -name '${nameNoExt}_*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-; exit 0" -maxRetries 2
                if ($foundLog -and $foundLog.Trim()) {
                    $remoteLogPath = $foundLog.Trim()
                    Write-Log "Found remote log: $([System.IO.Path]::GetFileName($remoteLogPath))"
                }
            }
            
            $statusMsg = "Encoding in progress..."
            if ($remoteLogPath) {
                # Just print the last line as requested
                $lastLine = Invoke-SSH "if [ -f '$remoteLogPath' ]; then tail -n 1 '$remoteLogPath' 2>/dev/null; fi; exit 0" -maxRetries 2
                if ($lastLine -and $lastLine.Trim()) {
                    $statusMsg = $lastLine.Trim()
                }
            }
            
            Write-Log $statusMsg
        } catch {
            Write-Log "Connection lost. Waiting for server..."
        }
        
        $sleepSecs = $PollInterval
        if ($sleepSecs -lt 2) { $sleepSecs = 2 }
        Start-Sleep -Seconds $sleepSecs
    }

    if ($serverFailed) {
        throw "Encoding failed on the server. Check logs."
    }

    # 6. Retrieve .done metadata (Small file, use Invoke-SCP)
    $tmpDone = [System.IO.Path]::GetTempFileName()
    Invoke-SCP -src "${target}:${remoteDone}" -dest "$tmpDone"

    $doneJson = Get-Content $tmpDone -Raw | ConvertFrom-Json
    $outName = $doneJson.output
    $remoteOutputPath = "$RemoteFinishedPath/$outName"

    Write-Log "Downloading result: $outName (using parallel streams)"
    Invoke-ParallelDownload -RemotePath "$remoteOutputPath" -LocalPath "./$outName" -NumThreads $Threads

    # 7. Verify Checksum
    $localOut = Join-Path (Get-Location) $outName
    if (Test-Path $localOut) {
        Write-Log "Verifying results..."
        $localSha = (Get-FileHash $localOut -Algorithm SHA256).Hash.ToLower()
        if ($localSha -eq $doneJson.sha256.ToLower()) {
            Write-Log "Checksum Verified: $localSha"
            if ($RemoveRemoteAfterDownload) {
                Write-Log "Cleaning up remote files..."
                Invoke-SSH "rm -f '$remoteDone' '$remoteOutputPath'"
            }
        } else {
            Write-Warning "CHECKSUM MISMATCH!"
            Write-Warning "Local:  $localSha"
            Write-Warning "Remote: $($doneJson.sha256)"
        }
    }
    # 9. Local Archive/Delete (Moved inside the Try block)
    try {
        Write-Log "Archiving local source..."
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($fullLocal,[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    } catch {
        $delDir = Join-Path (Split-Path $fullLocal -Parent) 'done'
        if (-not (Test-Path $delDir)) { New-Item -ItemType Directory $delDir }
        Move-Item -Path $fullLocal -Destination $delDir -Force
    }

    Write-Log "Job Finished Successfully."
    Read-Host "Press Enter to exit..."
} 
catch {
    Write-Host ""
    Write-Error "A fatal error occurred: $($_.Exception.Message)"
    Read-Host "Press Enter to exit..."
    exit 1
}

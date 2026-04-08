param(
    [Parameter(Mandatory=$true)][string]$LocalFile,
    [Parameter(Mandatory=$true)][string]$RemoteHost,
    [string]$RemotePort,
    [string]$RemoteUser,
    [string]$RemoteIncomingPath = "/srv/ffmpeg-automation/incoming",
    [string]$RemoteFinishedPath = "/srv/ffmpeg-automation/finished",
    [string]$PresetFile = "",
    [string]$NamedPreset = "",
    [int]$PollInterval = 30,
    [int]$Threads = 6,
    [switch]$RemoveRemoteAfterDownload
)

function Write-Log { param($m) Write-Host "[client] $m" -ForegroundColor Cyan }

function Invoke-SSH {
    param($cmd)
    $target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }
    $portArg = if ($RemotePort) { "-p $RemotePort" } else { "" }
    
    & ssh $portArg -o StrictHostKeyChecking=no $target $cmd
}

if (-not (Test-Path $LocalFile)) { Write-Error "Local file not found: $LocalFile"; exit 2 }

$fullLocal = (Resolve-Path $LocalFile).Path
$baseName = [System.IO.Path]::GetFileName($fullLocal)
$nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fullLocal)

$remotePart = "$RemoteIncomingPath/$baseName.partial"
$remoteFinal = "$RemoteIncomingPath/$baseName"
$remotePreset = "$RemoteIncomingPath/$nameNoExt.preset"
$remoteDone = "$RemoteFinishedPath/$nameNoExt.done"

function Get-ShellSafe {
    param($val)
    if ($null -eq $val) { return "''" }
    return "'" + $val.ToString().Replace("'", "'\''") + "'"
}

# 1. Prepare Preset
$tmpPreset = [System.IO.Path]::GetTempFileName()
if ($PresetFile -and (Test-Path $PresetFile)) {
    Write-Log "Loading dynamic preset from $PresetFile"
    . $PresetFile
    # Convert PS variables to Shell variables for the server
    $presetContent = "VIDEO_ENCODER=$(Get-ShellSafe $VIDEO_ENCODER)`n" +
                     "AUDIO_ENCODER=$(Get-ShellSafe $AUDIO_ENCODER)`n" +
                     "OUTPUT_SUFFIX=$(Get-ShellSafe $OUTPUT_SUFFIX)`n" +
                     "FINAL_EXT=$(Get-ShellSafe $FINAL_EXT)`n" +
                     "MOV_FLAGS=$(Get-ShellSafe $MOV_FLAGS)"
    Set-Content -Path $tmpPreset -Value $presetContent -Encoding ASCII
} elseif ($NamedPreset) {
    Write-Log "Using named preset: $NamedPreset"
    Set-Content -Path $tmpPreset -Value $NamedPreset -Encoding ASCII
} else {
    $tmpPreset = $null
}

function Invoke-ParallelUpload {
    param($LocalPath, $RemotePath, $NumThreads=6)
    
    $fileSize = (Get-Item $LocalPath).Length
    Write-Log "Initializing remote file: $baseName ($([Math]::Round($fileSize / 1GB, 2)) GB)"
    Invoke-SSH "truncate -s $fileSize '$RemotePath'"
    if ($LASTEXITCODE -ne 0) { throw "Failed to truncate remote file" }
    
    $blockSize = 1MB
    $totalBlocks = [Math]::Ceiling($fileSize / $blockSize)
    $blocksPerThread = [Math]::Ceiling($totalBlocks / $NumThreads)
    
    $jobs = for ($i=0; $i -lt $NumThreads; $i++) {
        $startBlock = $i * $blocksPerThread
        if ($startBlock -ge $totalBlocks) { break }
        
        $endBlock = [Math]::Min(($i + 1) * $blocksPerThread - 1, $totalBlocks - 1)
        $numBlocks = $endBlock - $startBlock + 1
        
        Start-Job -ScriptBlock {
            param($path, $remoteHost, $remotePort, $remoteUser, $remotePath, $startBlock, $numBlocks, $blockSize)
            
            try {
                $byteOffset = [Int64]$startBlock * $blockSize
                $bytesRemaining = [Int64]$numBlocks * $blockSize
                
                $totalSize = (Get-Item $path).Length
                if ($byteOffset + $bytesRemaining -gt $totalSize) {
                    $bytesRemaining = $totalSize - $byteOffset
                }

                $target = if ($remoteUser) { "${remoteUser}@${remoteHost}" } else { $remoteHost }
                $portArg = if ($remotePort) { "-p $remotePort" } else { "" }
                $remoteCmd = "dd of='$remotePath' bs=$blockSize seek=$startBlock conv=notrunc"
                
                $procInfo = New-Object System.Diagnostics.ProcessStartInfo
                $procInfo.FileName = "ssh"
                $procInfo.Arguments = "$portArg -o StrictHostKeyChecking=no -o BatchMode=yes $target `"$remoteCmd`""
                $procInfo.UseShellExecute = $false
                $procInfo.RedirectStandardInput = $true
                $procInfo.RedirectStandardError = $true
                $procInfo.CreateNoWindow = $true
                
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
                
                $stdin.Close()
                $file.Close()
                $p.WaitForExit()
                
                if ($p.ExitCode -ne 0) {
                    $err = $p.StandardError.ReadToEnd()
                    return "SSH Error (Exit $($p.ExitCode)): $err"
                }
                return 0
            } catch {
                return "Worker Error: $($_.Exception.Message)"
            }
        } -ArgumentList $LocalPath, $RemoteHost, $RemotePort, $RemoteUser, $RemotePath, $startBlock, $numBlocks, $blockSize
    }
    
    Write-Log "Launched $NumThreads parallel streams. Shoveling data..."
    while ($true) {
        $stats = $jobs | Get-Job
        $running = ($stats | Where-Object { $_.State -eq 'Running' }).Count
        $finished = ($stats | Where-Object { $_.State -ne 'Running' }).Count
        Write-Host -NoNewline "`r[client] Parallel Upload: $finished/$($jobs.Count) threads finished ($running active)          "
        if ($running -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    Write-Host ""
    
    $results = $jobs | Receive-Job
    $exitCodes = $results | Where-Object { $_ -is [int] }
    $failed = $exitCodes | Where-Object { $_ -ne 0 }
    
    if (($failed) -or ($exitCodes.Count -lt $jobs.Count)) { 
        $errCount = if ($failed) { $failed.Count } else { $jobs.Count - $exitCodes.Count }
        Write-Warning "Parallel upload failed in $errCount threads."
        # Extra debug: Output any string results (errors) from the jobs
        $results | Where-Object { $_ -isnot [int] } | Write-Host -ForegroundColor Red
        throw "Parallel upload failed in $errCount threads (out of $($jobs.Count))." 
    }
    $jobs | Remove-Job
}

function Invoke-ParallelDownload {
    param($RemotePath, $LocalPath, $NumThreads=6)
    
    $fileSizeStr = Invoke-SSH "stat -c%s '$RemotePath'"
    $fileSize = [Int64]$fileSizeStr
    Write-Log "Initializing local file: $([System.IO.Path]::GetFileName($LocalPath)) ($([Math]::Round($fileSize / 1GB, 2)) GB)"
    
    # Pre-allocate local file
    $fs = [System.IO.File]::Create($LocalPath)
    $fs.SetLength($fileSize)
    $fs.Close()
    
    $blockSize = 1MB
    $totalBlocks = [Math]::Ceiling($fileSize / $blockSize)
    $blocksPerThread = [Math]::Ceiling($totalBlocks / $NumThreads)
    
    $jobs = for ($i=0; $i -lt $NumThreads; $i++) {
        $startBlock = $i * $blocksPerThread
        if ($startBlock -ge $totalBlocks) { break }
        
        $endBlock = [Math]::Min(($i + 1) * $blocksPerThread - 1, $totalBlocks - 1)
        $numBlocks = $endBlock - $startBlock + 1
        
        Start-Job -ScriptBlock {
            param($localPath, $remoteHost, $remotePort, $remoteUser, $remotePath, $startBlock, $numBlocks, $blockSize)
            
            try {
                $byteOffset = [Int64]$startBlock * $blockSize
                $target = if ($remoteUser) { "${remoteUser}@${remoteHost}" } else { $remoteHost }
                $portArg = if ($remotePort) { "-p $remotePort" } else { "" }
                
                # Remote command to stream a specific chunk
                $remoteCmd = "dd if='$remotePath' bs=$blockSize skip=$startBlock count=$numBlocks status=none"
                
                $procInfo = New-Object System.Diagnostics.ProcessStartInfo
                $procInfo.FileName = "ssh"
                $procInfo.Arguments = "$portArg -o StrictHostKeyChecking=no -o BatchMode=yes $target `"$remoteCmd`""
                $procInfo.UseShellExecute = $false
                $procInfo.RedirectStandardOutput = $true
                $procInfo.CreateNoWindow = $true
                
                $p = [System.Diagnostics.Process]::Start($procInfo)
                $stdout = $p.StandardOutput.BaseStream
                
                $file = [System.IO.File]::OpenWrite($localPath)
                $file.Seek($byteOffset, 0)
                
                $bufSize = 256KB
                $buffer = New-Object byte[] $bufSize
                
                while ($true) {
                    $read = $stdout.Read($buffer, 0, $bufSize)
                    if ($read -le 0) { break }
                    $file.Write($buffer, 0, $read)
                }
                
                $file.Close()
                $p.WaitForExit()
                return $p.ExitCode
            } catch {
                return 1
            }
        } -ArgumentList $LocalPath, $RemoteHost, $RemotePort, $RemoteUser, $RemotePath, $startBlock, $numBlocks, $blockSize
    }
    
    Write-Log "Launched $NumThreads parallel streams. Shoveling data..."
    while ($true) {
        $stats = $jobs | Get-Job
        $running = ($stats | Where-Object { $_.State -eq 'Running' }).Count
        $finished = ($stats | Where-Object { $_.State -ne 'Running' }).Count
        Write-Host -NoNewline "`r[client] Parallel Download: $finished/$($jobs.Count) threads finished ($running active)          "
        if ($running -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    Write-Host ""
    
    $results = $jobs | Receive-Job
    $exitCodes = $results | Where-Object { $_ -is [int] }
    $failed = $exitCodes | Where-Object { $_ -ne 0 }
    
    if (($failed) -or ($exitCodes.Count -lt $jobs.Count)) { 
        throw "Parallel download failed." 
    }
    $jobs | Remove-Job
}

try {
    # 2. Upload Video using Parallel Block Writer
    Write-Log "Starting Parallel Block Upload..."
    Invoke-ParallelUpload -LocalPath "$fullLocal" -RemotePath "$remotePart" -NumThreads $Threads

    # 3. Upload Preset (Tiny file, use scp)
    if ($tmpPreset) {
        $target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }
        $portArg = if ($RemotePort) { "-P $RemotePort" } else { "" }
        & scp $portArg -o StrictHostKeyChecking=no "$tmpPreset" "${target}:${remotePreset}.partial"
        if ($LASTEXITCODE -ne 0) { throw "Preset upload failed" }
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

    # 5. Poll for completion
    $startTime = Get-Date
    while ($true) {
        $check = Invoke-SSH "test -f '$remoteDone' && echo OK || echo NO" 
        if ($check -and $check.Trim() -eq 'OK') { 
            Write-Log "Encoding finished!"
            break 
        }
        
        $elapsed = New-TimeSpan -Start $startTime -End (Get-Date)
        Write-Log "Encoding in progress (Elapsed: $($elapsed.ToString('hh\:mm\:ss'))). Checking again in $($PollInterval)s..."
        Start-Sleep -Seconds $PollInterval
    }

    # 6. Retrieve .done metadata (Small file, use scp or simple ssh cat)
    $tmpDone = [System.IO.Path]::GetTempFileName()
    $target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }
    $portArg = if ($RemotePort) { "-P $RemotePort" } else { "" }
    & scp $portArg -o StrictHostKeyChecking=no "${target}:${remoteDone}" "$tmpDone"
    if ($LASTEXITCODE -ne 0) { throw "Failed to download .done file" }

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
}
finally {
    # No cleanup needed
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

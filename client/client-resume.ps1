param(
    [Parameter(Mandatory=$true)][string]$RemoteHost,
    [string]$RemotePort,
    [string]$RemoteUser,
    [string]$RemoteIncomingPath = "/srv/ffmpeg-automation/incoming",
    [string]$RemoteFinishedPath = "/srv/ffmpeg-automation/finished",
    [int]$Threads = 6,
    [switch]$RemoveRemoteAfterDownload
)

if (-not $Threads) { $Threads = if ($env:THREADS) { [int]$env:THREADS } else { 6 } }
if (-not $RemotePort) { $RemotePort = $env:REMOTE_PORT }
if (-not $RemoteUser) { $RemoteUser = $env:REMOTE_USER }

function Write-Log { param($m) Write-Host "[resume] $m" -ForegroundColor Yellow }

function Invoke-SSH {
    param($cmd, $maxRetries = 20)
    $target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }
    $sshArgs = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes")
    $pArgs = if ($RemotePort) { @("-p", $RemotePort) } else { @() }
    
    $attempt = 0
    while ($attempt -lt $maxRetries) {
        $attempt++
        $result = $null | & ssh @pArgs @sshArgs $target $cmd
        if ($LASTEXITCODE -eq 0) { return $result }
        
        if ($attempt -lt $maxRetries) {
            Write-Warning "[ssh] Connection lost or command failed (attempt $attempt/$maxRetries). Retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    }
    throw "SSH failed: $cmd"
}

function Invoke-SCP {
    param($src, $dest, $maxRetries = 10)
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
    throw "SCP failed: $src -> $dest"
}

function Invoke-ParallelDownload {
    param($RemotePath, $LocalPath, $NumThreads=6)
    $fileSizeStr = Invoke-SSH "stat -c%s '$RemotePath'"
    $fileSize = [Int64]$fileSizeStr
    if (-not (Test-Path $LocalPath)) {
        $fs = [System.IO.File]::Create($LocalPath); $fs.SetLength($fileSize); $fs.Close()
    }
    $blockSize = 1MB
    $totalBlocks = [Math]::Ceiling($fileSize / $blockSize)
    $blocksPerThread = [Math]::Ceiling($totalBlocks / $NumThreads)
    $chunks = New-Object System.Collections.Generic.List[PSObject]
    for ($i=0; $i -lt $NumThreads; $i++) {
        $startBlock = $i * $blocksPerThread
        if ($startBlock -ge $totalBlocks) { break }
        $endBlock = [Math]::Min(($i + 1) * $blocksPerThread - 1, $totalBlocks - 1)
        $chunks.Add([PSCustomObject]@{ StartBlock = $startBlock; NumBlocks = ($endBlock - $startBlock + 1); Status = "Pending" })
    }

    $toDownload = $chunks
    $jobs = foreach ($chunk in $toDownload) {
        Start-Job -ScriptBlock {
            param($localPath, $remoteHost, $remotePort, $remoteUser, $remotePath, $startBlock, $numBlocks, $blockSize, $totalSize)
            try {
                $byteOffset = [Int64]$startBlock * $blockSize
                $bytesRemaining = [Int64]$numBlocks * $blockSize
                if ($byteOffset + $bytesRemaining -gt $totalSize) { $bytesRemaining = $totalSize - $byteOffset }
                $target = if ($remoteUser) { "${remoteUser}@${remoteHost}" } else { $remoteHost }
                $pArr = if ($remotePort) { @("-p", $remotePort) } else { @() }
                $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes")
                $remoteCmd = "dd if='$remotePath' bs=$blockSize skip=$startBlock count=$numBlocks iflag=fullblock status=none"
                $procInfo = New-Object System.Diagnostics.ProcessStartInfo
                $procInfo.FileName = "ssh"
                $procInfo.Arguments = ($pArr + $sshOpts + @($target, "`"$remoteCmd`"")) -join " "
                $procInfo.UseShellExecute = $false; $procInfo.RedirectStandardOutput = $true; $procInfo.RedirectStandardInput = $true; $procInfo.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($procInfo)
                $p.StandardInput.Close()
                $stdout = $p.StandardOutput.BaseStream
                $file = [System.IO.File]::Open($localPath,[System.IO.FileMode]::Open, [System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
                $file.Seek($byteOffset, 0)
                $bufSize = 256KB; $buffer = New-Object byte[] $bufSize
                while ($bytesRemaining -gt 0) {
                    $toRead = if ($bytesRemaining -lt $bufSize) { $bytesRemaining } else { $bufSize }
                    $read = $stdout.Read($buffer, 0, $toRead)
                    if ($read -le 0) { break }
                    $file.Write($buffer, 0, $read)
                    $bytesRemaining -= $read
                }
                $file.Close(); if (-not $p.HasExited) { $p.Kill() }
                return if ($bytesRemaining -le 0) { "OK" } else { "Incomplete" }
            } catch { return "Error: $($_.Exception.Message)" }
        } -ArgumentList $LocalPath, $RemoteHost, $RemotePort, $RemoteUser, $RemotePath, $chunk.StartBlock, $chunk.NumBlocks, $blockSize, $fileSize
    }
    while (($jobs | Get-Job | Where-Object { $_.State -eq 'Running' })) { Start-Sleep -Milliseconds 500 }
    $jobs | Remove-Job
}

Write-Log "Checking server for finished jobs..."
$doneFiles = Invoke-SSH "ls $RemoteFinishedPath/*.done 2>/dev/null"
if (-not $doneFiles) {
    Write-Log "No finished jobs found."
} else {
    foreach ($doneFile in ($doneFiles -split "`n" | Where-Object { $_.Trim() })) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($doneFile)
        Write-Log "Processing: $name"
        
        $tmpDone = [System.IO.Path]::GetTempFileName()
        $target = if ($RemoteUser) { "${RemoteUser}@${RemoteHost}" } else { $RemoteHost }
        Invoke-SCP -src "${target}:$doneFile" -dest "$tmpDone"
        
        $rawDone = Get-Content $tmpDone -Raw
        $doneJson = $rawDone | ConvertFrom-Json
        $outName = $doneJson.output
        $remoteOut = "$RemoteFinishedPath/$outName"
        
        $localDir = Get-Location
        if ($doneJson.client_path) {
            $cleanPath = $doneJson.client_path.Trim()
            try {
                $localDir = [System.IO.Path]::GetDirectoryName($cleanPath)
                if (-not (Test-Path $localDir)) { 
                    Write-Log "Original path $localDir not found, using current dir."
                    $localDir = Get-Location 
                }
            } catch {
                Write-Log "Could not resolve client_path, using current dir."
                $localDir = Get-Location
            }
        }
        
        $localFinal = Join-Path $localDir $outName
        Write-Log "Downloading to: $localFinal"
        Invoke-ParallelDownload -RemotePath "$remoteOut" -LocalPath "$localFinal" -NumThreads $Threads
        
        Write-Log "Verifying checksum..."
        $localSha = (Get-FileHash $localFinal -Algorithm SHA256).Hash.ToLower()
        if ($localSha -eq $doneJson.sha256.ToLower()) {
            Write-Log "Success! Verified: $localSha"
            
            try {
                if ($doneJson.client_path) {
                    $cleanPath = $doneJson.client_path.Trim()
                    if (Test-Path $cleanPath) {
                        Write-Log "Recycling original: $cleanPath"
                        Add-Type -AssemblyName Microsoft.VisualBasic
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($cleanPath, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                    }
                }
            } catch { Write-Log "Could not recycle original (path may be invalid)." }
            
            Write-Log "Cleaning up server..."
            Invoke-SSH "rm -f '$doneFile' '$remoteOut'"
        } else {
            Write-Error "Checksum mismatch for $outName"
        }
        Remove-Item $tmpDone
    }
}

Write-Log "Status of pending jobs:"
Invoke-SSH "echo '--- Active (Processing) ---'; ls /srv/ffmpeg-automation/processing/ 2>/dev/null | grep -v '.preset$'; echo '--- Queued (Incoming) ---'; ls /srv/ffmpeg-automation/incoming/ 2>/dev/null | grep -vE '(.partial|.preset)$'; exit 0" | Write-Host -ForegroundColor Cyan

Read-Host "Press Enter to exit..."

param(
    [Parameter(Mandatory=$true)][string]$LocalFile,
    [Parameter(Mandatory=$true)][string]$RemoteUser,
    [Parameter(Mandatory=$true)][string]$RemoteHost,
    [string]$RemoteIncomingPath = "/srv/ffmpeg-automation/incoming",
    [string]$RemoteFinishedPath = "/srv/ffmpeg-automation/finished",
    [string]$Preset = "",
    [int]$Port = 22,
    [switch]$RemoveRemoteAfterDownload
)

function Write-Log { param($m) Write-Host "[client] $m" }

if (-not (Test-Path $LocalFile)) { Write-Error "Local file not found: $LocalFile"; exit 2 }

$fullLocal = (Resolve-Path $LocalFile).Path
$baseName = [System.IO.Path]::GetFileName($fullLocal)
$nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fullLocal)

$remotePart = "$RemoteIncomingPath/$baseName.part"
$remoteFinal = "$RemoteIncomingPath/$baseName"
$remotePresetPart = "$RemoteIncomingPath/$nameNoExt.preset.part"
$remotePreset = "$RemoteIncomingPath/$nameNoExt.preset"
$remoteDone = "$RemoteFinishedPath/$nameNoExt.done"

Write-Log "Uploading $fullLocal -> $RemoteUser@$RemoteHost:$RemoteIncomingPath"

# Upload file as .part
& scp -P $Port -q $fullLocal "$RemoteUser@$RemoteHost:$remotePart"
if ($LASTEXITCODE -ne 0) { Write-Error "SCP upload failed"; exit 3 }

if ($Preset -ne "") {
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $Preset -Encoding ASCII
    & scp -P $Port -q $tmp "$RemoteUser@$RemoteHost:$remotePresetPart"
    if ($LASTEXITCODE -ne 0) { Write-Error "SCP preset upload failed"; Remove-Item $tmp -ErrorAction SilentlyContinue; exit 4 }
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# Atomically rename on server
$mvcmd = "mv '$remotePart' '$remoteFinal'"
if ($Preset -ne "") { $mvcmd += " && mv '$remotePresetPart' '$remotePreset' || true" }
& ssh -p $Port "$RemoteUser@$RemoteHost" $mvcmd
if ($LASTEXITCODE -ne 0) { Write-Error "Remote finalize failed"; exit 5 }

Write-Log "Upload finalized on server. Waiting for .done file: $remoteDone"

# Poll for done
while ($true) {
    $check = & ssh -p $Port "$RemoteUser@$RemoteHost" "bash -lc 'test -f \"$remoteDone\" && echo OK || echo NO'" 2>$null
    if ($check -and $check.Trim() -eq 'OK') { break }
    Start-Sleep -Seconds 600
}

# Retrieve done JSON
$tmpDone = New-TemporaryFile
& scp -P $Port -q "$RemoteUser@$RemoteHost:$remoteDone" $tmpDone
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to download .done file"; Remove-Item $tmpDone -ErrorAction SilentlyContinue; exit 6 }

$doneJson = Get-Content $tmpDone -Raw | ConvertFrom-Json
$outName = $doneJson.output
$remoteOutputPath = "$RemoteFinishedPath/$outName"

Write-Log "Found finished output: $outName. Downloading..."

& scp -P $Port -q "$RemoteUser@$RemoteHost:$remoteOutputPath" .
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to download output file"; exit 7 }

# Verify checksum
$localOut = Join-Path (Get-Location) $outName
$localSha = (Get-FileHash -Algorithm SHA256 $localOut).Hash.ToLower()
if ($localSha -ne $doneJson.sha256.ToLower()) {
    Write-Error "Checksum mismatch! local=$localSha remote=$($doneJson.sha256)"
    exit 8
}

Write-Log "Download verified (sha256 ok)."

if ($RemoveRemoteAfterDownload) {
    & ssh -p $Port "$RemoteUser@$RemoteHost" "rm -f '$remoteOutputPath' '$remoteDone' || true"
}

# Move local original to Recycle Bin (best-effort)
try {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($fullLocal, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    Write-Log "Moved local original to Recycle Bin"
} catch {
    Write-Log "Recycle Bin move failed, moving to ./deleted/"
    $delDir = Join-Path (Split-Path $fullLocal -Parent) 'deleted'
    New-Item -ItemType Directory -Force -Path $delDir | Out-Null
    Move-Item -Path $fullLocal -Destination $delDir -Force
}

Write-Log "Job complete."

# watch-downloads-unblock.ps1
# Watches the Downloads folder and unblocks new files as soon as they finish downloading,
# so Explorer's preview pane (and Office/PDF viewers) can open them without a security prompt.

$targetPath = "$env:USERPROFILE\Downloads"
$logPath = "$env:TEMP\watch-downloads-unblock.log"

if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
    $msg = "ERROR: Downloads folder not found at: $targetPath"
    Add-Content -Path $logPath -Value $msg
    Write-Host $msg
    exit 1
}

function Unblock-IfPossible {
    param([string]$Path)

    # Browsers often write to a temp name (.crdownload/.tmp) then rename it once done,
    # and may still hold a lock for a moment after that. Retry briefly instead of failing once.
    $attempts = 0
    while ($attempts -lt 10) {
        try {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $item = Get-Item -LiteralPath $Path -ErrorAction Stop
                if (-not ($item.Attributes -band [IO.FileAttributes]::Offline)) {
                    Unblock-File -LiteralPath $Path -ErrorAction Stop
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $logPath -Value "[$timestamp] Unblocked: $Path"
                }
            }
            return
        }
        catch {
            Start-Sleep -Milliseconds 500
            $attempts++
        }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logPath -Value "[$timestamp] Failed to unblock after 10 attempts: $Path"
}

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $targetPath
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite
$watcher.EnableRaisingEvents = $true

$action = {
    $path = $Event.SourceEventArgs.FullPath
    Start-Sleep -Milliseconds 500   # let the write/rename settle before touching it
    Unblock-IfPossible -Path $path
}

# Created covers files that appear with their final name;
# Renamed covers browsers that download as .crdownload/.tmp then rename on completion.
$createdEvent = Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action
$renamedEvent = Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action

Write-Host "Watching $targetPath for new downloads... (Ctrl+C to stop)"
Write-Host "Logging to: $logPath"

try {
    while ($true) { Start-Sleep -Seconds 5 }
}
finally {
    # Cleanup event subscriptions on graceful shutdown
    Unregister-Event -SourceIdentifier $createdEvent.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $renamedEvent.Name -ErrorAction SilentlyContinue
    $watcher.Dispose()
    Add-Content -Path $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Watcher stopped"
}
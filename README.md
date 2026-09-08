# Auto-Unblock Downloaded Files for Explorer Preview (PowerShell)

Windows marks files downloaded from the internet with a "blocked" flag (the NTFS `Zone.Identifier` alternate data stream), which prevents Explorer's preview pane from rendering them until you manually check "Unblock" in the file's Properties dialog. This guide sets up a background watcher that unblocks new files in `Downloads` automatically, the moment they finish downloading — no manual steps needed.

## How it works

A PowerShell script uses `FileSystemWatcher` to monitor your `Downloads` folder in the background. Whenever a file is created or renamed (covers browsers that download to a temp name like `.crdownload` and rename on completion), it runs `Unblock-File` on it automatically. A Windows Scheduled Task starts this watcher silently every time you log on, so it's always running without you thinking about it.

> **Security Note:** This script automatically removes the Windows "blocked" flag from all downloaded files, which disables the security warning that normally appears when opening files from the internet. Only use this if you trust your download sources and understand the implications.

## 1. Save the watcher script

Create the folder `C:\Scripts` if it doesn't exist, then save this as `C:\Scripts\watch-downloads-unblock.ps1`:

```powershell
# watch-downloads-unblock.ps1
# Watches the Downloads folder and unblocks new files as soon as they finish downloading,
# so Explorer's preview pane (and Office/PDF viewers) can open them without a security prompt.

$targetPath = "$env:USERPROFILE\Downloads"

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
                }
            }
            return
        }
        catch {
            Start-Sleep -Milliseconds 500
            $attempts++
        }
    }
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
Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action | Out-Null

Write-Host "Watching $targetPath for new downloads... (Ctrl+C to stop)"
while ($true) { Start-Sleep -Seconds 5 }
```

## 2. Check your PowerShell 7 path

If you're using PowerShell 7 (`pwsh`), confirm where it's installed — Scheduled Tasks needs the **full path**, since it doesn't resolve `pwsh.exe` from PATH the way an interactive shell does:

```powershell
Get-Command pwsh | Select-Object Source
```

Typically: `C:\Program Files\PowerShell\7\pwsh.exe`. Use that full path in the next step (swap in `powershell.exe` instead if you're on Windows PowerShell 5.1, which is on PATH by default).

## 3. Register the Scheduled Task

Run this from an **elevated** PowerShell/pwsh window (Run as administrator) — writing scheduled task changes can fail silently without elevation:

```powershell
$action = New-ScheduledTaskAction -Execute "C:\Program Files\PowerShell\7\pwsh.exe" `
    -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -File "C:\Scripts\watch-downloads-unblock.ps1"' `
    -WorkingDirectory "C:\Scripts"
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "Watch Downloads Unblock" -Action $action -Trigger $trigger -Settings $settings `
    -Description "Auto-unblocks new files in Downloads for Explorer preview"
```

Key details baked into this:
- **Full `pwsh.exe` path** — a bare `pwsh.exe` fails with error `0x80070002` ("file not found") under Task Scheduler.
- **Quoted script path** in `-Argument` — avoids parsing ambiguity.
- **`-WorkingDirectory`** set explicitly — Scheduled Tasks otherwise defaults to `C:\Windows\System32`.
- **`ExecutionTimeLimit` set to zero** — disables the default 3-day (`PT72H`) kill timer, since this script is meant to run forever.

## 4. Start it and verify

```powershell
Start-ScheduledTask -TaskName "Watch Downloads Unblock"
Start-Sleep -Seconds 5
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Format-List ProcessId, CommandLine
```

You should see one `pwsh` process whose `CommandLine` matches the task's full arguments. Wait a minute and check again — if the same process ID is still there, it's stable.

To check the task's last run status at any time:

```powershell
Get-ScheduledTask -TaskName "Watch Downloads Unblock" | Get-ScheduledTaskInfo | Select-Object LastTaskResult
```

- `0` = last run finished successfully
- `267009` (`0x41301`, `SCHED_S_TASK_RUNNING`) = task is currently active — this is normal for a long-running watcher, not an error

## 5. Real-world test

Download any file into `Downloads`. Right-click it → **Properties**. If the "Unblock" checkbox and security warning at the bottom of the General tab are absent, the watcher caught it. You can also just open it directly in Explorer's preview pane.

## Managing the task later

**Stop it:**
```powershell
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -like "*watch-downloads-unblock*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

**Remove it entirely:**
```powershell
Unregister-ScheduledTask -TaskName "Watch Downloads Unblock" -Confirm:$false
```

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `LastTaskResult` = `2147942402` (`0x80070002`) | `pwsh.exe`/script path not found by Task Scheduler | Use full `pwsh.exe` path in the task action; verify script path with `Test-Path` |
| `Set-ScheduledTask` seems to succeed but `Actions` still shows the old command | Change wasn't applied — needs elevation | Rerun `Set-ScheduledTask` from an elevated window, then re-check with `Get-ScheduledTask ... | Select -Expand Actions` |
| Multiple `pwsh.exe` processes running | Leftover manual test runs weren't cleaned up | Identify by `CommandLine` via `Get-CimInstance Win32_Process`, then `Stop-Process -Id <PID> -Force` on the stray only |
| `LastTaskResult` = `267009` | Not an error — task is actively running | No action needed |

## Viewing logs

The script logs all unblock operations and errors to `%TEMP%\watch-downloads-unblock.log`. To view recent activity:

```powershell
Get-Content "$env:TEMP\watch-downloads-unblock.log" -Tail 20
```

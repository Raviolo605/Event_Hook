# EventHookEngine.ps1 — universal working version (filtered)
# Monitors: USB insertion/removal, app launch/close (visible only), file changes/creation/deletion, CPU overload

Import-Module ScheduledTasks
Import-Module BurntToast

function Send-Notification($msg) {
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $fullMsg = "$now - $msg"
    Write-Host $fullMsg -ForegroundColor Cyan
    New-BurntToastNotification -Text $now, $msg
    Add-Content -Path "$env:USERPROFILE\Desktop\engine_log.txt" -Value $fullMsg
}

# 1. USB detection via WMI
Register-WmiEvent -Class Win32_VolumeChangeEvent -SourceIdentifier "USBChange" -Action {
    $eventType = $Event.SourceEventArgs.EventType
    switch ($eventType) {
        2 { Send-Notification "USB drive removed." }
        3 {
            Start-Sleep -Milliseconds 1000
            $vol = $null
            for ($i = 0; $i -lt 5; $i++) {
                $vol = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' } | Sort-Object DriveLetter -Descending | Select-Object -First 1
                if ($vol) { break }
                Start-Sleep -Milliseconds 500
            }
            if ($vol) {
                Send-Notification "USB drive inserted: $($vol.DriveLetter):\ ($($vol.FileSystemLabel))"
            } else {
                Send-Notification "USB drive inserted (volume not identified)."
            }
        }
    }
}

# 2. New visible app detection (only launch/close)
$global:knownProcs = @{}
Register-ObjectEvent -SourceIdentifier 'ProcessWatcher' -InputObject (New-Object System.Timers.Timer) -EventName Elapsed -Action {
    $current = Get-Process | Where-Object { $_.MainWindowTitle -ne "" } | Group-Object Id -AsHashTable
    foreach ($proc in $current.Values) {
        if (-not $global:knownProcs.ContainsKey($proc.Id)) {
            $global:knownProcs[$proc.Id] = $proc.ProcessName
            Send-Notification "App launched: $($proc.ProcessName)"
        }
    }
    $toRemove = @()
    foreach ($id in $global:knownProcs.Keys) {
        if (-not $current.ContainsKey($id)) {
            Send-Notification "App closed: $($global:knownProcs[$id])"
            $toRemove += $id
        }
    }
    foreach ($id in $toRemove) { $global:knownProcs.Remove($id) }
} | Out-Null
(Get-EventSubscriber -SourceIdentifier 'ProcessWatcher').SourceObject.Interval = 4000
(Get-EventSubscriber -SourceIdentifier 'ProcessWatcher').SourceObject.Enabled = $true

# 3. File system monitoring: only visible folders
$paths = @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Downloads")
foreach ($path in $paths) {
    if (Test-Path $path) {
        $fsw = New-Object IO.FileSystemWatcher $path, '*.*'
        $fsw.IncludeSubdirectories = $true
        $fsw.EnableRaisingEvents = $true

        Register-ObjectEvent $fsw Changed -Action {
            $path = $Event.SourceEventArgs.FullPath
            if (-not $path.EndsWith("engine_log.txt")) { Send-Notification "File modified: $path" }
        }
        Register-ObjectEvent $fsw Created -Action {
            $path = $Event.SourceEventArgs.FullPath
            if (-not $path.EndsWith("engine_log.txt")) { Send-Notification "File created: $path" }
        }
        Register-ObjectEvent $fsw Deleted -Action {
            $path = $Event.SourceEventArgs.FullPath
            if (-not $path.EndsWith("engine_log.txt")) { Send-Notification "File deleted: $path" }
        }
    }
}

# 4. CPU overload > 85% for 10s
Start-Job {
    while ($true) {
        $cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
        if ($cpu -gt 85) {
            Start-Sleep -Seconds 10
            $cpu2 = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
            if ($cpu2 -gt 85) {
                Send-Notification "CPU overload detected over 85%"
            }
        }
        Start-Sleep -Seconds 5
    }
} | Out-Null

# 5. Hardware device monitoring (input: mouse, keyboard, audio, others)
$global:prevDevices = @()
Register-ObjectEvent -SourceIdentifier 'DeviceMonitor' -InputObject (New-Object System.Timers.Timer) -EventName Elapsed -Action {
    $current = Get-PnpDevice | Where-Object { $_.Status -eq "OK" -and $_.Class -match '^(USB|AudioEndpoint|Keyboard|Mouse|HIDClass)$' }
    $diff = Compare-Object -ReferenceObject $global:prevDevices -DifferenceObject $current -Property Name, InstanceId -PassThru
    foreach ($d in $diff) {
        $dir = if ($d.SideIndicator -eq "=>") { "Connected" } else { "Disconnected" }
        Send-Notification "Device ${dir}: $($d.Name) (Type: $($d.Class), ID: $($d.InstanceId))"
    }
    $global:prevDevices = $current
} | Out-Null
(Get-EventSubscriber -SourceIdentifier 'DeviceMonitor').SourceObject.Interval = 5000
(Get-EventSubscriber -SourceIdentifier 'DeviceMonitor').SourceObject.Enabled = $true

Send-Notification "[EventHookEngine] Started. Listening for system hooks..."
while ($true) { Start-Sleep -Seconds 1 }

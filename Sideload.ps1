# Fire TV Sideload - a tiny WinForms GUI that pushes APKs to a Fire TV Stick
# over ADB (network debugging). Zero build required; adb is auto-downloaded on
# first run into .\tools\platform-tools.
#
# Threading model: adb runs as an async process, but nothing depends on .NET
# process events (they stop firing once the Process object is unrooted). The UI
# timer polls HasExited, enforces a per-job timeout, and advances a job queue.
# Worker threads only ever push strings onto a concurrent queue, so no WinForms
# control is touched off the UI thread.
#
# NOTE: keep this file pure ASCII. Windows PowerShell 5.1 reads .ps1 as the
# system ANSI codepage, so a non-ASCII character silently breaks parsing.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ToolsDir  = Join-Path $ScriptDir 'tools'
$AdbExe    = Join-Path $ToolsDir 'platform-tools\adb.exe'
$AdbUrl    = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$RememberFile = Join-Path $ScriptDir 'last-ip.txt'

$DefaultTimeout  = 30
$InstallTimeout  = 180

# ---------------------------------------------------------------------------
# adb bootstrapping
# ---------------------------------------------------------------------------
function Ensure-Adb {
    param([scriptblock]$Log)
    if (Test-Path $AdbExe) { return $AdbExe }

    & $Log "adb not found. Downloading Google platform-tools..."
    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }
    $zip = Join-Path $ToolsDir 'platform-tools.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $AdbUrl -OutFile $zip -UseBasicParsing
    & $Log "Extracting..."
    Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $AdbExe)) { throw "Downloaded platform-tools but adb.exe was not found at $AdbExe" }
    & $Log "adb ready: $AdbExe"
    return $AdbExe
}

# ---------------------------------------------------------------------------
# shared state
# ---------------------------------------------------------------------------
$logQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$state = [pscustomobject]@{
    Adb      = $null
    Serial   = ''
    Busy     = $false
    Jobs     = @()
    Index    = 0
    Proc     = $null
    OutReg   = @()
    Deadline = [datetime]::MaxValue
    Limit    = $DefaultTimeout
    ExitSeen = $null
    FailStep = -1
    JobOut   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Fire TV Sideload'
$form.Size            = New-Object System.Drawing.Size(680, 520)
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = $form.Size
$form.AllowDrop       = $true
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$lblIp                = New-Object System.Windows.Forms.Label
$lblIp.Text           = 'Stick IP:'
$lblIp.Location       = New-Object System.Drawing.Point(16, 20)
$lblIp.AutoSize       = $true

$txtIp                = New-Object System.Windows.Forms.TextBox
$txtIp.Location       = New-Object System.Drawing.Point(80, 16)
$txtIp.Size           = New-Object System.Drawing.Size(180, 24)
$txtIp.Text           = '192.168.1.'
if (Test-Path $RememberFile) { $txtIp.Text = (Get-Content $RememberFile -Raw).Trim() }

$lblPort              = New-Object System.Windows.Forms.Label
$lblPort.Text         = ':5555'
$lblPort.Location     = New-Object System.Drawing.Point(266, 20)
$lblPort.AutoSize     = $true

$btnConnect           = New-Object System.Windows.Forms.Button
$btnConnect.Text      = 'Connect'
$btnConnect.Location  = New-Object System.Drawing.Point(320, 14)
$btnConnect.Size      = New-Object System.Drawing.Size(90, 28)

$btnDisconnect        = New-Object System.Windows.Forms.Button
$btnDisconnect.Text   = 'Disconnect'
$btnDisconnect.Location = New-Object System.Drawing.Point(416, 14)
$btnDisconnect.Size   = New-Object System.Drawing.Size(100, 28)

$btnDevices           = New-Object System.Windows.Forms.Button
$btnDevices.Text      = 'Devices'
$btnDevices.Location  = New-Object System.Drawing.Point(522, 14)
$btnDevices.Size      = New-Object System.Drawing.Size(90, 28)

$btnBrowse            = New-Object System.Windows.Forms.Button
$btnBrowse.Text       = 'Install APK...'
$btnBrowse.Location   = New-Object System.Drawing.Point(16, 54)
$btnBrowse.Size       = New-Object System.Drawing.Size(140, 30)

$lblHint              = New-Object System.Windows.Forms.Label
$lblHint.Text         = '...or drag one or more .apk files anywhere onto this window.'
$lblHint.Location     = New-Object System.Drawing.Point(168, 62)
$lblHint.AutoSize     = $true
$lblHint.ForeColor    = [System.Drawing.Color]::Gray

$txtLog               = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline     = $true
$txtLog.ScrollBars    = 'Vertical'
$txtLog.ReadOnly      = $true
$txtLog.Location      = New-Object System.Drawing.Point(16, 96)
$txtLog.Size          = New-Object System.Drawing.Size(632, 340)
$txtLog.Anchor        = 'Top,Bottom,Left,Right'
$txtLog.BackColor     = [System.Drawing.Color]::FromArgb(28, 28, 28)
$txtLog.ForeColor     = [System.Drawing.Color]::Gainsboro
$txtLog.Font          = New-Object System.Drawing.Font('Consolas', 9)

$btnClear             = New-Object System.Windows.Forms.Button
$btnClear.Text        = 'Clear log'
$btnClear.Location    = New-Object System.Drawing.Point(548, 444)
$btnClear.Size        = New-Object System.Drawing.Size(100, 26)
$btnClear.Anchor      = 'Bottom,Right'

$form.Controls.AddRange(@($lblIp, $txtIp, $lblPort, $btnConnect, $btnDisconnect,
    $btnDevices, $btnBrowse, $lblHint, $txtLog, $btnClear))

# Safe to call from any thread.
function Write-Log {
    param([string]$Message)
    $logQueue.Enqueue(((Get-Date -Format 'HH:mm:ss') + '  ' + $Message))
}
$Log = { param($m) Write-Log $m }

function Set-ButtonsEnabled {
    param([bool]$Enabled)
    $btnConnect.Enabled    = $Enabled
    $btnDisconnect.Enabled = $Enabled
    $btnDevices.Enabled    = $Enabled
    $btnBrowse.Enabled     = $Enabled
}

# ---------------------------------------------------------------------------
# job runner
# ---------------------------------------------------------------------------
function Start-AdbJob {
    param([string[]]$Arguments)
    if ($state.Busy) { Write-Log 'Busy - wait for the current operation to finish.'; return }
    if (-not $state.Adb) { Write-Log 'adb is not ready.'; return }
    # @(,$x) = a one-element array whose element is the argument list. Plain
    # @($x) would flatten it and run each argument as its own adb command.
    $state.Jobs     = @(,$Arguments)
    $state.Index    = 0
    $state.FailStep = -1
    $state.Busy     = $true
    Set-ButtonsEnabled $false
    Raise-Job
}

function Start-ApkInstall {
    param([string]$LocalPath)
    if ($state.Busy) { Write-Log 'Busy - wait for the current operation to finish.'; return }
    if (-not $state.Adb) { Write-Log 'adb is not ready.'; return }

    $name    = Split-Path $LocalPath -Leaf
    $tmpPath = '/data/local/tmp/' + $name

    # adb install over Wi-Fi hangs on Fire TV, so push the file and let the
    # device's own package manager install it from local storage.
    $jobs = @(
        ,@('push', $LocalPath, $tmpPath)
        ,@('shell', 'pm', 'install', '-r', '-d', $tmpPath)
        ,@('shell', 'rm', '-f', $tmpPath)
    )
    $state.Jobs     = $jobs
    $state.Index    = 0
    $state.FailStep = 1
    $state.Busy     = $true
    Set-ButtonsEnabled $false
    Write-Log ("Installing " + $name + " (push, then on-device pm install)...")
    Raise-Job
}

function Raise-Job {
    if ($state.Index -ge $state.Jobs.Count) {
        Write-Log 'Done.'
        Complete-Job
        return
    }
    # $jobArgs, not $args - $args is a PowerShell automatic variable.
    $jobArgs = @($state.Jobs[$state.Index])
    $label   = ($jobArgs -join ' ')
    $limit   = if ($state.Index -eq 1 -and $state.FailStep -eq 1) { $InstallTimeout } else { $DefaultTimeout }
    Start-Proc $jobArgs $label $limit
}

function Start-Proc {
    param([string[]]$ArgList, [string]$Label, [int]$TimeoutSec)

    $all = @()
    if ($state.Serial) { $all += @('-s', $state.Serial) }
    $all += $ArgList

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $state.Adb
    $psi.Arguments              = ($all | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    # NOTE: assign $EventArgs.Data to a local first. "$EventArgs.Data" would
    # interpolate the variable and append the literal text ".Data".
    $outAction = {
        $d = $EventArgs.Data
        if ($d -and "$d".Trim()) { Write-Log "$d"; $state.JobOut.Enqueue("$d") }
    }
    $errAction = {
        # adb writes normal daemon chatter to stderr too, so don't tag it as an error
        $d = $EventArgs.Data
        if ($d -and "$d".Trim()) { Write-Log "  $d"; $state.JobOut.Enqueue("$d") }
    }
    $reg = @(
        (Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outAction),
        (Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $errAction)
    )

    $state.Proc     = $proc   # rooted in $state, so the read events keep firing
    $state.OutReg   = $reg
    $state.Limit    = $TimeoutSec
    $state.Deadline = (Get-Date).AddSeconds($TimeoutSec)
    $state.ExitSeen = $null
    $state.JobOut   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

    $proc.EnableRaisingEvents = $true
    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    Write-Log ('> adb ' + $Label)
}

function Stop-Proc {
    param([string]$Reason)
    $p = $state.Proc
    if ($p -and -not $p.HasExited) { try { $p.Kill(); $p.WaitForExit(2000) | Out-Null } catch {} }
    Write-Log ('  ' + $Reason)
    Complete-Proc
    Complete-Job   # always release the busy flag, or the buttons stay dead forever
}

function Complete-Proc {
    if ($state.OutReg) {
        foreach ($sub in $state.OutReg) {
            try { Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue } catch {}
        }
    }
    $state.OutReg = @()
    if ($state.Proc) { $state.Proc.Dispose() }
    $state.Proc = $null
}

function Complete-Job {
    $state.Busy  = $false
    $state.Jobs  = @()
    $state.Index = 0
    Set-ButtonsEnabled $true
}

function On-Proc-Exit {
    param([int]$Code)
    $label = ($state.Jobs[$state.Index] -join ' ')
    if ($Code -ne 0) { Write-Log ('  (exit code ' + $Code + ')') }

    if ($label -like 'connect *') {
        # adb exits 0 even when it prints "failed to connect", so judge by the
        # captured text rather than the exit code.
        $captured = ($state.JobOut.ToArray() -join ' ')
        if ($Code -eq 0 -and $captured -notmatch '(?i)failed to connect|unable to connect|cannot connect|connection refused|no route to host') {
            $state.Serial = $label.Substring('connect '.Length)
            Write-Log ('  connected to ' + $state.Serial)
        } else {
            $state.Serial = ''
            Write-Log '  NOT connected - check the IP, that ADB Debugging is ON, and that you accepted the prompt on the TV.'
        }
    }
    if ($label -like 'disconnect*' -and $Code -eq 0) { $state.Serial = '' }

    if ($state.FailStep -ge 0 -and $state.Index -eq $state.FailStep -and $Code -ne 0) {
        Write-Log '  (pm install reported a failure - the messages above say why)'
        Complete-Proc
        Complete-Job
        return
    }

    Complete-Proc
    $state.Index++
    Raise-Job
}

# ---------------------------------------------------------------------------
# UI timer - drains the log queue, polls the process, advances the job queue
# ---------------------------------------------------------------------------
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({
    $line = $null
    while ($logQueue.TryDequeue([ref]$line)) { $txtLog.AppendText($line + "`r`n") }

    $p = $state.Proc
    if ($p) {
        if ($p.HasExited) {
            if (-not $state.ExitSeen) { $state.ExitSeen = Get-Date }
            if (((Get-Date) - $state.ExitSeen).TotalMilliseconds -ge 300) {
                On-Proc-Exit $p.ExitCode
            }
        }
        elseif ((Get-Date) -gt $state.Deadline) {
            Stop-Proc ('timed out after ' + $state.Limit + 's - the device may be asleep, unreachable, or the operation is stuck.')
        }
    }
})

# ---------------------------------------------------------------------------
# handlers
# ---------------------------------------------------------------------------
function Connect-Device {
    $ip = $txtIp.Text.Trim()
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Log 'Enter a valid IPv4 address for the Stick.'; return }
    Set-Content -Path $RememberFile -Value $ip -NoNewline
    Start-AdbJob @('connect', ($ip + ':5555'))
}

$btnConnect.Add_Click({ Connect-Device })
$txtIp.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { Connect-Device } })

$btnDisconnect.Add_Click({
    if ($state.Serial) { Start-AdbJob @('disconnect', $state.Serial) } else { Start-AdbJob @('disconnect') }
})

$btnDevices.Add_Click({
    Start-AdbJob @('devices')
    Write-Log "Tip: 'unauthorized' means accept the RSA prompt shown on the TV screen."
})

$btnClear.Add_Click({ $txtLog.Clear() })

function Install-Apk {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log ('File not found: ' + $Path); return }
    if ($Path -notmatch '(?i)\.apk$') { Write-Log ('Not an .apk: ' + $Path); return }
    Start-ApkInstall $Path
}

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Android packages (*.apk)|*.apk|All files (*.*)|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq 'OK') {
        foreach ($f in $dlg.FileNames) { Install-Apk $f }
    }
})

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' }
})
$form.Add_DragDrop({
    $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    foreach ($f in $files) { Install-Apk $f }
})

$form.Add_Shown({
    Write-Log 'Fire TV Sideload starting...'
    try {
        $state.Adb = Ensure-Adb $Log
        Write-Log "Turn on 'ADB Debugging' in the Stick's Developer Options, enter its IP, then Connect."
        Write-Log 'On first connect, accept the RSA prompt on the TV and tick Always allow.'
        Start-AdbJob @('start-server')
    } catch {
        Write-Log ('ERROR preparing adb: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            ('Could not prepare adb.`n`n' + $_.Exception.Message),
            'Fire TV Sideload', 'OK', 'Error') | Out-Null
    }
})

# Clear any stale server left behind by a previous run so a hung connection
# can't block the next one.
if (Test-Path $AdbExe) {
    try { & $AdbExe kill-server 2>&1 | Out-Null } catch {}
}

$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
if ($state.Proc) { try { $state.Proc.Kill() } catch {} }
Get-EventSubscriber | Unregister-Event

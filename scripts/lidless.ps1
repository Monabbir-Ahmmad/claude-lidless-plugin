# Lidless: Windows side. Written for Windows PowerShell 5.1 (powershell.exe).
# Keep this file plain ASCII. lidless.sh starts it from Git Bash.
#
# This script runs from the plugin folder. Everything Lidless remembers lives
# in the state folder, %USERPROFILE%\.claude\lidless, which lidless.sh passes
# as a leading "home=<folder>" argument.
#
#   lidless.ps1 on [sid=<id>] [limit]      turn on for this Claude Code session, or change the limit
#   lidless.ps1 off [all]                  turn off for this session (or every session)
#   lidless.ps1 status                     short status
#   lidless.ps1 setup                      show the one-time boot reset command
#   lidless.ps1 reconcile [sid=<id>]       tidy up after sessions that ended
#   lidless.ps1 monitor                    hidden background watcher
#   lidless.ps1 logon-reset                logon fallback (Startup folder shortcut)
#   lidless.ps1 install-boot-task <dir>    run as administrator, once
#   lidless.ps1 remove-boot-task <dir>     run as administrator
#
# How it works: the three power settings that decide whether a closed lid or an
# idle PC goes to sleep (LIDACTION, STANDBYIDLE, HIBERNATEIDLE, on AC and on
# battery) are saved once per power plan to state\plan-<guid>.txt, set to 0,
# and written back when the last session ends.

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# The state folder: "home=<folder>" when given, else the usual place.
$CmdArgs = @()
$LD = ''
foreach ($a in $args) {
    $t = [string]$a
    if ($LD -eq '' -and $t -like 'home=*') { $LD = $t.Substring(5) } else { $CmdArgs += $t }
}
if (-not $LD -and $env:LIDLESS_HOME) { $LD = $env:LIDLESS_HOME }
if (-not $LD) { $LD = Join-Path (Join-Path $env:USERPROFILE '.claude') 'lidless' }

$sysRoot = $env:SystemRoot
if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
$progFiles = $env:ProgramFiles
if (-not $progFiles) { $progFiles = 'C:\Program Files' }

$ScriptPath  = Join-Path $ScriptDir 'lidless.ps1'
$SessDir     = Join-Path $LD 'sessions'
$RunDir      = Join-Path $LD 'run'
$BusyDir     = Join-Path $LD 'busy'
$StateDir    = Join-Path $LD 'state'
$LogFile     = Join-Path $LD 'lidless.log'
$CfgFile     = Join-Path $LD 'config.json'
$OnFile      = Join-Path $LD 'on'
$MonitorPid  = Join-Path $RunDir 'monitor.pid'
$MonitorErr  = Join-Path $RunDir 'monitor.err'
$BatteryFile = Join-Path $RunDir 'battery'
$PsExe       = Join-Path $sysRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$PowerCfg    = Join-Path $sysRoot 'System32\powercfg.exe'
$BootDir     = Join-Path $progFiles 'Lidless'

# The settings Lidless changes: name, subgroup GUID, setting GUID.
$Settings = @(
    @{ Name = 'LIDACTION';     Sub = '4f971e89-eebd-4455-a8de-9e59040e7347'; Id = '5ca83367-6e45-459f-a27b-476b1d01c936' },
    @{ Name = 'STANDBYIDLE';   Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Id = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' },
    @{ Name = 'HIBERNATEIDLE'; Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Id = '9d7815a6-7ee4-497e-8888-515a05f02364' }
)
$GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

$script:LastReason = ''
$script:StateMutex = $null

# ---------------------------------------------------------------- basics
function Say([string]$text) { [Console]::Out.WriteLine($text) }

function Ensure-Dirs {
    foreach ($d in @($LD, $SessDir, $RunDir, $BusyDir, $StateDir)) {
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    }
    # First use: write the settings file with its defaults, so it is easy to find and edit.
    if (-not (Test-Path -LiteralPath $CfgFile)) {
        Write-Lines $CfgFile @('{', '  "idleMinutes": 0,', '  "batteryFloor": 20,', '  "defaultLimit": 0,', '  "lockOnLidClose": true', '}')
    }
}

# Files that the shell hooks read must end lines with LF, not CRLF.
function Write-Lines([string]$path, [string[]]$lines) {
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"))
}

function Read-FirstLine([string]$path) {
    try {
        $all = [IO.File]::ReadAllLines($path)
        if ($all.Length -gt 0) { return $all[0].Trim() }
    } catch { }
    return ''
}

function Write-Log([string]$text) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $text + "`n"
    try { [IO.File]::AppendAllText($LogFile, $line) } catch { }
}

function Trim-Log {
    try {
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        $all = [IO.File]::ReadAllLines($LogFile)
        if ($all.Length -gt 1000) {
            Write-Lines $LogFile ($all[($all.Length - 500)..($all.Length - 1)])
        }
    } catch { }
}

function Get-Now { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Format-Clock([int64]$epoch) {
    return [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime.ToString('HH:mm')
}

function Format-Dur([int64]$sec) {
    if ($sec -lt 60) { return 'under 1m' }
    $h = [int64][math]::Floor($sec / 3600)
    $m = [int64][math]::Floor((($sec % 3600) + 30) / 60)
    if ($m -eq 60) { $h++; $m = 0 }
    if ($h -gt 0 -and $m -gt 0) { return ('{0}h {1}m' -f $h, $m) }
    if ($h -gt 0) { return ('{0}h' -f $h) }
    return ('{0}m' -f $m)
}

# Returns seconds, 0 for "no limit", -1 for a limit that makes no sense.
# Accepts 3h, 90m, 1h30m, 1h30, 1:30, 1.5h, "2 hours", and a bare number (hours).
function Parse-Limit([string]$text) {
    $t = ($text -replace '\s', '').ToLower()
    if ($t -eq '') { return -1 }
    if (@('0', 'none', 'off', 'no', 'nolimit', 'unlimited', 'false') -contains $t) { return 0 }
    $t = $t -replace 'hours|hour|hrs|hr', 'h'
    $t = $t -replace 'minutes|minute|mins|min', 'm'
    if ($t -match '^(\d+):(\d\d)$') { $t = $Matches[1] + 'h' + $Matches[2] + 'm' }
    if ($t -match '^\d+(\.\d+)?h\d+$') { $t = $t + 'm' }
    $sec = 0.0
    if ($t -match '^\d+(\.\d+)?$') {
        $sec = [double]$t * 3600
    } elseif ($t -match '^(?:(\d+(?:\.\d+)?)h)?(?:(\d+)m)?$') {
        $hh = 0.0; $mm = 0.0
        if ($Matches[1]) { $hh = [double]$Matches[1] }
        if ($Matches[2]) { $mm = [double]$Matches[2] }
        $sec = $hh * 3600 + $mm * 60
    } else {
        return -1
    }
    $n = [int64][math]::Floor($sec + 0.5)
    if ($n -eq 0) { return 0 }
    if ($n -lt 60 -or $n -gt 604800) { return -1 }
    return $n
}

# ~/.claude/lidless/config.json. 0 or false turns a check off.
function Get-Config {
    $c = @{ idleMinutes = 0; batteryFloor = 20; defaultLimit = '0'; lockOnLidClose = $true }
    if (-not (Test-Path -LiteralPath $CfgFile)) { return $c }
    try {
        $j = [IO.File]::ReadAllText($CfgFile) | ConvertFrom-Json
        if ($null -ne $j.idleMinutes) {
            if ($j.idleMinutes -is [bool]) { $c.idleMinutes = 0 }
            elseif ("$($j.idleMinutes)" -match '^\d+$') { $c.idleMinutes = [int]$j.idleMinutes }
        }
        if ($null -ne $j.batteryFloor) {
            if ($j.batteryFloor -is [bool]) { if (-not $j.batteryFloor) { $c.batteryFloor = 0 } }
            elseif ("$($j.batteryFloor)" -match '^\d+$') { $c.batteryFloor = [int]$j.batteryFloor }
        }
        if ($null -ne $j.defaultLimit) {
            if ($j.defaultLimit -is [bool]) { $c.defaultLimit = '0' } else { $c.defaultLimit = "$($j.defaultLimit)" }
        }
        if ($null -ne $j.lockOnLidClose) {
            if ($j.lockOnLidClose -is [bool]) { $c.lockOnLidClose = [bool]$j.lockOnLidClose }
            elseif ("$($j.lockOnLidClose)" -eq '0') { $c.lockOnLidClose = $false }
        }
    } catch { }
    return $c
}

# One lock for everything that changes state, shared by the commands and the watcher.
function Lock-State {
    if ($null -eq $script:StateMutex) {
        $script:StateMutex = New-Object System.Threading.Mutex($false, 'Local\LidlessState')
    }
    try { [void]$script:StateMutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { }
}

function Unlock-State {
    try { if ($null -ne $script:StateMutex) { $script:StateMutex.ReleaseMutex() } } catch { }
}

# Run a program without a window and without PowerShell touching its error stream.
function Invoke-Native([string]$exe, [string]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $out }
}

# ------------------------------------------------------------- processes
# Start time as a file time. Together with the process id it identifies one
# process, so a recycled id is never mistaken for the old Claude Code process.
function Get-StartStamp([int]$procId) {
    try { return (Get-Process -Id $procId -ErrorAction Stop).StartTime.ToFileTimeUtc().ToString() } catch { return '' }
}

function Test-Alive([int]$procId, [string]$stamp) {
    if (-not $stamp) { return $false }
    return ((Get-StartStamp $procId) -eq $stamp)
}

function Test-IsClaude($proc) {
    $name = ([string]$proc.Name).ToLower()
    if ($name -eq 'claude.exe' -or $name -eq 'claude') { return $true }
    if (@('node.exe', 'bun.exe', 'deno.exe') -contains $name) {
        if (([string]$proc.CommandLine) -match 'claude') { return $true }
    }
    return $false
}

# Walk up the parent processes until the Claude Code process is found. 0 means not found.
function Find-Claude {
    $map = @{}
    foreach ($p in (Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate)) {
        $map[[int]$p.ProcessId] = $p
    }
    $cur = [int]$PID
    $hops = 0
    while ($hops -lt 25 -and $map.ContainsKey($cur)) {
        $p = $map[$cur]
        if ($hops -gt 0 -and (Test-IsClaude $p)) { return [int]$p.ProcessId }
        $parent = [int]$p.ParentProcessId
        if ($parent -le 4 -or -not $map.ContainsKey($parent)) { break }
        # A parent that started after its child is not the real parent: the id was reused.
        if ($null -ne $p.CreationDate -and $null -ne $map[$parent].CreationDate -and $map[$parent].CreationDate -gt $p.CreationDate) { break }
        $cur = $parent
        $hops++
    }
    return 0
}

# -------------------------------------------------------------- sessions
# One file per Claude Code process that has Lidless on: sessions\<pid>
function Read-Session([string]$file) {
    $h = @{ pid = ''; start = ''; session_id = ''; since = '0'; deadline = '0'; limit = 'none' }
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $h[$line.Substring(0, $i)] = $line.Substring($i + 1).Trim() }
    }
    return $h
}

function Write-Session($s) {
    Write-Lines (Join-Path $SessDir ([string]$s.pid)) @(
        "pid=$($s.pid)", "start=$($s.start)", "session_id=$($s.session_id)",
        "since=$($s.since)", "deadline=$($s.deadline)", "limit=$($s.limit)"
    )
}

function Get-Sessions {
    $list = @()
    if (Test-Path -LiteralPath $SessDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $SessDir -File)) {
            if ($f.Name -match '^\d+$') {
                try { $list += , (Read-Session $f.FullName) } catch { }
            }
        }
    }
    return , $list
}

function Remove-Quiet([string]$path) {
    try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } } catch { }
}

function End-Session($s, [string]$reason) {
    $base = Join-Path $SessDir ([string]$s.pid)
    Remove-Quiet $base
    Remove-Quiet "$base.end"
    Remove-Quiet (Join-Path $RunDir ("warned." + $s.pid))
    if ($s.session_id -match '^[A-Za-z0-9_-]+$') { Remove-Quiet (Join-Path $BusyDir $s.session_id) }
    Write-Log ("OFF  session {0}: {1}" -f $s.pid, $reason)
    $script:LastReason = $reason
}

# Busy or idle for one session, from the marker the hooks write.
function Get-BusyState([string]$sid) {
    $mark = $null
    if ($sid -match '^[A-Za-z0-9_-]+$') {
        $candidate = Join-Path $BusyDir $sid
        if (Test-Path -LiteralPath $candidate) { $mark = Get-Item -LiteralPath $candidate }
    } elseif (Test-Path -LiteralPath $BusyDir) {
        # The session id is not known. Use the most recent marker there is.
        $mark = Get-ChildItem -LiteralPath $BusyDir -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    }
    if ($null -eq $mark) {
        # Nothing recorded yet: assume busy, which never triggers the idle rule.
        return @{ State = 'busy'; Since = (Get-Now) }
    }
    $state = Read-FirstLine $mark.FullName
    if (@('busy', 'waiting', 'idle') -notcontains $state) { $state = 'busy' }
    $since = [int64]([DateTimeOffset]$mark.LastWriteTimeUtc).ToUnixTimeSeconds()
    return @{ State = $state; Since = $since }
}

function Get-Battery {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $st = [System.Windows.Forms.SystemInformation]::PowerStatus
        if (($st.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) -ne 0) {
            return @{ Percent = -1; Source = 'none' }
        }
        $pct = [int][math]::Round($st.BatteryLifePercent * 100)
        if ($pct -lt 0 -or $pct -gt 100) { return @{ Percent = -1; Source = 'none' } }
        $src = 'ac'
        if ($st.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline) { $src = 'battery' }
        return @{ Percent = $pct; Source = $src }
    } catch {
        return @{ Percent = -1; Source = 'none' }
    }
}

# Drop sessions that ended. With $full also apply the limit, battery floor and idle rule.
function Invoke-Sweep([bool]$full, $cfg, $bat) {
    $now = Get-Now
    foreach ($s in (Get-Sessions)) {
        $base = Join-Path $SessDir ([string]$s.pid)
        if (Test-Path -LiteralPath "$base.end") {
            $why = Read-FirstLine "$base.end"
            if (-not $why) { $why = 'exit' }
            End-Session $s "the session ended ($why)"
            continue
        }
        if (-not (Test-Alive ([int]$s.pid) $s.start)) {
            End-Session $s 'Claude Code is no longer running'
            continue
        }
        if (-not $full) { continue }
        $deadline = [int64]$s.deadline
        if ($deadline -gt 0 -and $now -ge $deadline) {
            End-Session $s "time limit reached ($($s.limit))"
            continue
        }
        if ($cfg.batteryFloor -gt 0 -and $bat.Source -eq 'battery' -and $bat.Percent -ge 0 -and $bat.Percent -le $cfg.batteryFloor) {
            End-Session $s ("battery at {0}% on battery power (floor {1}%)" -f $bat.Percent, $cfg.batteryFloor)
            continue
        }
        if ($cfg.idleMinutes -gt 0) {
            $b = Get-BusyState $s.session_id
            if ($b.State -eq 'idle' -and ($now - $b.Since) -ge ($cfg.idleMinutes * 60)) {
                End-Session $s ("Claude was idle for {0} minutes" -f $cfg.idleMinutes)
                continue
            }
        }
    }
}

# --------------------------------------------------------- power settings
function Get-ActivePlan {
    $r = Invoke-Native $PowerCfg '/getactivescheme'
    if ($r.Out -match "($GuidPattern)") { return $Matches[1].ToLower() }
    return ''
}

# Current AC and DC values of one setting, or $null when the plan does not have it.
# powercfg prints them last, as 0x........ numbers, in every display language.
function Read-Setting([string]$plan, $setting) {
    $r = Invoke-Native $PowerCfg ("/qh {0} {1} {2}" -f $plan, $setting.Sub, $setting.Id)
    if ($r.Code -ne 0) { return $null }
    $m = [regex]::Matches($r.Out, '0x([0-9a-fA-F]{8})')
    if ($m.Count -lt 2) { return $null }
    $ac = [Convert]::ToInt64($m[$m.Count - 2].Groups[1].Value, 16)
    $dc = [Convert]::ToInt64($m[$m.Count - 1].Groups[1].Value, 16)
    return @($ac, $dc)
}

function Write-Setting([string]$plan, $setting, [int64]$ac, [int64]$dc) {
    [void](Invoke-Native $PowerCfg ("/setacvalueindex {0} {1} {2} {3}" -f $plan, $setting.Sub, $setting.Id, $ac))
    [void](Invoke-Native $PowerCfg ("/setdcvalueindex {0} {1} {2} {3}" -f $plan, $setting.Sub, $setting.Id, $dc))
}

function Get-PlanFile([string]$plan) { return (Join-Path $StateDir ("plan-{0}.txt" -f $plan)) }

# Save the original values of a plan, once. An existing state file is never overwritten.
function Save-Plan([string]$plan) {
    $file = Get-PlanFile $plan
    if (Test-Path -LiteralPath $file) { return $true }
    $lines = @()
    foreach ($s in $Settings) {
        $v = Read-Setting $plan $s
        if ($null -ne $v) { $lines += ('{0} {1} {2}' -f $s.Name, $v[0], $v[1]) }
    }
    if ($lines.Count -eq 0) { return $false }
    Write-Lines $file $lines
    return $true
}

# Lid close does nothing, no sleep after idle, no hibernate after idle. The display timeout is not touched.
function Set-PlanAwake([string]$plan) {
    foreach ($s in $Settings) { Write-Setting $plan $s 0 0 }
    [void](Invoke-Native $PowerCfg ("/setactive {0}" -f $plan))
}

function Test-PlanAwake([string]$plan) {
    $v = Read-Setting $plan $Settings[0]
    return ($null -ne $v -and $v[0] -eq 0 -and $v[1] -eq 0)
}

function Test-StateLeft {
    if (-not (Test-Path -LiteralPath $StateDir)) { return $false }
    return (@(Get-ChildItem -LiteralPath $StateDir -Filter 'plan-*.txt' -File).Count -gt 0)
}

function Get-ShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Lidless reset.lnk')
}

# Logon fallback: a Startup folder shortcut that restores the settings and deletes itself.
function Add-LogonShortcut {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Get-ShortcutPath))
        $lnk.TargetPath = $PsExe
        $lnk.Arguments = ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" "home={1}" logon-reset' -f $ScriptPath, $LD)
        $lnk.WindowStyle = 7
        $lnk.Description = 'Puts normal sleep settings back if Lidless was on when the PC went down.'
        $lnk.Save()
    } catch {
        Write-Log ("NOTE could not create the logon fallback shortcut: " + $_.Exception.Message)
    }
}

function Remove-LogonShortcut { Remove-Quiet (Get-ShortcutPath) }

# Write every saved value back to every plan Lidless changed, then forget the saved state.
function Restore-All([string]$why) {
    $had = $false
    if (Test-Path -LiteralPath $StateDir) {
        $active = Get-ActivePlan
        foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter 'plan-*.txt' -File)) {
            if ($f.Name -notmatch "^plan-($GuidPattern)\.txt$") { continue }
            $plan = $Matches[1].ToLower()
            $had = $true
            foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
                if ($line -match '^(LIDACTION|STANDBYIDLE|HIBERNATEIDLE) (\d{1,10}) (\d{1,10})$') {
                    $name = $Matches[1]; $ac = [int64]$Matches[2]; $dc = [int64]$Matches[3]
                    foreach ($s in $Settings) { if ($s.Name -eq $name) { Write-Setting $plan $s $ac $dc } }
                }
            }
            if ($plan -eq $active) { [void](Invoke-Native $PowerCfg ("/setactive {0}" -f $plan)) }
            Remove-Quiet $f.FullName
        }
    }
    Remove-LogonShortcut
    $wasOn = Test-Path -LiteralPath $OnFile
    Remove-Quiet $OnFile
    Remove-Quiet $BatteryFile
    foreach ($dir in @($BusyDir)) {
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File)) { Remove-Quiet $f.FullName }
        }
    }
    if (Test-Path -LiteralPath $RunDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $RunDir -Filter 'warned.*' -File)) { Remove-Quiet $f.FullName }
    }
    if ($had -or $wasOn) { Write-Log ("RESTORED normal sleep behaviour: " + $why) }
}

# ---------------------------------------------------------------- watcher
$WatcherSource = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Lidless
{
    // A window that is never shown. Windows sends it a message when the lid
    // opens or closes, and when the user signs out or the PC shuts down.
    public class Watcher : NativeWindow, IDisposable
    {
        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PowerBroadcastSetting
        {
            public Guid PowerSetting;
            public uint DataLength;
            public byte Data;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid powerSettingGuid, int flags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool LockWorkStation();

        [DllImport("powrprof.dll")]
        private static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr hMem);

        // GUID_LIDSWITCH_STATE_CHANGE
        private static readonly Guid LidSwitch = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
        private const int WM_POWERBROADCAST = 0x0218;
        private const int PBT_POWERSETTINGCHANGE = 0x8013;
        private const int WM_ENDSESSION = 0x0016;

        private IntPtr registration = IntPtr.Zero;

        public bool LockOnClose = true;
        public int LidState = -1;      // -1 unknown, 0 closed, 1 open
        public int CloseCount = 0;
        public int LockFailCount = 0;
        public event EventHandler SessionEnding;

        public Watcher()
        {
            CreateParams cp = new CreateParams();
            cp.Caption = "Lidless";
            CreateHandle(cp);
            Guid g = LidSwitch;
            registration = RegisterPowerSettingNotification(Handle, ref g, 0);
        }

        public bool Registered { get { return registration != IntPtr.Zero; } }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt64() == PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
            {
                PowerBroadcastSetting s = (PowerBroadcastSetting)Marshal.PtrToStructure(m.LParam, typeof(PowerBroadcastSetting));
                if (s.PowerSetting == LidSwitch)
                {
                    int state = (s.Data == 0) ? 0 : 1;
                    if (state == 0 && LidState != 0)
                    {
                        CloseCount++;
                        // Lock right here, so it happens the moment the lid closes.
                        if (LockOnClose && !LockWorkStation()) { LockFailCount++; }
                    }
                    LidState = state;
                }
            }
            else if (m.Msg == WM_ENDSESSION && m.WParam != IntPtr.Zero)
            {
                EventHandler handler = SessionEnding;
                if (handler != null)
                {
                    try { handler(this, EventArgs.Empty); } catch (Exception) { }
                }
            }
            base.WndProc(ref m);
        }

        public static string ActiveScheme()
        {
            IntPtr p;
            if (PowerGetActiveScheme(IntPtr.Zero, out p) != 0 || p == IntPtr.Zero) { return ""; }
            try
            {
                Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
                return g.ToString().ToLowerInvariant();
            }
            finally
            {
                LocalFree(p);
            }
        }

        public void Dispose()
        {
            if (registration != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(registration);
                registration = IntPtr.Zero;
            }
            DestroyHandle();
        }
    }
}
'@

function Test-MonitorAlive {
    if (-not (Test-Path -LiteralPath $MonitorPid)) { return $false }
    $parts = (Read-FirstLine $MonitorPid).Split('|')
    if ($parts.Length -ne 2 -or $parts[0] -notmatch '^\d+$') { return $false }
    return (Test-Alive ([int]$parts[0]) $parts[1])
}

# Start the hidden watcher and wait until it reports that it is up.
function Start-Monitor {
    if (Test-MonitorAlive) { return $true }
    Remove-Quiet $MonitorPid
    Remove-Quiet $MonitorErr
    $arguments = ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" "home={1}" monitor' -f $ScriptPath, $LD)
    # Start-Process gives the watcher its own hidden console, so it does not die with this terminal.
    Start-Process -FilePath $PsExe -ArgumentList $arguments -WindowStyle Hidden
    for ($i = 0; $i -lt 100; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-Path -LiteralPath $MonitorErr) { return $false }
        if (Test-MonitorAlive) { return $true }
    }
    return $false
}

# Reapply the settings when the active power plan changed (OEM tools, plugging
# in, unplugging), or when something wrote the old values back.
function Update-PlanState {
    $plan = ''
    try { $plan = [Lidless.Watcher]::ActiveScheme() } catch { $plan = '' }
    if (-not $plan) {
        if (($script:Tick % 5) -ne 0) { return }
        $plan = Get-ActivePlan
    }
    if (-not $plan) { return }
    if ($script:Ending) { return }
    if (-not (Test-Path -LiteralPath (Get-PlanFile $plan))) {
        if (Save-Plan $plan) {
            Set-PlanAwake $plan
            Write-Log ("NOTE the active power plan changed, Lidless settings were applied to the new plan ({0})" -f $plan)
        }
        return
    }
    if (($script:Tick % 10) -eq 0) {
        $drift = $false
        foreach ($s in @($Settings[0], $Settings[1])) {
            $v = Read-Setting $plan $s
            if ($null -ne $v -and ($v[0] -ne 0 -or $v[1] -ne 0)) { $drift = $true }
        }
        if ($drift) {
            Set-PlanAwake $plan
            Write-Log 'NOTE something changed the sleep settings back while Lidless is on, they were applied again'
        }
    }
}

function Invoke-MonitorTick {
    if ($script:Ending) { return }
    try {
        $script:Tick++
        $cfg = Get-Config
        $script:Watcher.LockOnClose = [bool]$cfg.lockOnLidClose

        if ($script:Watcher.CloseCount -gt $script:SeenCloses) {
            $script:SeenCloses = $script:Watcher.CloseCount
            if (-not $cfg.lockOnLidClose) {
                Write-Log 'LID  closed (lockOnLidClose is off)'
            } elseif ($script:Watcher.LockFailCount -gt $script:SeenFails) {
                $script:SeenFails = $script:Watcher.LockFailCount
                Write-Log 'LID  closed, but Windows refused to lock the screen'
            } else {
                Write-Log 'LID  closed, screen locked'
            }
        }

        $bat = Get-Battery
        $done = $false
        Lock-State
        try {
            Invoke-Sweep $true $cfg $bat
            if ((Get-Sessions).Count -eq 0) {
                $why = $script:LastReason
                if (-not $why) { $why = 'no session is using it' }
                Restore-All $why
                Remove-Quiet $MonitorPid
                $done = $true
            } elseif (-not $script:Ending) {
                Update-PlanState
            }
        } finally {
            Unlock-State
        }
        if ($script:Ending) { return }
        if ($done) {
            $script:Timer.Stop()
            [System.Windows.Forms.Application]::ExitThread()
            return
        }

        # The prompt hook reads this to warn before the battery floor is reached.
        if ($bat.Source -eq 'none') {
            Write-Lines $BatteryFile @("none none $($cfg.batteryFloor)")
        } else {
            Write-Lines $BatteryFile @("$($bat.Percent) $($bat.Source) $($cfg.batteryFloor)")
        }
    } catch {
        $script:TickErrors++
        if ($script:TickErrors -le 5) { Write-Log ("NOTE watcher error: " + $_.Exception.Message) }
    }
}

function Start-MonitorLoop {
    Ensure-Dirs
    $created = $false
    $single = New-Object System.Threading.Mutex($true, 'Local\LidlessMonitor', [ref]$created)
    if (-not $created) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -TypeDefinition $WatcherSource -ReferencedAssemblies 'System.Windows.Forms'

        $script:Tick = 0
        $script:Ending = $false
        $script:TickErrors = 0
        $script:SeenCloses = 0
        $script:SeenFails = 0
        $script:Watcher = New-Object Lidless.Watcher
        $script:Watcher.LockOnClose = [bool](Get-Config).lockOnLidClose
        if (-not $script:Watcher.Registered) {
            Write-Log 'NOTE Windows would not register for lid events, so the screen will not lock on lid close'
        }

        # Sign-out, restart and shutdown: put the settings back before the PC goes down.
        $script:Watcher.add_SessionEnding([EventHandler] {
            $script:Ending = $true
            try {
                Lock-State
                foreach ($s in (Get-Sessions)) { End-Session $s 'Windows is shutting down or signing out' }
                Restore-All 'Windows is shutting down or signing out'
            } catch { } finally { Unlock-State }
        })

        $script:Timer = New-Object System.Windows.Forms.Timer
        $script:Timer.Interval = 3000
        $script:Timer.add_Tick({ Invoke-MonitorTick })
        $script:Timer.Start()

        Write-Lines $MonitorPid @(("{0}|{1}" -f $PID, (Get-StartStamp $PID)))
        [System.Windows.Forms.Application]::Run()
    } catch {
        $msg = $_.Exception.Message
        try { Write-Lines $MonitorErr @($msg) } catch { }
        Write-Log ("NOTE the watcher could not start: " + $msg)
    } finally {
        try { if ($null -ne $script:Watcher) { $script:Watcher.Dispose() } } catch { }
        try { $single.ReleaseMutex() } catch { }
    }
}

# --------------------------------------------------------------- commands
function Get-UserTag([string]$dir) {
    $leaf = ''
    try { $leaf = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $dir)) } catch { $leaf = '' }
    if (-not $leaf) { $leaf = 'user' }
    return ($leaf -replace '[^A-Za-z0-9_-]', '_')
}

function Get-BootMarker([string]$dir) { return (Join-Path $BootDir ("installed-{0}.txt" -f (Get-UserTag $dir))) }

function Test-BootReset { return (Test-Path -LiteralPath (Get-BootMarker $LD)) }

function Get-BatteryLine($bat, $cfg) {
    if ($bat.Source -eq 'none') { return '' }
    if ($bat.Source -eq 'battery') {
        if ($cfg.batteryFloor -gt 0) { return ("Battery: {0}%, on battery. Lidless turns off at {1}%." -f $bat.Percent, $cfg.batteryFloor) }
        return ("Battery: {0}%, on battery. The battery floor is off." -f $bat.Percent)
    }
    return ("Battery: {0}%, plugged in." -f $bat.Percent)
}

function Split-Args($list) {
    $sid = ''
    $spec = ''
    $all = $false
    foreach ($a in $list) {
        $t = [string]$a
        if ($t -match '^sid=(.*)$') { $sid = $Matches[1] }
        elseif (@('all', '--all', '-a') -contains $t) { $all = $true; $spec += $t }
        else { $spec += $t }
    }
    if ($sid -notmatch '^[A-Za-z0-9_-]+$') { $sid = '' }
    return @{ Sid = $sid; Spec = $spec; All = $all }
}

function Invoke-On($list) {
    Ensure-Dirs
    $a = Split-Args $list
    $cfg = Get-Config
    $spec = $a.Spec

    $claude = Find-Claude
    if ($claude -le 0) {
        Say 'Lidless could not find the Claude Code process that ran this command, so it has no session to tie itself to.'
        Say 'Run /lidless from inside Claude Code.'
        return
    }
    $stamp = Get-StartStamp $claude

    $plus = $false
    $secs = $null
    if ($spec -ne '') {
        if ($spec.StartsWith('+')) { $plus = $true; $spec = $spec.Substring(1) }
        $secs = Parse-Limit $spec
        if ($secs -lt 0) {
            Say ('Invalid limit "{0}". Use something like 3h, 90m or 1h30m, or a plain number of hours. Use 0 for no limit.' -f $spec)
            return
        }
    }

    $now = Get-Now
    $file = Join-Path $SessDir ([string]$claude)
    $isNew = $false
    $message = @()

    Lock-State
    try {
        Invoke-Sweep $false $cfg $null

        if (Test-Path -LiteralPath $file) {
            # ---- already on for this session: only the limit can change
            $s = Read-Session $file
            $old = [int64]$s.deadline
            $new = $old
            $label = $s.limit
            $nothing = $false
            if ($null -ne $secs) {
                if ($secs -eq 0) { $new = 0; $label = 'none' }
                elseif ($plus) {
                    if ($old -gt 0) { $new = $old + $secs; $label = ($s.limit + ' + ' + (Format-Dur $secs)) }
                    else { $nothing = $true }
                } else { $new = $now + $secs; $label = (Format-Dur $secs) }
            }
            if ($a.Sid) { $s.session_id = $a.Sid }
            $s.deadline = [string]$new
            $s.limit = $label
            Write-Session $s
            if ($new -ne $old) {
                Remove-Quiet (Join-Path $RunDir ("warned." + $claude))
                if ($new -gt 0) { Write-Log ("LIMIT session {0}: now {1} left" -f $claude, (Format-Dur ($new - $now))) }
                else { Write-Log ("LIMIT session {0}: limit removed" -f $claude) }
            }
            if ($nothing) { $message += 'There is no time limit on this session, so there is nothing to extend.' }
            elseif ($new -ne $old -and $new -gt 0) { $message += ("Lidless time limit updated: {0} left, until {1}." -f (Format-Dur ($new - $now)), (Format-Clock $new)) }
            elseif ($new -ne $old) { $message += 'Lidless time limit removed. It stays on until this session ends.' }
            elseif ($new -gt 0) { $message += ("Lidless is already on for this session: {0} left, until {1}." -f (Format-Dur ($new - $now)), (Format-Clock $new)) }
            else { $message += 'Lidless is already on for this session, with no time limit.' }
        } else {
            # ---- turning on for this session
            $isNew = $true
            if ((Get-Sessions).Count -eq 0 -and (Test-StateLeft)) {
                Restore-All 'leftover state from an earlier run'
            }
            $plan = Get-ActivePlan
            if (-not $plan) {
                Say 'Lidless could not read the active Windows power plan (powercfg /getactivescheme gave nothing), so it did not turn on.'
                return
            }
            if (-not (Save-Plan $plan)) {
                Say 'Lidless could not read the lid and sleep settings of the active power plan, so it did not turn on.'
                return
            }
            Set-PlanAwake $plan
            if (-not (Test-PlanAwake $plan)) {
                if ((Get-Sessions).Count -eq 0) { Restore-All 'Windows did not accept the change' }
                Say 'Windows did not accept the power setting change. A company policy may be locking the power settings. Lidless did not turn on.'
                return
            }

            $note = ''
            if ($null -eq $secs) {
                $secs = Parse-Limit $cfg.defaultLimit
                if ($secs -lt 0) { $secs = 0; $note = 'Note: defaultLimit in config.json is not a valid limit, so no limit was set.' }
            }
            $deadline = 0
            $label = 'none'
            if ($secs -gt 0) { $deadline = $now + $secs; $label = (Format-Dur $secs) }

            Write-Session @{ pid = $claude; start = $stamp; session_id = $a.Sid; since = $now; deadline = $deadline; limit = $label }
            # This command runs inside a turn, so the session is busy right now.
            if ($a.Sid) { Write-Lines (Join-Path $BusyDir $a.Sid) @('busy') }
            Write-Lines $OnFile @('on')
            Add-LogonShortcut
            Trim-Log
            Write-Log ("ON   session {0}: limit {1}" -f $claude, $label)

            $message += 'Lidless is ON for this session.'
            if ($cfg.lockOnLidClose) { $message += 'Closing the lid will not put the laptop to sleep. The screen locks when the lid closes.' }
            else { $message += 'Closing the lid will not put the laptop to sleep. Locking on lid close is switched off in the settings.' }
            if ($deadline -gt 0) { $message += ("Time limit: {0}, until {1}." -f $label, (Format-Clock $deadline)) }
            else { $message += 'Time limit: none. It stays on until this session ends.' }
            $bl = Get-BatteryLine (Get-Battery) $cfg
            if ($bl) { $message += $bl }
            $count = (Get-Sessions).Count
            if ($count -gt 1) { $message += ("{0} sessions are using Lidless now." -f $count) }
            if ($note) { $message += $note }
        }
    } finally {
        Unlock-State
    }

    # The watcher is what resets everything when Claude Code goes away, so Lidless must not stay on without it.
    if (-not (Start-Monitor)) {
        $why = Read-FirstLine $MonitorErr
        Lock-State
        try {
            foreach ($s in (Get-Sessions)) { End-Session $s 'the background watcher could not start' }
            Restore-All 'the background watcher could not start'
        } finally { Unlock-State }
        Say 'Lidless could not start its background watcher, so it turned itself off again and put the sleep settings back.'
        if ($why) { Say ("Reason: " + $why) }
        return
    }

    foreach ($line in $message) { Say $line }

    if ($isNew -and -not (Test-BootReset)) {
        $flag = Join-Path $LD 'setup-reminded'
        if (-not (Test-Path -LiteralPath $flag)) {
            Write-Lines $flag @('1')
            Say 'Tip, shown once: the boot-time reset is not set up yet. Run /lidless-setup to see the one-time command.'
        }
    }
}

function Invoke-Off($list) {
    Ensure-Dirs
    $a = Split-Args $list
    $cfg = Get-Config
    $message = @()
    Lock-State
    try {
        Invoke-Sweep $false $cfg $null
        $before = (Get-Sessions).Count
        if ($a.All) {
            foreach ($s in (Get-Sessions)) { End-Session $s 'turned off by the user (all sessions)' }
        } else {
            $claude = Find-Claude
            if ($claude -le 0) {
                Say 'Lidless could not find the Claude Code process that ran this command.'
                Say 'To turn it off for every session, run /lidless-off all.'
                return
            }
            $file = Join-Path $SessDir ([string]$claude)
            if (Test-Path -LiteralPath $file) {
                End-Session (Read-Session $file) 'turned off by the user'
            } elseif ($before -gt 0) {
                Say ("Lidless is not on for this session. {0} other session(s) still have it on." -f $before)
                Say 'To turn it off everywhere, run /lidless-off all.'
                return
            }
        }
        $left = (Get-Sessions).Count
        if ($left -eq 0) {
            $why = $script:LastReason
            if (-not $why) { $why = 'turned off by the user' }
            Restore-All $why
            if ($before -gt 0) { $message += 'Lidless is OFF. Normal sleep behaviour is back, so closing the lid sleeps the laptop again.' }
            else { $message += 'Lidless is already off. Sleep behaviour is normal.' }
        } else {
            $message += ("Lidless is off for this session. {0} other session(s) still keep the laptop awake." -f $left)
            $message += 'To turn it off everywhere, run /lidless-off all.'
        }
    } finally {
        Unlock-State
    }
    foreach ($line in $message) { Say $line }
}

function Invoke-Status {
    Ensure-Dirs
    $cfg = Get-Config
    $now = Get-Now
    $claude = Find-Claude
    $count = 0
    $mine = $null
    foreach ($s in (Get-Sessions)) {
        if (-not (Test-Alive ([int]$s.pid) $s.start)) { continue }
        $count++
        if ([int]$s.pid -eq $claude) { $mine = $s }
    }

    if ($count -eq 1) { Say 'Lidless: ON (1 session)' }
    elseif ($count -gt 1) { Say ("Lidless: ON ({0} sessions)" -f $count) }
    else { Say 'Lidless: OFF' }

    if ($null -ne $mine) {
        $deadline = [int64]$mine.deadline
        if ($deadline -gt 0) { Say ("This session: on, {0} left (until {1})" -f (Format-Dur ($deadline - $now)), (Format-Clock $deadline)) }
        else { Say 'This session: on, no time limit' }
    } else {
        Say 'This session: off'
    }

    $bat = Get-Battery
    $floor = 'floor off'
    if ($cfg.batteryFloor -gt 0) { $floor = ("floor {0}%" -f $cfg.batteryFloor) }
    if ($bat.Source -eq 'none') { Say 'Battery: none found' }
    elseif ($bat.Source -eq 'battery') { Say ("Battery: {0}%, on battery ({1})" -f $bat.Percent, $floor) }
    else { Say ("Battery: {0}%, plugged in ({1})" -f $bat.Percent, $floor) }

    if ($null -ne $mine) {
        $b = Get-BusyState $mine.session_id
        if ($b.State -eq 'idle') { Say ("Claude: idle for {0}" -f (Format-Dur ($now - $b.Since))) }
        elseif ($b.State -eq 'waiting') { Say 'Claude: waiting on background work (counts as busy)' }
        else { Say 'Claude: busy' }
    } else {
        Say 'Claude: not tracked while Lidless is off here'
    }

    if (Test-BootReset) { Say 'Boot reset: installed' } else { Say 'Boot reset: not installed (run /lidless-setup)' }

    $idle = 'off'
    if ($cfg.idleMinutes -gt 0) { $idle = ("{0}m" -f $cfg.idleMinutes) }
    $fl = 'off'
    if ($cfg.batteryFloor -gt 0) { $fl = ("{0}%" -f $cfg.batteryFloor) }
    $dl = Parse-Limit $cfg.defaultLimit
    if ($dl -lt 0) { $dlText = 'invalid' } elseif ($dl -eq 0) { $dlText = 'none' } else { $dlText = Format-Dur $dl }
    $lk = 'off'
    if ($cfg.lockOnLidClose) { $lk = 'on' }
    Say ("Settings: idle off-switch {0}, battery floor {1}, default limit {2}, lock on lid close {3}" -f $idle, $fl, $dlText, $lk)

    $last = ''
    try {
        if (Test-Path -LiteralPath $LogFile) {
            $all = [IO.File]::ReadAllLines($LogFile)
            if ($all.Length -gt 0) { $last = $all[$all.Length - 1] }
        }
    } catch { }
    if ($last) { Say ("Last event: " + $last) } else { Say 'Last event: none yet' }
}

# Called at every Claude Code start (SessionStart hook).
function Invoke-Reconcile($list) {
    Ensure-Dirs
    $a = Split-Args $list
    $cfg = Get-Config
    $needMonitor = $false
    Lock-State
    try {
        Invoke-Sweep $false $cfg $null
        if ((Get-Sessions).Count -eq 0) {
            if ((Test-StateLeft) -or (Test-Path -LiteralPath $OnFile)) {
                $why = $script:LastReason
                if (-not $why) { $why = 'leftover state from an earlier run' }
                Restore-All $why
            }
        } else {
            # /clear and /resume start a new conversation inside the same Claude
            # process. Follow the new session id so busy and idle keep working.
            if ($a.Sid) {
                $claude = Find-Claude
                $file = Join-Path $SessDir ([string]$claude)
                if ($claude -gt 0 -and (Test-Path -LiteralPath $file)) {
                    $s = Read-Session $file
                    if ($s.session_id -ne $a.Sid) {
                        if ($s.session_id -match '^[A-Za-z0-9_-]+$') { Remove-Quiet (Join-Path $BusyDir $s.session_id) }
                        $s.session_id = $a.Sid
                        Write-Session $s
                        $mark = Join-Path $BusyDir $a.Sid
                        if (-not (Test-Path -LiteralPath $mark)) { Write-Lines $mark @('idle') }
                    }
                }
            }
            Write-Lines $OnFile @('on')
            $needMonitor = $true
        }
    } finally {
        Unlock-State
    }
    if ($needMonitor) { [void](Start-Monitor) }
}

# Startup folder fallback. Runs at logon, restores if needed, then removes its own shortcut.
function Invoke-LogonReset {
    Ensure-Dirs
    $cfg = Get-Config
    Lock-State
    try {
        Invoke-Sweep $false $cfg $null
        if ((Get-Sessions).Count -eq 0) {
            if ((Test-StateLeft) -or (Test-Path -LiteralPath $OnFile)) { Restore-All 'reset at logon after the PC went down with Lidless on' }
            Remove-LogonShortcut
        }
    } finally {
        Unlock-State
    }
}

function Invoke-Setup {
    $tag = Get-UserTag $LD
    $cmdLine = ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" install-boot-task "{1}"' -f $ScriptPath, $LD)
    $undo = ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" remove-boot-task "{1}"' -f $ScriptPath, $LD)
    if (Test-BootReset) {
        Say 'The boot-time reset is already installed on this PC.'
        Say 'To remove it, open PowerShell as administrator and run:'
        Say ''
        Say ('  ' + $undo)
        return
    }
    Say 'Boot-time reset: not installed.'
    Say 'Open PowerShell as administrator (right-click Start, then "Terminal (Admin)") and run this once:'
    Say ''
    Say ('  ' + $cmdLine)
    Say ''
    Say ('It adds a Task Scheduler task named "Lidless Boot Reset - {0}" that runs at startup as SYSTEM.' -f $tag)
    Say 'If Lidless was on when the PC went down, the task puts your sleep settings back before anyone logs in.'
    Say 'Without it, Lidless still resets at logon and at the next Claude Code start.'
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TaskName([string]$dir) { return ("Lidless Boot Reset - {0}" -f (Get-UserTag $dir)) }

function Install-BootTask($list) {
    if (-not (Test-Admin)) {
        Say 'This needs an administrator PowerShell. Right-click Start, choose "Terminal (Admin)" or "Windows PowerShell (Admin)", and run the command again.'
        return
    }
    $userDir = $LD
    if ($list.Count -gt 0 -and $list[0]) { $userDir = [string]$list[0] }
    if (-not [IO.Path]::IsPathRooted($userDir) -or -not (Test-Path -LiteralPath $userDir -PathType Container)) {
        Say ("The Lidless folder was not found: " + $userDir)
        return
    }
    $source = Join-Path $ScriptDir 'boot-reset.ps1'
    if (-not (Test-Path -LiteralPath $source)) {
        Say ("boot-reset.ps1 is missing next to this script: " + $source)
        return
    }
    # The task runs as SYSTEM, so its script must live where only administrators can change it.
    if (-not (Test-Path -LiteralPath $BootDir)) { [void](New-Item -ItemType Directory -Path $BootDir -Force) }
    $target = Join-Path $BootDir 'boot-reset.ps1'
    Copy-Item -LiteralPath $source -Destination $target -Force

    $stateDir = Join-Path $userDir 'state'
    $taskArgs = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" "{1}"' -f $target, $stateDir)
    $action = New-ScheduledTaskAction -Execute $PsExe -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $name = Get-TaskName $userDir
    [void](Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Lidless: puts sleep settings back at startup if Lidless was on when the PC went down.' -Force)
    Write-Lines (Get-BootMarker $userDir) @($stateDir)

    Say ('Done. Task "{0}" is installed and runs at every startup as SYSTEM.' -f $name)
    Say ("Its script is " + $target)
}

function Remove-BootTask($list) {
    if (-not (Test-Admin)) {
        Say 'This needs an administrator PowerShell. Right-click Start, choose "Terminal (Admin)" or "Windows PowerShell (Admin)", and run the command again.'
        return
    }
    $userDir = $LD
    if ($list.Count -gt 0 -and $list[0]) { $userDir = [string]$list[0] }
    $name = Get-TaskName $userDir
    try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop } catch { }
    Remove-Quiet (Get-BootMarker $userDir)
    if (Test-Path -LiteralPath $BootDir) {
        if (@(Get-ChildItem -LiteralPath $BootDir -Filter 'installed-*.txt' -File).Count -eq 0) {
            try { Remove-Item -LiteralPath $BootDir -Recurse -Force } catch { }
        }
    }
    Say ('Removed the task "{0}".' -f $name)
}

# ------------------------------------------------------------------ main
if ($env:LIDLESS_PS_TEST -eq '1') { return }

$cmd = 'status'
$rest = @()
if ($CmdArgs.Count -gt 0) { $cmd = [string]$CmdArgs[0] }
if ($CmdArgs.Count -gt 1) { $rest = @($CmdArgs[1..($CmdArgs.Count - 1)]) }

$quiet = (@('reconcile', 'monitor', 'logon-reset') -contains $cmd)
try {
    switch ($cmd) {
        'on'                { Invoke-On $rest }
        'off'               { Invoke-Off $rest }
        'status'            { Invoke-Status }
        'setup'             { Invoke-Setup }
        'reconcile'         { Invoke-Reconcile $rest }
        'monitor'           { Start-MonitorLoop }
        'logon-reset'       { Invoke-LogonReset }
        'install-boot-task' { Install-BootTask $rest }
        'remove-boot-task'  { Remove-BootTask $rest }
        default             { Say 'Lidless commands: /lidless [limit], /lidless-off, /lidless-status, /lidless-setup' }
    }
} catch {
    $text = $_.Exception.Message
    Write-Log ("NOTE error in '{0}': {1}" -f $cmd, $text)
    if (-not $quiet) { Say ("Lidless hit an error and stopped: " + $text) }
}
exit 0

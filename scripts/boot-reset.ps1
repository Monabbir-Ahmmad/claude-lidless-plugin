# Lidless: boot-time reset for Windows. Plain ASCII, Windows PowerShell 5.1.
#
# The "Lidless Boot Reset" scheduled task runs this at startup as SYSTEM, from
# a copy under Program Files that only administrators can change. Its one
# argument is the state folder of the user who installed it.
#
# If Lidless was on when the PC went down, the state folder still holds the
# original sleep settings. This script writes them back, so the PC behaves
# normally from the moment it boots, before anyone logs in.
#
# It only reads the state folder. It never writes or deletes anything there,
# and it only accepts lines that match the exact expected shape. The saved
# files are cleared later by Lidless itself, at logon or at the next Claude
# Code start.

$stateDir = $null
if ($args.Count -gt 0) { $stateDir = [string]$args[0] }
if (-not $stateDir) { exit 0 }
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { exit 0 }

$powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# name -> subgroup GUID, setting GUID
$known = @{
    'LIDACTION'     = @('4f971e89-eebd-4455-a8de-9e59040e7347', '5ca83367-6e45-459f-a27b-476b1d01c936')
    'STANDBYIDLE'   = @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da')
    'HIBERNATEIDLE' = @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '9d7815a6-7ee4-497e-8888-515a05f02364')
}

$active = ''
$out = (& $powercfg /getactivescheme | Out-String)
if ($out -match "($guid)") { $active = $Matches[1].ToLower() }

$restored = 0
foreach ($file in @(Get-ChildItem -LiteralPath $stateDir -Filter 'plan-*.txt' -File -ErrorAction SilentlyContinue)) {
    if ($file.Name -notmatch "^plan-($guid)\.txt$") { continue }
    $plan = $Matches[1].ToLower()
    if ($file.Length -gt 4096) { continue }
    $lines = @()
    try { $lines = [IO.File]::ReadAllLines($file.FullName) } catch { continue }
    foreach ($line in $lines) {
        if ($line -match '^(LIDACTION|STANDBYIDLE|HIBERNATEIDLE) (\d{1,10}) (\d{1,10})$') {
            $ids = $known[$Matches[1]]
            $ac = $Matches[2]
            $dc = $Matches[3]
            & $powercfg /setacvalueindex $plan $ids[0] $ids[1] $ac | Out-Null
            & $powercfg /setdcvalueindex $plan $ids[0] $ids[1] $dc | Out-Null
            $restored++
        }
    }
    if ($plan -eq $active) { & $powercfg /setactive $plan | Out-Null }
}

# A one-line note next to this script (administrators only), handy when checking that the task ran.
try {
    $note = Join-Path $PSScriptRoot 'last-run.txt'
    [IO.File]::WriteAllText($note, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  settings written back: $restored`r`n"))
} catch { }
exit 0

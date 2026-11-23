#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up tv-auto-power: venv, TV pairing, PC input, scheduled tasks and
    the Group Policy shutdown script. Windows 11 Pro only (needs Group Policy).
    Safe to re-run. Use -Uninstall to remove the tasks and the shutdown script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

$py  = Join-Path $root '.venv\Scripts\python.exe'
$pyw = Join-Path $root '.venv\Scripts\pythonw.exe'
$tv  = Join-Path $root '.venv\Scripts\tv.exe'
$envFile = Join-Path $root '.env'
$user = "$env:USERDOMAIN\$env:USERNAME"
$taskNames = 'TV On', 'TV Sleep Watch'

$gpDir      = "$env:SystemRoot\System32\GroupPolicy"
$gptIni     = "$gpDir\gpt.ini"
$scriptsIni = "$gpDir\Machine\Scripts\scripts.ini"
# Client-side extension GUIDs that tell Windows the local policy has scripts.
$scriptsCse = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# --- .env helpers -------------------------------------------------------------
function Get-EnvValue($key) {
    $line = Get-Content $envFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
    if ($line) { return ($line -split '=', 2)[1].Trim().Trim('"', "'") }
}

function Set-EnvValue($key, $value) {
    $done = $false
    $lines = @(Get-Content $envFile | ForEach-Object {
        if (-not $done -and $_ -match "^\s*#?\s*$key\s*=") { $done = $true; "$key=$value" } else { $_ }
    })
    if (-not $done) { $lines += "$key=$value" }
    Set-Content $envFile $lines -Encoding utf8
}

# --- Scheduled tasks ----------------------------------------------------------
function Remove-Tasks {
    foreach ($name in $taskNames) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Removed task '$name'"
        }
    }
}

# --- Local Group Policy shutdown script -----------------------------------------
function Write-PolicyFile($path, $lines, $encoding, [switch]$Hidden) {
    New-Item (Split-Path $path) -ItemType Directory -Force | Out-Null
    $item = Get-Item $path -Force -ErrorAction SilentlyContinue
    if ($item) { $item.Attributes = 'Normal' }  # hidden files can't be overwritten
    Set-Content $path $lines -Encoding $encoding
    if ($Hidden) { (Get-Item $path -Force).Attributes = 'Hidden' }
}

function Read-ScriptsIni {
    # Section name -> ordered entries of @{ CmdLine; Parameters }
    $sections = [ordered]@{}
    $current = $null
    foreach ($line in (Get-Content $scriptsIni -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $current = $Matches[1]
            $sections[$current] = [ordered]@{}
        } elseif ($current -and $line -match '^(\d+)(CmdLine|Parameters)=(.*)$') {
            $key = $Matches[1]  # string key: an int would index OrderedDictionary by position
            if (-not $sections[$current].Contains($key)) {
                $sections[$current][$key] = @{ CmdLine = ''; Parameters = '' }
            }
            $sections[$current][$key][$Matches[2]] = $Matches[3]
        }
    }
    $sections
}

function Update-GptIni {
    $lines = @(Get-Content $gptIni -ErrorAction SilentlyContinue)
    $ext = $lines | Where-Object { $_ -match '^gPCMachineExtensionNames=' } | Select-Object -First 1
    $groups = @()
    if ($ext) { $groups = @([regex]::Matches($ext, '\[[^\]]+\]') | ForEach-Object Value) }
    $groups = @($groups + $scriptsCse | Sort-Object -Unique)
    $ver = $lines | Where-Object { $_ -match '^Version=\d+' } | Select-Object -First 1
    $version = 1
    if ($ver) { $version = [int64]($ver -split '=')[1] + 1 }  # +1 = machine part changed
    $other = @($lines | Where-Object {
        $_ -and $_ -notmatch '^\[General\]' -and $_ -notmatch '^(gPCMachineExtensionNames|Version)='
    })
    $out = @('[General]', "gPCMachineExtensionNames=$($groups -join '')", "Version=$version") + $other
    Write-PolicyFile $gptIni $out Ascii
}

function Set-ShutdownScript([bool]$enable) {
    $sections = Read-ScriptsIni
    $kept = [ordered]@{}
    if ($sections.Contains('Shutdown')) {
        foreach ($key in $sections['Shutdown'].Keys) {
            $entry = $sections['Shutdown'][$key]
            if ("$($entry.CmdLine) $($entry.Parameters)" -notmatch 'tv_power\.py') { $kept[$key] = $entry }
        }
    }
    if ($enable) { $kept['tv'] = @{ CmdLine = $py; Parameters = "`"$root\tv_power.py`" off" } }
    $sections['Shutdown'] = $kept

    $lines = @('')
    foreach ($name in $sections.Keys) {
        $lines += "[$name]"
        $n = 0
        foreach ($entry in $sections[$name].Values) {
            $lines += "${n}CmdLine=$($entry.CmdLine)"
            $lines += "${n}Parameters=$($entry.Parameters)"
            $n++
        }
    }
    Write-PolicyFile $scriptsIni $lines Unicode -Hidden
    Update-GptIni
    gpupdate /target:computer /force | Out-Null
}

# --- Edition check ----------------------------------------------------------------
$os = (Get-CimInstance Win32_OperatingSystem).Caption
if ($os -match 'Home') {
    throw "$os has no Group Policy, which turns the TV off at shutdown. tv-auto-power needs Windows 11 Pro."
}

if ($Uninstall) {
    Step 'Removing scheduled tasks'
    Remove-Tasks
    Step 'Removing the Group Policy shutdown script'
    Set-ShutdownScript $false
    return
}

# --- Python environment -------------------------------------------------------
if (-not (Test-Path $py)) {
    Step 'Creating virtual environment'
    if (Get-Command py -ErrorAction SilentlyContinue) { & py -3 -m venv .venv }
    else { & python -m venv .venv }
    if ($LASTEXITCODE -or -not (Test-Path $py)) {
        throw 'Could not create .venv. Install Python 3.9+ from python.org and re-run.'
    }
}
Step 'Installing requirements'
& $py -m pip install --upgrade --quiet pip
& $py -m pip install --quiet -r requirements.txt
if ($LASTEXITCODE) { throw 'pip install failed' }

if (-not (Test-Path $envFile)) { Copy-Item .env.example $envFile }

# --- TV pairing ---------------------------------------------------------------
# Leave the TV on for the rest of the setup.
if (-not (Test-Path config.yaml)) {
    Step 'Adding the TV (make sure it is on)'
    & $tv discover
    $ip = Read-Host 'TV IP address'
    & $tv config add $ip
}
if (-not (Test-Path tokens.json)) {
    Step 'Pairing (a PIN appears on the TV)'
    & $tv auth pair
    if ($LASTEXITCODE) { throw 'Pairing failed - re-run setup.ps1 to try again.' }
}

# --- MAC for Wake-on-LAN ------------------------------------------------------
$cfg = & $py -c "import json; from vidaa.config.loader import get_default_tv as g; print(json.dumps(g() or {}))" |
    ConvertFrom-Json
$macRe = '^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$'
$hasMac = (Get-EnvValue 'TV_MAC') -or ($cfg.mac -match $macRe) -or ($cfg.device_id -match $macRe)
if (-not $hasMac) {
    Step 'Looking up the TV MAC address'
    Test-Connection $cfg.host -Count 1 -Quiet | Out-Null  # fills the ARP cache
    $mac = (Get-NetNeighbor -IPAddress $cfg.host -ErrorAction SilentlyContinue |
        Where-Object LinkLayerAddress -match $macRe | Select-Object -First 1).LinkLayerAddress
    if (-not $mac) { $mac = Read-Host 'Could not find it - enter the TV MAC (AA:BB:CC:DD:EE:FF)' }
    Set-EnvValue 'TV_MAC' ($mac -replace '-', ':').ToUpper()
}

# --- PC input -----------------------------------------------------------------
Step 'Choosing the PC input'
& $tv source list
$current = Get-EnvValue 'TV_INPUT'
if (-not $current) { $current = 'none: no switching' }
$answer = Read-Host "Input id the PC is connected to, '-' for none [$current]"
if ($answer -eq '-') { Set-EnvValue 'TV_INPUT' '' }
elseif ($answer) { Set-EnvValue 'TV_INPUT' $answer.Trim() }

# --- Scheduled tasks ----------------------------------------------------------
Step 'Registering scheduled tasks'
Remove-Tasks

# 'TV On': at boot and on resume from sleep, as SYSTEM so it runs before logon.
$wakeClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$onWake = New-CimInstance -CimClass $wakeClass -ClientOnly
$onWake.Enabled = $true
$onWake.Subscription = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>"

Register-ScheduledTask -TaskName 'TV On' `
    -Description 'Turn the TV on and switch to the PC input (tv-auto-power).' `
    -Action (New-ScheduledTaskAction -Execute $py -Argument "`"$root\tv_power.py`" on" -WorkingDirectory $root) `
    -Trigger @((New-ScheduledTaskTrigger -AtStartup), $onWake) `
    -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew) | Out-Null

# 'TV Sleep Watch': runs for the whole session, turns the TV off when the PC sleeps.
Register-ScheduledTask -TaskName 'TV Sleep Watch' `
    -Description 'Turn the TV off when the PC goes to sleep (tv-auto-power).' `
    -Action (New-ScheduledTaskAction -Execute $pyw -Argument "`"$root\tv_sleep_watch.py`"" -WorkingDirectory $root) `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew) | Out-Null

Start-ScheduledTask -TaskName 'TV Sleep Watch'
Write-Host "Registered 'TV On' (SYSTEM) and 'TV Sleep Watch' ($user), watcher started."

# --- Shutdown -----------------------------------------------------------------
Step 'Registering the Group Policy shutdown script'
Set-ShutdownScript $true
Write-Host "Added: gpedit.msc > Computer Configuration > Windows Settings > Scripts > Shutdown"

Step 'Done'
Write-Host "Test with: .\.venv\Scripts\python.exe tv_power.py on   (TV in standby), then check tv_power.log"

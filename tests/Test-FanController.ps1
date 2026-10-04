param([string]$SourceText)
$ErrorActionPreference='Stop'
if(-not $SourceText){$SourceText=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'AsusFanDirect.ps1'))}
. ([scriptblock]::Create($SourceText)) -LibraryOnly
$script:Calls=New-Object 'System.Collections.Generic.List[string]'
$script:FakeState=[pscustomobject]@{ModeValue=3;CPURPM=7000;GPURPM=6500}
$script:GpuFailure=$false
$script:GpuSwitchProfile=$null
function Get-FanState {return $script:FakeState}
function Get-ProfileValue {return $script:FakeState.ModeValue}
function Send-AsusCommand([uint32]$Device,[uint32]$Value){$script:Calls.Add(('WMI:{0:X8}:{1}' -f $Device,$Value))}
function Set-GpuSaioFull {if($null -ne $script:GpuSwitchProfile){$script:FakeState.ModeValue=$script:GpuSwitchProfile};if($script:GpuFailure){throw 'Mock GPU failure'};$script:Calls.Add('GPU:MAX')}
function Stop-GpuSaioFull {$script:Calls.Add('GPU:AUTO')}
$script:Assertions=0
function Assert-Case([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};$script:Assertions++}
Assert-Case (Test-ControllerFileVersion ([version]$ControllerVersion).ToString()) 'Same release can reopen the existing window'
Assert-Case (-not (Test-ControllerFileVersion '2026.10.4.1')) 'Previous release is identified as an upgrade'
Set-RequestedFanMode RPM7000
Assert-Case ($script:Control.Mode -eq 'RPM7000') 'Full mode retained'
Assert-Case ($script:Calls.Contains('GPU:MAX')) 'GPU100 used'
Assert-Case (-not($script:Calls.Contains('WMI:00110013:1') -or $script:Calls.Contains('WMI:00110014:1'))) 'WMI full writes removed'
$script:Calls.Clear();Update-FanControl $script:FakeState ([datetime]::UtcNow.AddSeconds(2))
Assert-Case ($script:Calls.Contains('GPU:MAX')) 'Full keepalive uses SAIO'
$script:Calls.Clear();$script:FakeState.ModeValue=1;Update-FanControl $script:FakeState
Assert-Case ($script:Control.Mode -eq 'System') 'FnF yields'
Assert-Case ($script:Calls.Contains('GPU:AUTO')) 'FnF releases SAIO'
Assert-Case (-not $script:Calls.Contains('GPU:MAX')) 'FnF does not reacquire'
Assert-Case (-not(@($script:Calls|Where-Object {$_ -like 'WMI:00110019:*'}).Count)) 'FnF does not overwrite profile'
$script:Calls.Clear();$script:FakeState.ModeValue=3;Set-RequestedFanMode RPM6300
Assert-Case (-not $script:Calls.Contains('GPU:MAX')) '6300 unchanged'
Assert-Case ($script:Calls.Contains('GPU:AUTO')) '6300 releases SAIO'
$script:Calls.Clear();Set-RequestedFanMode Quiet
Assert-Case ($script:Control.QuietBridgePending) 'High quiet bridge retained'
Assert-Case ($script:Calls.Contains('GPU:AUTO') -and $script:Calls.Contains('WMI:00110019:2')) 'Quiet releases first'
$script:FakeState.ModeValue=2;Update-FanControl $script:FakeState ([datetime]::UtcNow.AddSeconds(13))
Assert-Case (-not $script:Control.QuietBridgePending) 'Quiet bridge bounded'
Assert-Case ($script:Calls.Contains('WMI:00110019:1')) 'Quiet final mode'
$script:Calls.Clear();$script:FakeState.ModeValue=3;$script:GpuFailure=$true
try{Set-RequestedFanMode RPM7000;throw 'Expected GPU failure'}catch{if($_.Exception.Message -eq 'Expected GPU failure'){throw}}
Assert-Case ($script:Control.Mode -eq 'Quiet' -and $script:Calls.Contains('GPU:AUTO')) 'Failed GPU request releases'
Assert-Case ($script:Calls.Contains('WMI:00110013:0') -and $script:Calls.Contains('WMI:00110014:0')) 'Failed GPU request dualAUTO'
$script:Calls.Clear();$script:GpuSwitchProfile=2
Set-RequestedFanMode RPM7000
Assert-Case ($script:Control.Mode -eq 'System' -and -not $script:Calls.Contains('WMI:00110019:1')) 'Initial FnF does not overwrite profile'
$script:GpuSwitchProfile=$null
$script:Control.Mode='RPM7000';$script:Control.Failures=2;$script:Control.RetryAtUtc=[datetime]::MinValue;$script:Control.LastKeepUtc=[datetime]::MinValue
$script:FakeState.ModeValue=3;$script:GpuSwitchProfile=2;$script:Calls.Clear()
$cached=[pscustomobject]@{ModeValue=3;CPURPM=7000;GPURPM=6500}
Update-FanControl $cached
Assert-Case ($script:Control.Mode -eq 'System' -and -not $script:Calls.Contains('WMI:00110019:1')) 'Late FnF does not overwrite profile'
$script:GpuSwitchProfile=$null
$script:GpuFailure=$false;$script:Control.Mode='System';$script:Calls.Clear();Stop-FanController
Assert-Case ($script:Calls.Contains('GPU:AUTO')) 'Exit releases helper'

# Simulated time verifies the tray deadline without moving the fans or waiting a minute.
$script:Calls.Clear()
$script:Control.Mode='RPM7000'; $script:Control.Applied=$true; $script:Control.LastError=''
$script:Control.ReleasePending=$false; $script:Control.QuietBridgePending=$false
$reached=[pscustomobject]@{ModeValue=3;CPURPM=7000;GPURPM=6500}
$start=[datetime]::SpecifyKind([datetime]'2026-10-04T10:00:00',[DateTimeKind]::Utc)
Reset-AutoTrayDelay
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start)) 'Reached starts countdown without hiding'
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddMilliseconds(59999))) 'Visible before 60 seconds'
Assert-Case (Update-AutoTrayDelay $reached $true $start.AddSeconds(60)) 'Hide at 60 seconds'
Assert-Case (-not (Update-AutoTrayDelay $reached $false $start.AddSeconds(61))) 'Hidden window has no countdown'
Assert-Case ($script:AutoTrayDelay.ReachedAtUtc -eq [datetime]::MinValue) 'Hide clears old deadline'
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(62))) 'Reopen waits again'
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(121))) 'Reopen gets full minute'
Assert-Case (Update-AutoTrayDelay $reached $true $start.AddSeconds(122)) 'Reopen reaches new deadline'

Reset-AutoTrayDelay
[void](Update-AutoTrayDelay $reached $true $start)
$below=[pscustomobject]@{ModeValue=3;CPURPM=7000;GPURPM=6300}
Assert-Case (-not (Update-AutoTrayDelay $below $true $start.AddSeconds(59))) 'GPU below enhanced target cancels'
Assert-Case ($script:AutoTrayDelay.ReachedAtUtc -eq [datetime]::MinValue) 'Below target clears deadline'
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(60))) 'Recovering speed starts fresh minute'
Assert-Case (-not (Update-AutoTrayDelay $null $true $start.AddSeconds(120))) 'Read failure cannot hide'
$missing=[pscustomobject]@{ModeValue=3;CPURPM=7000;GPURPM=$null}
Assert-Case (-not (Update-AutoTrayDelay $missing $true $start.AddSeconds(121))) 'Missing sensor cannot hide'

Reset-AutoTrayDelay
[void](Update-AutoTrayDelay $reached $true $start)
$script:Control.Mode='RPM6300'
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(60))) 'Changing mode resets minute'
Assert-Case (Update-AutoTrayDelay $reached $true $start.AddSeconds(120)) '6300 mode reaches its deadline'
$script:Control.Mode='System'
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(121))) 'FnF release cancels countdown'
$script:Control.Mode=$null
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(122))) 'No selection cannot hide'

$script:Control.Mode='RPM7000'
foreach($flag in @('LastError','ReleasePending','QuietBridgePending')) {
    Reset-AutoTrayDelay
    [void](Update-AutoTrayDelay $reached $true $start)
    if($flag -eq 'LastError'){$script:Control.$flag='Mock control failure'}else{$script:Control.$flag=$true}
    Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(60))) "$flag cancels countdown"
    if($flag -eq 'LastError'){$script:Control.$flag=''}else{$script:Control.$flag=$false}
}
$script:Control.Applied=$false
Assert-Case (-not (Update-AutoTrayDelay $reached $true $start.AddSeconds(61))) 'Unapplied mode cannot hide'
$script:Control.Applied=$true; $script:Control.Mode='Quiet'
$quiet=[pscustomobject]@{ModeValue=1;CPURPM=2200;GPURPM=2200}
Reset-AutoTrayDelay
Assert-Case (-not (Update-AutoTrayDelay $quiet $true $start)) 'Quiet target starts minute'
Assert-Case (Update-AutoTrayDelay $quiet $true $start.AddSeconds(60)) 'Quiet target hides after minute'
Reset-AutoTrayDelay
[void](Update-AutoTrayDelay $quiet $true $start)
Assert-Case (-not (Update-AutoTrayDelay $quiet $true $start.AddSeconds(-10))) 'Clock rollback cannot hide early'
Assert-Case ($script:Calls.Count -eq 0) 'Tray timing issues no hardware commands'
Write-Output ('PASS: {0} offline integration assertions; no hardware writes.' -f $script:Assertions)

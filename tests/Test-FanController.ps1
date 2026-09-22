param([string]$SourceText)
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('SourceText')) {
    $SourceText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\AsusFanDirect.ps1'))
}
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($SourceText,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
. ([scriptblock]::Create($SourceText)) -LibraryOnly
$script:checks = 0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
$script:calls = New-Object System.Collections.Generic.List[string]
$script:failAt = ''
function Send-FanModeFast([string]$Name) {
    $script:calls.Add($Name)
    if ($Name -eq $script:failAt) { throw 'simulated firmware rejection' }
    return 1
}
function Start-Sleep { param([int]$Milliseconds) }
function Get-FanState { [pscustomobject]@{ModeValue=1;CPURPM=2000;GPURPM=2000} }
$r = Set-FanMode Full
Assert (($script:calls -join ',') -eq 'Standard,High,Full') 'Full performs the exact ordered transition'
Assert ($r.SetResult -eq 1) 'successful write result is preserved'
foreach($failedMode in @('Standard','High','Full')) {
    $script:calls.Clear(); $script:failAt=$failedMode; $thrown=$false
    try { [void](Invoke-FullSpeedReset) } catch { $thrown=$true }
    Assert $thrown "error is reported for $failedMode"
    Assert ($script:calls[$script:calls.Count-1] -eq 'Full') "Full is the final attempted mode after $failedMode failure"
}
$script:failAt=''
foreach($otherMode in @('High','Quiet')) {
    $script:calls.Clear(); [void](Set-FanMode $otherMode)
    Assert (($script:calls -join ',') -eq $otherMode) "$otherMode never performs a full-speed reset"
}
$now=[datetime]::UtcNow
$state=[pscustomobject]@{ModeValue=3;CPURPM=6300;GPURPM=6300}
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-30) 1 $now) -eq 'Ready') 'both fans ready: no more writes'
$state.GPURPM=5600
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-5) 1 $now) -eq 'Waiting') 'normal spin-up is not interrupted'
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-21) 1 $now) -eq 'Waiting') 'slow but normal spin-up gets a full 30 seconds'
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-31) 1 $now) -eq 'Recover') 'GPU stuck at 5600 triggers recovery'
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-31) 3 $now) -eq 'Limited') 'recovery has a hard attempt limit'
$state.CPURPM=5600; $state.GPURPM=6300
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-31) 1 $now) -eq 'Recover') 'CPU stuck at 5600 also triggers recovery'
$state.CPURPM=$null
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-21) 1 $now) -eq 'Unreadable') 'unknown speed never triggers blind cycling'
$state.CPURPM=6300; $state.ModeValue=2
Assert ((Get-FullSpeedAction $state $now.AddSeconds(-31) 1 $now) -eq 'Recover') 'a wrong profile is not considered success'
Assert ((Convert-FanStatusToRpm 65599) -eq 6300) 'raw fan speed is decoded correctly'
Assert ($null -eq (Convert-FanStatusToRpm ([uint32]4294967294))) 'unsupported sensor is unknown'
# Exercise the actual GUI auto-close function without loading a window or WMI.
$autoCloseAst=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-AutoCloseState'},$true)[0]
. ([scriptblock]::Create($autoCloseAst.Extent.Text))
$script:RequestedMode='Full'
$script:TargetStableSinceUtc=[datetime]::UtcNow.AddSeconds(-61)
$form=[pscustomobject]@{Closed=$false}
$form | Add-Member ScriptMethod Close {$this.Closed=$true}
$state=[pscustomobject]@{ModeValue=3;CPURPM=5600;GPURPM=6300}
Update-AutoCloseState $state
Assert (-not $form.Closed -and $null -eq $script:TargetStableSinceUtc) 'GPU alone cannot auto-close with a slow CPU'
$state.CPURPM=6300
Update-AutoCloseState $state
Assert ($null -ne $script:TargetStableSinceUtc) '6300 starts stability timer'
$script:TargetStableSinceUtc=[datetime]::UtcNow.AddSeconds(-61)
$state.GPURPM=6200
Update-AutoCloseState $state
Assert $form.Closed '6200 fluctuation preserves the original stable-close behavior'
# Transient telemetry errors must not cancel a successfully applied request.
$readerAst=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-AndUpdateFanState'},$true)[0]
. ([scriptblock]::Create($readerAst.Extent.Text))
$noteLabel=[pscustomobject]@{Text=''}
function Update-Labels($State) { $script:LastState=$State }
function Get-FanState { throw 'simulated sensor timeout' }
$script:RequestedMode='Full'; $script:FullAttempts=1
$ok=Read-AndUpdateFanState
Assert (-not $ok -and $null -eq $script:LastState) 'failed telemetry invalidates stale RPM'
Assert ($script:RequestedMode -eq 'Full' -and $script:FullAttempts -eq 1) 'transient telemetry error preserves recovery request'
function Get-FanState { [pscustomobject]@{ModeValue=3;CPURPM=6300;GPURPM=6300} }
Assert (Read-AndUpdateFanState) 'telemetry resumes on the next read'
# Invoke the real GUI handler with lightweight controls and mocked firmware.
$applyAst=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Apply-RequestedMode'},$true)[0]
. ([scriptblock]::Create($applyAst.Extent.Text))
$modeLabel=[pscustomobject]@{Text=''}
$textSetting='Setting'; $textTitle='Test'
$form | Add-Member ScriptMethod Refresh {} -Force
$script:IsBusy=$false
$script:calls.Clear()
Apply-RequestedMode Full
Assert (($script:calls -join ',') -eq 'Standard,High,Full') 'the GUI Full handler executes the verified sequence'
Assert ($script:RequestedMode -eq 'Full' -and $script:FullAttempts -eq 1 -and -not $script:IsBusy) 'GUI request and recovery count are initialized'
$script:IsBusy=$true; $script:calls.Clear()
Apply-RequestedMode Full
Assert ($script:calls.Count -eq 0) 'a repeated click cannot interleave an active transition'
$script:IsBusy=$false
<# Quiet deceleration behavior, using the real transition helpers and GUI events. #>
$high=[pscustomobject]@{ModeValue=3;CPURPM=6300;GPURPM=6200}
$low=[pscustomobject]@{ModeValue=2;CPURPM=2000;GPURPM=2300}
$script:calls.Clear()
Start-QuietTransition $high
Assert ($script:QuietBridgePending -and ($script:calls -join ',') -eq 'High') 'Quiet starts one non-blocking High bridge from high RPM'
$now=[datetime]::UtcNow
Assert ((Get-QuietSpeedAction $high $true $now.AddSeconds(-11) 0 $now) -eq 'Waiting') 'bridge waits while both fans are still high'
Assert ((Get-QuietSpeedAction $low $true $now.AddSeconds(-5) 0 $now) -eq 'FinishBridge') 'bridge ends as soon as both fans are low'
$oneSlow=[pscustomobject]@{ModeValue=2;CPURPM=2000;GPURPM=3000}
Assert ((Get-QuietSpeedAction $oneSlow $true $now.AddSeconds(-5) 0 $now) -eq 'Waiting') 'one low fan cannot end the bridge early'
Assert ((Get-QuietSpeedAction $null $true $now.AddSeconds(-13) 0 $now) -eq 'FinishBridge') '12-second deadline applies even without sensor data'
Complete-QuietTransition
Complete-QuietTransition
Assert ((($script:calls -join ',') -eq 'High,Quiet') -and -not $script:QuietBridgePending) 'bridge completion is exactly once'
$script:calls.Clear(); Start-QuietTransition $low
Assert (($script:calls -join ',') -eq 'Quiet' -and -not $script:QuietBridgePending) 'already-low fans go directly to Quiet'
foreach($speed in @(2000,4900,6300)) {
    $quietState=[pscustomobject]@{ModeValue=1;CPURPM=$speed;GPURPM=$speed}
    Assert ((Get-QuietSpeedAction $quietState $false $now.AddSeconds(-60) 1 $now) -eq 'Ready') "Quiet at $speed RPM never causes periodic rewriting"
}
Assert ((Get-QuietSpeedAction $high $false $now.AddSeconds(-4) 1 $now) -eq 'Waiting') 'wrong mode gets a reapply grace interval'
Assert ((Get-QuietSpeedAction $high $false $now.AddSeconds(-6) 1 $now) -eq 'Reapply') 'an overwritten quiet mode is reapplied'
Assert ((Get-QuietSpeedAction $high $false $now.AddSeconds(-6) 3 $now) -eq 'Limited') 'overwritten quiet mode has a hard retry limit'
# GUI: selecting a newer mode cancels any delayed Quiet.
$script:calls.Clear(); Apply-RequestedMode Quiet
Assert ($script:QuietBridgePending -and ($script:calls -join ',') -eq 'High') 'GUI Quiet begins the same bridge'
$bridgeDeadline=$script:LastApplyUtc
Apply-RequestedMode Quiet
Assert (($script:calls.Count -eq 1) -and $script:LastApplyUtc -eq $bridgeDeadline) 'repeated Quiet click does not restart or delay the bridge'
Apply-RequestedMode Full
Complete-QuietTransition
Assert (($script:calls -join ',') -eq 'High,Standard,High,Full' -and -not $script:QuietBridgePending) 'new Full selection cannot be overwritten by a delayed Quiet'
$script:calls.Clear(); Apply-RequestedMode Quiet; Apply-RequestedMode High; Complete-QuietTransition
Assert (($script:calls -join ',') -eq 'High,High' -and -not $script:QuietBridgePending) 'new High selection cancels the quiet bridge'
# Invoke the actual timer callback with sensor failure at the bridge deadline.
$tickAst=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Tick'},$true)[0]
$tick=$tickAst.Arguments[0].ScriptBlock.GetScriptBlock()
$script:RequestedMode='Quiet'; $script:QuietBridgePending=$true
$script:LastApplyUtc=[datetime]::UtcNow.AddSeconds(-13)
$script:calls.Clear()
function Get-FanState { throw 'simulated sensor timeout' }
& $tick
Assert (($script:calls -join ',') -eq 'Quiet' -and -not $script:QuietBridgePending) 'GUI deadline completes despite failed telemetry'
& $tick
Assert ($script:calls.Count -eq 1) 'failed telemetry cannot repeat the final Quiet command'
# Final write failure is consumed, visible, and never retried on every tick.
$script:RequestedMode='Quiet'; $script:QuietBridgePending=$true
$script:LastApplyUtc=[datetime]::UtcNow.AddSeconds(-13)
$script:failAt='Quiet'; $script:calls.Clear()
& $tick
Assert (-not $script:QuietBridgePending -and $null -eq $script:RequestedMode -and $noteLabel.Text -like '*rejection*') 'Quiet write failure stops control and surfaces its error'
& $tick
Assert ($script:calls.Count -eq 1) 'a failed Quiet write is not retried indefinitely'
$script:failAt=''
# Closing an unfinished bridge finalizes Quiet; closing another mode does not.
$closingAst=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_FormClosing'},$true)[0]
$closing=$closingAst.Arguments[0].ScriptBlock.GetScriptBlock()
$script:QuietBridgePending=$true; $script:calls.Clear()
$cancel=[pscustomobject]@{Cancel=$false}
& $closing $form $cancel
& $closing $form $cancel
Assert (($script:calls -join ',') -eq 'Quiet' -and -not $cancel.Cancel) 'closing finalizes a pending quiet bridge only once'
$script:QuietBridgePending=$true; $script:RequestedMode='Quiet'; $script:failAt='Quiet'
& $closing $form $cancel
Assert ($cancel.Cancel -and -not $script:QuietBridgePending -and $null -eq $script:RequestedMode) 'failed close-time Quiet keeps the error visible'
$script:failAt=''
# Quiet/High auto-close requires the requested profile, not just matching RPM.
$targetAst=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-TargetReached'},$true)[0]
. ([scriptblock]::Create($targetAst.Extent.Text))
Assert (-not (Test-TargetReached Quiet $low)) 'low RPM in High is not completed Quiet'
$low.ModeValue=1
Assert (Test-TargetReached Quiet $low) 'low RPM in Quiet is completed Quiet'
"PASS: $script:checks assertions; PowerShell $($PSVersionTable.PSVersion); no hardware writes."

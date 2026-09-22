param([string]$SourceText,[string]$SourcePath)
$ErrorActionPreference='Stop'
if(-not $SourceText){
    if(-not $SourcePath){
        $SourcePath=Join-Path $PSScriptRoot 'AsusFanDirect.ThreeMode.ps1'
        if(-not (Test-Path -LiteralPath $SourcePath)){$SourcePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'AsusFanDirect.ps1'}
    }
    $SourceText=[IO.File]::ReadAllText($SourcePath)
}
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($SourceText,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors|Out-String)}
. ([scriptblock]::Create($SourceText)) -LibraryOnly
function Invoke-CimMethod {throw 'Forbidden unmocked hardware access in self-test.'}
function Get-CimInstance {throw 'Forbidden unmocked hardware access in self-test.'}
$script:Checks=0
$script:Calls=New-Object 'System.Collections.Generic.List[string]'
$script:Reject=''
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"}; $script:Checks++}
function Send-AsusCommand([uint32]$Device,[uint32]$Value){
    $command=('{0:X8}={1}' -f $Device,$Value); $script:Calls.Add($command)
    if($command -eq $script:Reject){throw 'simulated command rejection'}
}
function Start-Sleep {param([int]$Milliseconds)}
function Reset-Control {
    $script:Calls.Clear(); $script:Reject=''
    $script:Control=[pscustomobject]@{Mode=$null;Applied=$false;LastKeepUtc=[datetime]::MinValue;RetryAtUtc=[datetime]::MinValue;Failures=0;LastError='';ReleasePending=$false}
}
Reset-Control
Set-RequestedFanMode RPM7000
Assert (($script:Calls -join ',') -eq '00110013=0,00110014=0,00110019=0,00110019=2,00110019=3,00110013=1,00110014=1') '7000 initializes both AUTO then profile and native max'
Assert ($script:Control.Mode -eq 'RPM7000' -and $script:Control.Applied) '7000 requested state retained'
$state=[pscustomobject]@{ModeValue=3;CPURPM=6900;GPURPM=6300}
$now=[datetime]::UtcNow.AddSeconds(2)
$script:Calls.Clear(); Update-FanControl $state $now
Assert (($script:Calls -join ',') -eq '00110013=1,00110014=1') 'GPU6300 keeps CPU full without whole-profile cycling'
$script:Calls.Clear(); $state.GPURPM=5000; $state.CPURPM=6000
Update-FanControl $state $now.AddSeconds(2)
Assert (($script:Calls -join ',') -eq '00110013=1,00110014=1') 'low RPM only reasserts native max, never drops into normal/high'
$script:Calls.Clear(); Update-FanControl $state $now.AddSeconds(2.1)
Assert ($script:Calls.Count -eq 0) 'keepalive interval limits writes'
$script:Calls.Clear(); $state.ModeValue=1
Update-FanControl $state $now.AddSeconds(4)
Assert (($script:Calls -join ',') -eq '00110019=3,00110013=1,00110014=1') 'foreign profile changes recover directly to full'
$script:Calls.Clear(); Update-FanControl $null $now.AddSeconds(6)
Assert (($script:Calls -join ',') -eq '00110013=1,00110014=1') 'lost telemetry does not stop selected max or blindly cycle profiles'
$script:Calls.Clear(); Set-RequestedFanMode Quiet
Assert (($script:Calls -join ',') -eq '00110013=0,00110014=0,00110019=0,00110019=1,00110013=0,00110014=0') 'Quiet releases native max and uses Normal reset without Performance'
Assert ($script:Control.Mode -eq 'Quiet' -and -not $script:Control.ReleasePending) 'Quiet cancels old max keepalive'
$script:Calls.Clear(); $state.ModeValue=1
Update-FanControl $state $now.AddSeconds(10)
Assert ($script:Calls.Count -eq 0) 'Quiet has no stale max writes or repeated resets at high RPM'
Reset-Control; Set-RequestedFanMode RPM6300
Assert (($script:Calls -join ',') -eq '00110013=0,00110014=0,00110019=0,00110019=2,00110019=3') '6300 releases native max and uses classic method'
$state.ModeValue=3; $script:Calls.Clear()
Update-FanControl $state ([datetime]::UtcNow.AddSeconds(2))
Assert ($script:Calls.Count -eq 0) '6300 never applies native max during hold'
Reset-Control; $script:Reject='00110013=0'; $thrown=$false
try{Set-NativeFans 0}catch{$thrown=$true}
Assert $thrown 'CPU release rejection is surfaced'
Assert (($script:Calls -join ',') -eq '00110013=0,00110014=0') 'GPU release still attempted after CPU failure'
Reset-Control; $script:Reject='00110019=1'; $thrown=$false
try{Invoke-QuietCommands}catch{$thrown=$true}
Assert $thrown 'Quiet profile failure is surfaced'
Assert (($script:Calls -join ',') -eq '00110013=0,00110014=0,00110019=0,00110019=1,00110013=0,00110014=0') 'both fan releases attempted despite Quiet profile failure'
Reset-Control; $script:Reject='00110014=1'; $thrown=$false
try{Set-RequestedFanMode RPM7000}catch{$thrown=$true}
Assert $thrown 'partial max failure is reported'
Assert (($script:Calls | Select-Object -Last 3) -join ',' -eq '00110019=1,00110013=0,00110014=0') 'partial max failure returns to Quiet and releases both'
Assert ($script:Control.Mode -eq 'Quiet' -and -not $script:Control.ReleasePending) 'failed request cannot continue native keepalive'
Reset-Control; $script:Reject='00110013=0'
try{Set-RequestedFanMode Quiet}catch{}
Assert ($script:Control.Mode -eq 'Quiet' -and $script:Control.ReleasePending) 'failed release remains pending even when profile is Quiet'
$script:Reject=''; $script:Calls.Clear()
Update-FanControl $state ([datetime]::UtcNow.AddSeconds(3))
Assert (-not $script:Control.ReleasePending -and $script:Control.Applied) 'pending release recovers on a later tick'
Reset-Control; $script:Reject='00110013=0'
try{Set-RequestedFanMode Quiet}catch{}
1..5 | ForEach-Object {Update-FanControl $state ([datetime]::UtcNow.AddSeconds(3*$_))}
$script:Calls.Clear(); Update-FanControl $state ([datetime]::UtcNow.AddSeconds(30))
Assert ($script:Calls.Count -eq 0 -and $script:Control.ReleasePending) 'persistent release failures are bounded and remain visible'
Reset-Control; Set-RequestedFanMode RPM7000; $script:Reject='00110013=1'
1..3 | ForEach-Object {Update-FanControl $state ([datetime]::UtcNow.AddSeconds(3*$_))}
Assert ($script:Control.Mode -eq 'Quiet' -and -not $script:Control.ReleasePending) 'three keepalive failures release native control and stop full'
Reset-Control; $state.ModeValue=3; $state.CPURPM=6900; $state.GPURPM=6300
Assert (Test-ModeReached RPM7000 $state) 'GPU6300 satisfies the practical max target'
$state.GPURPM=6200
Assert (-not (Test-ModeReached RPM7000 $state)) 'GPU6200 is not mislabeled as at least6300'
$state.ModeValue=1; $state.CPURPM=6300; $state.GPURPM=6300
Assert (-not (Test-ModeReached Quiet $state)) 'Quiet mode readback alone cannot claim low RPM'
$state.CPURPM=2000; $state.GPURPM=2400
Assert (Test-ModeReached Quiet $state) 'Quiet reached requires both fans low'
$script:Control.ReleasePending=$true
Assert (-not (Test-ModeReached Quiet $state)) 'pending release cannot be shown as successful'
Assert ($null -eq (Convert-FanRpm ([uint32]::MaxValue-1))) 'unsupported fan telemetry is unknown'
Assert ((Convert-FanRpm 65605) -eq 6900) 'fan RPM decoding preserves measured values'
Assert ($SourceText -notmatch 'AutoCloseStableSeconds|TargetStableSinceUtc') 'no timed automatic process exit can drop keepalive'
Assert ($SourceText -match 'UserClosing.*\{\$_\.Cancel=\$true; \$form.Hide\(\)\}') 'window close keeps tray process alive'
Assert ($SourceText -match "'Quiet','RPM6300','RPM7000'") 'three requested modes are exposed'
"PASS: $script:Checks assertions; no hardware writes."
if($SourceText){'PASS: embedded controller compatible self-test'}

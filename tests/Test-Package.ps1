param([Parameter(Mandatory=$true)][string]$PackageDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$count=0
function Assert-Package([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};$script:count++}
# These operations must never be reached while asking for an installation plan.
function Register-ScheduledTask {throw 'ValidateOnly tried to register a task'}
function Start-ScheduledTask {throw 'ValidateOnly tried to start hardware control'}
function Copy-Item {throw 'ValidateOnly tried to install files'}
function New-Item {throw 'ValidateOnly tried to create files'}
function Start-Process {throw 'ValidateOnly tried to start a program'}
$plan=& (Join-Path $PackageDirectory 'Install.ps1') -PackageDirectory $PackageDirectory -ValidateOnly
Assert-Package ($plan.WorkerPrincipal -eq 'SYSTEM') 'Worker requires SYSTEM'
Assert-Package ($plan.InstallDirectory -eq [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'ASUS Fan Direct\GPUEnhanced'))) 'Worker installation is restricted to Program Files'
Assert-Package ($plan.WorkerTriggers -eq 0) 'Worker has no automatic triggers'
Assert-Package (-not $plan.StartsWorker) 'Installation plan does not start worker'
Assert-Package (-not $plan.StartsProgram) 'Installation plan does not start GUI'
Assert-Package (-not $plan.CreatesLogonTask) 'Installation plan has no logon task'
Assert-Package ($plan.WorkerArguments -match '-WindowStyle Hidden') 'Worker is hidden'
Assert-Package ($plan.WorkerArguments -match '-UserSid "S-1-[0-9-]+"') 'Worker uses a dynamic user identity'
Assert-Package ((Test-Path -LiteralPath $plan.Executable) -and (Test-Path -LiteralPath (Join-Path $PackageDirectory 'GpuSaioWorker.ps1'))) 'Complete executable and worker payload'
Write-Output ('PASS: {0} install-plan assertions; no installation or hardware writes.' -f $count)

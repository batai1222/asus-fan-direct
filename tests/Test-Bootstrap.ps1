param([string]$InstallerText)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not $InstallerText){$InstallerText=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'Install.ps1'))}
# The library path and decision checks must never configure the local computer.
function Register-ScheduledTask {throw 'Self-test tried to register a task'}
function Start-ScheduledTask {throw 'Self-test tried to start a worker'}
function Copy-Item {throw 'Self-test tried to install files'}
function New-Item {throw 'Self-test tried to create files'}
function Start-Process {throw 'Self-test tried to start another program'}
function Get-ScheduledTask {throw 'Self-test tried to inspect local tasks'}
function Get-Process {throw 'Self-test tried to inspect local programs'}
. ([scriptblock]::Create($InstallerText)) -LibraryOnly
$count=0
function Assert-Bootstrap([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};$script:count++}
function Assert-Blocked([scriptblock]$Action,[string]$Expected){
    $message=''
    try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
    Assert-Bootstrap ($message -like ('*'+$Expected+'*')) ('Expected block: '+$Expected)
}
Assert-Bootstrap ((Get-InstallationAction $true $false @() $false) -eq 'Install') 'Fresh single-file launch configures missing components'
Assert-Bootstrap ((Get-InstallationAction $true $false $null $false) -eq 'Install') 'No other processes is allowed'
Assert-Bootstrap ((Get-InstallationAction $true $true @(99) $true) -eq 'Reuse') 'Healthy repeated launch leaves running GUI and worker untouched'
Assert-Bootstrap ((Get-InstallationAction $true $false @() $false) -eq 'Install') 'Changed payload is upgraded when idle'
Assert-Blocked {Get-InstallationAction $true $false @(99) $false} '旧风扇程序'
Assert-Blocked {Get-InstallationAction $true $false @() $true} '后台仍在运行'
Assert-Blocked {Get-InstallationAction $false $true @(99) $false} '旧风扇程序'
$plan=[pscustomobject]@{
    WorkerExecutable='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    WorkerArguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Program Files\ASUS Fan Direct\GPUEnhanced\GpuSaioWorker.ps1" -UserSid "S-1-5-21-111-222-333-1001"'
    InstallDirectory='C:\Program Files\ASUS Fan Direct\GPUEnhanced'
}
function New-MockTask {
    [pscustomobject]@{
        Principal=[pscustomobject]@{UserId='SYSTEM';RunLevel='Highest';LogonType='ServiceAccount'}
        State='Ready';Triggers=@()
        Actions=@([pscustomobject]@{Execute=$plan.WorkerExecutable;Arguments=$plan.WorkerArguments;WorkingDirectory=$plan.InstallDirectory})
        Settings=[pscustomobject]@{MultipleInstances='IgnoreNew';ExecutionTimeLimit='PT0S';DisallowStartIfOnBatteries=$false;StopIfGoingOnBatteries=$false}
    }
}
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $null $plan)) 'Missing task requires configuration'
$task=New-MockTask
Assert-Bootstrap (Test-WorkerTaskConfiguration $task $plan) 'Matching task may be reused'
$task.Triggers=$null
Assert-Bootstrap (Test-WorkerTaskConfiguration $task $plan) 'CIM null trigger collection means no triggers'
$task.Principal.RunLevel=1;$task.Principal.LogonType=5;$task.Settings.MultipleInstances=2
Assert-Bootstrap (Test-WorkerTaskConfiguration $task $plan) 'Numeric scheduled-task enum values are supported'
$task=New-MockTask;$task.Principal.UserId='S-1-5-18';$task.State='Running'
Assert-Bootstrap (Test-WorkerTaskConfiguration $task $plan) 'Matching active SYSTEM task is reused'
$task=New-MockTask;$task.Principal.UserId='user'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Unprivileged task is rejected'
$task=New-MockTask;$task.Principal.RunLevel='Limited'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Task must use highest privileges'
$task=New-MockTask;$task.Principal.LogonType='Interactive'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Task must use a service account'
$task=New-MockTask;$task.Triggers=@('logon')
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Unexpected automatic trigger is rejected'
$task=New-MockTask;$task.Actions[0].Execute='C:\Temp\worker.exe'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Wrong task executable is rejected'
$task=New-MockTask;$task.Actions[0].Arguments=$plan.WorkerArguments.Replace('1001','1002')
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Different user SID requires reconfiguration'
$task=New-MockTask;$task.Actions[0].WorkingDirectory='C:\Temp'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Wrong worker directory is rejected'
$task=New-MockTask;$task.Actions+=($task.Actions[0])
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Extra worker action is rejected'
$task=New-MockTask;$task.State='Disabled'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Disabled task is repaired'
$task.State=1
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Numeric disabled task state is repaired'
$task=New-MockTask;$task.Settings.ExecutionTimeLimit='PT1H'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Unexpected worker timeout is repaired'
$task=New-MockTask;$task.Settings.MultipleInstances='Parallel'
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Parallel worker starts are rejected'
$task=New-MockTask;$task.Settings.DisallowStartIfOnBatteries=$true
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Worker remains available on battery'
$task=New-MockTask;$task.Settings.StopIfGoingOnBatteries=$true
Assert-Bootstrap (-not (Test-WorkerTaskConfiguration $task $plan)) 'Battery transition cannot silently stop worker'
$security=New-InstallationSecurity
Assert-Bootstrap ($security.AreAccessRulesProtected -and $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Fresh directory disables inheritance and belongs to Administrators'
$rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
$userRules=@($rules|Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545'})
$userWrite=[int][Security.AccessControl.FileSystemRights]::Write -bor [int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor [int][Security.AccessControl.FileSystemRights]::TakeOwnership
Assert-Bootstrap ($userRules.Count -eq 1 -and ([int]$userRules[0].FileSystemRights -band [int][Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [int][Security.AccessControl.FileSystemRights]::ReadAndExecute -and -not ([int]$userRules[0].FileSystemRights -band $userWrite)) 'Ordinary users may read fresh components but cannot replace them'
Write-Output ('PASS: {0} bootstrap assertions; no installation or hardware writes.' -f $count)

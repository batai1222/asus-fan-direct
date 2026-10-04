[CmdletBinding()]
param(
    [string]$PackageDirectory=$PSScriptRoot,
    [switch]$ValidateOnly,
    [switch]$EnsureInstalled,
    [int]$LauncherProcessId=0,
    [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Get-InstallationAction([bool]$Ensure,[bool]$Matches,[int[]]$OtherProcessIds,[bool]$WorkerRunning){
    if($Ensure -and $Matches){return 'Reuse'}
    if(@($OtherProcessIds|Where-Object {$_ -gt 0}).Count){throw '请先从旧风扇程序中点击“退出程序”，再打开新版。'}
    if($WorkerRunning){throw '风扇后台仍在运行，请等待其退出后重试。'}
    return 'Install'
}
function Test-WorkerTaskConfiguration($Task,$Plan){
    if($null -eq $Task){return $false}
    try{
        $actions=@($Task.Actions)
        return (
            $Task.Principal.UserId -in @('SYSTEM','S-1-5-18') -and
            [string]$Task.Principal.RunLevel -in @('Highest','1') -and
            [string]$Task.Principal.LogonType -in @('ServiceAccount','5') -and
            [string]$Task.State -notin @('Disabled','1') -and
            @($Task.Triggers|Where-Object {$null -ne $_}).Count -eq 0 -and $actions.Count -eq 1 -and
            $actions[0].Execute -eq $Plan.WorkerExecutable -and
            $actions[0].Arguments -ceq $Plan.WorkerArguments -and
            $actions[0].WorkingDirectory -eq $Plan.InstallDirectory -and
            [string]$Task.Settings.MultipleInstances -in @('IgnoreNew','2') -and
            [string]$Task.Settings.ExecutionTimeLimit -eq 'PT0S' -and
            -not $Task.Settings.DisallowStartIfOnBatteries -and
            -not $Task.Settings.StopIfGoingOnBatteries
        )
    }catch{return $false}
}
function New-InstallationSecurity {
    $security=New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true,$false)
    $security.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $inheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')){
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))
    }
    $users=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,[Security.AccessControl.FileSystemRights]::ReadAndExecute,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))
    return $security
}
function Assert-ProtectedInstallation([string]$InstallDirectory,[string]$ProgramFiles){
    $writeMask=[int][Security.AccessControl.FileSystemRights]::WriteData -bor [int][Security.AccessControl.FileSystemRights]::AppendData -bor [int][Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor [int][Security.AccessControl.FileSystemRights]::WriteAttributes -bor [int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor [int][Security.AccessControl.FileSystemRights]::TakeOwnership
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $protectedPaths=@('AsusFanDirect.exe','GpuSaioWorker.ps1','AsusFanDirect.ps1','fan.ico'|ForEach-Object {Join-Path $InstallDirectory $_})
    $directory=$InstallDirectory
    while($directory.StartsWith($ProgramFiles+'\',[StringComparison]::OrdinalIgnoreCase) -or $directory -eq $ProgramFiles){
        $protectedPaths+=$directory
        if($directory -eq $ProgramFiles){break}
        $directory=Split-Path -Parent $directory
    }
    foreach($protectedPath in $protectedPaths){
        if(-not (Test-Path -LiteralPath $protectedPath)){continue}
        if((Get-Item -LiteralPath $protectedPath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The protected installation path contains a reparse point.'}
        foreach($rule in (Get-Acl -LiteralPath $protectedPath).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
            if($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
            if(-not ([int]$rule.FileSystemRights -band $writeMask)){continue}
            if($rule.IdentityReference.Value -notin $trusted){throw '安装目录可被普通用户修改，无法安全配置风扇后台。'}
        }
    }
}
if($LibraryOnly){return}
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1 (powershell.exe).'}
$PackageDirectory=[IO.Path]::GetFullPath($PackageDirectory)
$programFiles=[IO.Path]::GetFullPath([Environment]::GetFolderPath('ProgramFiles')).TrimEnd('\')
$InstallDirectory=Join-Path $programFiles 'ASUS Fan Direct\GPUEnhanced'
$exe=Join-Path $PackageDirectory 'AsusFanDirect.exe'
if(-not (Test-Path -LiteralPath $exe)){$exe=Join-Path $PackageDirectory 'dist\AsusFanDirect.exe'}
$worker=Join-Path $PackageDirectory 'GpuSaioWorker.ps1'
$source=Join-Path $PackageDirectory 'AsusFanDirect.ps1'
$icon=Join-Path $PackageDirectory 'assets\fan.ico'
$files=@(
    @{Source=$exe;Name='AsusFanDirect.exe'},
    @{Source=$worker;Name='GpuSaioWorker.ps1'},
    @{Source=$source;Name='AsusFanDirect.ps1'},
    @{Source=$icon;Name='fan.ico'}
)
foreach($file in $files){if(-not (Test-Path -LiteralPath $file.Source -PathType Leaf)){throw "Package file missing: $($file.Source)"}}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$userSid=$identity.User.Value
$taskName='ASUS Fan Direct - GPU SAIO'
$taskArguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $InstallDirectory 'GpuSaioWorker.ps1')+'" -UserSid "'+$userSid+'"'
$plan=[pscustomobject]@{
    InstallDirectory=$InstallDirectory
    Executable=$exe
    InstalledExecutable=(Join-Path $InstallDirectory 'AsusFanDirect.exe')
    WorkerTask=$taskName
    WorkerExecutable=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
    WorkerArguments=$taskArguments
    WorkerPrincipal='SYSTEM'
    WorkerTriggers=0
    StartsProgram=$false
    StartsWorker=$false
    CreatesLogonTask=$false
}
if($ValidateOnly){return $plan}
if(-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw '请允许程序申请管理员权限，或右键 Install.cmd 选择“以管理员身份运行”。'
}
Assert-ProtectedInstallation $InstallDirectory $programFiles
$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existing -and ($existing.Principal.UserId -notin @('SYSTEM','S-1-5-18') -or $existing.Actions.Arguments -notmatch 'GpuSaioWorker\.ps1')){
    throw 'An unrelated task uses the reserved worker name; it was not changed.'
}
$payloadMatches=Test-WorkerTaskConfiguration $existing $plan
foreach($file in $files){
    $destination=Join-Path $InstallDirectory $file.Name
    if(-not (Test-Path -LiteralPath $destination -PathType Leaf)){$payloadMatches=$false;break}
    if((Get-FileHash -LiteralPath $file.Source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash){$payloadMatches=$false;break}
}
$otherProcesses=@(Get-Process -Name AsusFanDirect -ErrorAction SilentlyContinue|Where-Object {$_.Id -ne $LauncherProcessId}|ForEach-Object {$_.Id})
$workerRunning=$null -ne $existing -and [string]$existing.State -in @('Running','4')
$decision=Get-InstallationAction ([bool]$EnsureInstalled) $payloadMatches $otherProcesses $workerRunning
if($decision -eq 'Reuse'){return $plan}
foreach($path in @((Split-Path -Parent $InstallDirectory),$InstallDirectory)){
    if(-not (Test-Path -LiteralPath $path)){[IO.Directory]::CreateDirectory($path,(New-InstallationSecurity))|Out-Null}
}
Assert-ProtectedInstallation $InstallDirectory $programFiles
foreach($file in $files){
    $destination=Join-Path $InstallDirectory $file.Name
    if([IO.Path]::GetFullPath($file.Source) -ne [IO.Path]::GetFullPath($destination)){
        if(-not (Test-Path -LiteralPath $destination) -or (Get-FileHash -LiteralPath $file.Source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash){
            Copy-Item -LiteralPath $file.Source -Destination $destination -Force
        }
    }
    if((Get-FileHash -LiteralPath $file.Source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash){throw 'Installed file hash mismatch'}
}
Assert-ProtectedInstallation $InstallDirectory $programFiles
$action=New-ScheduledTaskAction -Execute $plan.WorkerExecutable -Argument $taskArguments -WorkingDirectory $InstallDirectory
$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'ASUS风扇－GPU增强版.lnk'))
$shortcut.TargetPath=$plan.InstalledExecutable
$shortcut.WorkingDirectory=$InstallDirectory
$shortcut.IconLocation=(Join-Path $InstallDirectory 'fan.ico')+',0'
$shortcut.Description='CPU约7000转、GPU约6400–6500转；达速一分钟后收起到托盘'
$shortcut.Save()
Write-Output '后台组件已配置。'

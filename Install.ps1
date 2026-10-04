[CmdletBinding()]
param(
    [string]$PackageDirectory=$PSScriptRoot,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1 (powershell.exe).'}
$PackageDirectory=[IO.Path]::GetFullPath($PackageDirectory)
$InstallDirectory=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'ASUS Fan Direct\GPUEnhanced'))
$exe=Join-Path $PackageDirectory 'AsusFanDirect.exe'
if(-not (Test-Path -LiteralPath $exe)){$exe=Join-Path $PackageDirectory 'dist\AsusFanDirect.exe'}
$worker=Join-Path $PackageDirectory 'GpuSaioWorker.ps1'
$source=Join-Path $PackageDirectory 'AsusFanDirect.ps1'
$icon=Join-Path $PackageDirectory 'assets\fan.ico'
foreach($file in @($exe,$worker,$source,$icon)){if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw "Package file missing: $file"}}
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
    throw '请右键 Install.cmd，选择“以管理员身份运行”。'
}
if(@(Get-Process -Name AsusFanDirect -ErrorAction SilentlyContinue).Count){throw '请先从风扇程序中点击“退出程序”，再运行安装器。安装器不会强制结束程序。'}
$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existing -and [string]$existing.State -eq 'Running'){throw '风扇后台仍在运行，请等待其退出后重试。'}
if($existing -and ($existing.Principal.UserId -notin @('SYSTEM','S-1-5-18') -or $existing.Actions.Arguments -notmatch 'GpuSaioWorker\.ps1')){
    throw 'An unrelated task uses the reserved worker name; it was not changed.'
}
$directory=$InstallDirectory
$programFiles=[IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
while($directory.StartsWith($programFiles,[StringComparison]::OrdinalIgnoreCase)){
    if((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'The protected installation path contains a reparse point.'
    }
    if($directory.TrimEnd('\') -eq $programFiles){break}
    $directory=Split-Path -Parent $directory
}
New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
foreach($entry in @(
    @{Source=$exe;Name='AsusFanDirect.exe'},
    @{Source=$worker;Name='GpuSaioWorker.ps1'},
    @{Source=$source;Name='AsusFanDirect.ps1'},
    @{Source=$icon;Name='fan.ico'}
)){
    $destination=Join-Path $InstallDirectory $entry.Name
    Copy-Item -LiteralPath $entry.Source -Destination $destination -Force
    if((Get-FileHash -LiteralPath $entry.Source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash){throw 'Installed file hash mismatch'}
}
# A SYSTEM task must never execute a worker that ordinary users can replace.
$writeMask=[int][Security.AccessControl.FileSystemRights]::WriteData -bor [int][Security.AccessControl.FileSystemRights]::AppendData -bor [int][Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor [int][Security.AccessControl.FileSystemRights]::WriteAttributes -bor [int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor [int][Security.AccessControl.FileSystemRights]::TakeOwnership
$trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$protectedPaths=@((Join-Path $InstallDirectory 'GpuSaioWorker.ps1'))
$directory=$InstallDirectory
while($directory.StartsWith($programFiles,[StringComparison]::OrdinalIgnoreCase)){
    $protectedPaths+=$directory
    if($directory.TrimEnd('\') -eq $programFiles){break}
    $directory=Split-Path -Parent $directory
}
foreach($protectedPath in $protectedPaths){
    foreach($rule in (Get-Acl -LiteralPath $protectedPath).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
        if(-not ([int]$rule.FileSystemRights -band $writeMask)){continue}
        $sid=$rule.IdentityReference.Value
        if($sid -notin $trusted){throw 'Worker installation directory is writable by an unprivileged identity; no SYSTEM task was registered.'}
    }
}
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
Write-Output '安装完成。请打开桌面上的小风扇快捷方式。安装器没有运行风扇控制，也没有创建开机启动项。'

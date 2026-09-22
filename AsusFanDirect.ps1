param(
    [ValidateSet('Gui','Quiet','RPM6300','RPM7000','Status','Full','High')][string]$Mode='Gui',
    [switch]$LibraryOnly,
    [int]$DurationSeconds=0
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ControllerVersion='2026.09.22.3'
$DeviceIds=@{Profile=[uint32]0x00110019;CPU=[uint32]0x00110013;GPU=[uint32]0x00110014}
$script:Wmi=$null
$script:ShowWindowEvent=$null
$script:Control=[pscustomobject]@{
    Mode=$null; Applied=$false; LastKeepUtc=[datetime]::MinValue;
    RetryAtUtc=[datetime]::MinValue; Failures=0; LastError=''; ReleasePending=$false
}

function Get-AsusWmi {
    if($null -eq $script:Wmi){$script:Wmi=Get-CimInstance -Namespace 'root\WMI' -ClassName AsusAtkWmi_WMNB -OperationTimeoutSec 2}
    return $script:Wmi
}
function Send-AsusCommand([uint32]$Device,[uint32]$Value) {
    $r=Invoke-CimMethod -InputObject (Get-AsusWmi) -MethodName DEVS -Arguments @{Device_ID=$Device;Control_status=$Value} -OperationTimeoutSec 2
    if([int64]$r.Result -ne 1){throw ('ASUS rejected 0x{0:X8}={1}: {2}' -f $Device,$Value,$r.Result)}
}
function Get-AsusStatus([uint32]$Device) {
    $r=Invoke-CimMethod -InputObject (Get-AsusWmi) -MethodName DSTS -Arguments @{Device_ID=$Device} -OperationTimeoutSec 2
    return [uint32]$r.device_status
}
function Convert-FanRpm([uint32]$Raw) {
    if($Raw -eq [uint32]::MaxValue -or $Raw -eq ([uint32]::MaxValue-1)){return $null}
    $value=$Raw -band 0xffff
    if($value -in @(65534,65535)){return $null}
    if($value -lt 200){return $value*100}
    return $value
}
function Get-FanState {
    [pscustomobject]@{
        ModeValue=((Get-AsusStatus $DeviceIds.Profile) -band 0xffff)
        CPURPM=(Convert-FanRpm (Get-AsusStatus $DeviceIds.CPU))
        GPURPM=(Convert-FanRpm (Get-AsusStatus $DeviceIds.GPU))
    }
}
function Set-NativeFans([ValidateSet(0,1)][int]$Value) {
    # SPEC83: 0 means firmware AUTO, never a zero-RPM/manual PWM command.
    $failures=New-Object 'System.Collections.Generic.List[string]'
    foreach($id in @($DeviceIds.CPU,$DeviceIds.GPU)) {
        try{Send-AsusCommand $id $Value}catch{$failures.Add($_.Exception.Message)}
    }
    if($failures.Count){throw ($failures -join '; ')}
}
function Invoke-QuietCommands {
    $failures=New-Object 'System.Collections.Generic.List[string]'
    # Brief Normal reset improves the observed decay; never use Performance (2).
    # Cancelled native keepalive stays cancelled throughout this synchronous step.
    try{Set-NativeFans 0}catch{$failures.Add($_.Exception.Message)}
    try{Send-AsusCommand $DeviceIds.Profile 0; Start-Sleep -Milliseconds 100}catch{$failures.Add($_.Exception.Message)}
    try{Send-AsusCommand $DeviceIds.Profile 1}catch{$failures.Add($_.Exception.Message)}
    try{Set-NativeFans 0}catch{$failures.Add($_.Exception.Message)}
    if($failures.Count){throw ($failures -join '; ')}
}
function Initialize-FullProfile {
    Set-NativeFans 0
    try {
        Send-AsusCommand $DeviceIds.Profile 0
        Start-Sleep -Milliseconds 300
        Send-AsusCommand $DeviceIds.Profile 2
        Start-Sleep -Milliseconds 50
    } finally {Send-AsusCommand $DeviceIds.Profile 3}
}
function Set-RequestedFanMode([ValidateSet('Quiet','RPM6300','RPM7000')][string]$Name) {
    # All requests and ticks share the UI thread: cancel previous keepalive first.
    $script:Control.Mode=$Name
    $script:Control.Applied=$false
    $script:Control.Failures=0
    $script:Control.RetryAtUtc=[datetime]::MinValue
    $script:Control.LastError=''
    $script:Control.ReleasePending=($Name -eq 'Quiet')
    try {
        switch($Name) {
            Quiet {Invoke-QuietCommands}
            RPM6300 {Initialize-FullProfile}
            RPM7000 {Initialize-FullProfile; Set-NativeFans 1}
        }
        $script:Control.Applied=$true
        $script:Control.ReleasePending=$false
        $script:Control.LastKeepUtc=[datetime]::UtcNow
    } catch {
        $message=$_.Exception.Message
        # A partial full request must never leave an unattended native override.
        $script:Control.Mode='Quiet'
        $script:Control.ReleasePending=$true
        try{Invoke-QuietCommands; $script:Control.ReleasePending=$false; $script:Control.Applied=$true}
        catch{$message+='; AUTO/Quiet: '+$_.Exception.Message}
        $script:Control.LastError=$message
        $script:Control.Failures=1
        $script:Control.RetryAtUtc=[datetime]::UtcNow.AddSeconds(2)
        throw $message
    }
}
function Update-FanControl($State,[datetime]$NowUtc=[datetime]::UtcNow) {
    $c=$script:Control
    if(-not $c.Mode -or $NowUtc -lt $c.RetryAtUtc){return}
    try {
        if($c.ReleasePending) {
            if($c.Failures -ge 3){return}
            Invoke-QuietCommands
            $c.ReleasePending=$false; $c.Applied=$true; $c.Failures=0; $c.LastError=''
            return
        }
        if(($NowUtc-$c.LastKeepUtc).TotalSeconds -lt 1){return}
        if($c.Mode -eq 'RPM7000') {
            # Never cycle 0/2 because GPU is below 7000: keep CPU running steadily.
            if($null -ne $State -and $State.ModeValue -ne 3){Send-AsusCommand $DeviceIds.Profile 3}
            Set-NativeFans 1
        } elseif($c.Mode -eq 'RPM6300') {
            if($null -ne $State -and $State.ModeValue -ne 3){
                Set-NativeFans 0
                Send-AsusCommand $DeviceIds.Profile 3
            }
        } elseif($c.Mode -eq 'Quiet') {
            if($null -ne $State -and $State.ModeValue -ne 1){Invoke-QuietCommands}
        }
        $c.LastKeepUtc=$NowUtc
        if($c.Failures -gt 0){$c.LastError=''}
        $c.Failures=0
    } catch {
        $c.LastError=$_.Exception.Message
        $c.Failures++
        $c.RetryAtUtc=$NowUtc.AddSeconds(2)
        if($c.ReleasePending){return}
        if($c.Failures -ge 3) {
            $c.Mode='Quiet'; $c.Applied=$false; $c.ReleasePending=$true; $c.Failures=0
            try{Invoke-QuietCommands; $c.Applied=$true; $c.ReleasePending=$false}
            catch{$c.LastError+='; AUTO/Quiet: '+$_.Exception.Message; $c.Failures=1}
        }
    }
}
function Test-ModeReached([string]$Name,$State) {
    if($null -eq $State -or $null -eq $State.CPURPM -or $null -eq $State.GPURPM){return $false}
    switch($Name) {
        Quiet {return ($State.ModeValue -eq 1 -and $State.CPURPM -le 2500 -and $State.GPURPM -le 2500 -and -not $script:Control.ReleasePending)}
        RPM6300 {return ($State.ModeValue -eq 3 -and $State.CPURPM -ge 6200 -and $State.GPURPM -ge 6300)}
        RPM7000 {return ($State.ModeValue -eq 3 -and $State.CPURPM -ge 6900 -and $State.GPURPM -ge 6300)}
    }
    return $false
}
function Get-ModeLabel([string]$Name) {
    switch($Name){Quiet{'安静'} RPM6300{'6300 转'} RPM7000{'7000 转'} default{'未选择'}}
}
function Get-RpmText($Value) {if($null -eq $Value){return '读取中'}; return "$Value RPM"}

function Show-FanGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form
    $form.Text="ASUS 风扇直控 $ControllerVersion"
    $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(470,250)
    $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $modeLabel=New-Object Windows.Forms.Label
    $modeLabel.Location=New-Object Drawing.Point(20,18); $modeLabel.Size=New-Object Drawing.Size(430,30)
    $modeLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',14,[Drawing.FontStyle]::Bold)
    $modeLabel.Text='请选择风扇档位'; $form.Controls.Add($modeLabel)
    $cpuLabel=New-Object Windows.Forms.Label
    $cpuLabel.Location=New-Object Drawing.Point(20,58); $cpuLabel.Size=New-Object Drawing.Size(215,28)
    $form.Controls.Add($cpuLabel)
    $gpuLabel=New-Object Windows.Forms.Label
    $gpuLabel.Location=New-Object Drawing.Point(240,58); $gpuLabel.Size=New-Object Drawing.Size(215,28)
    $form.Controls.Add($gpuLabel)
    $note=New-Object Windows.Forms.Label
    $note.Location=New-Object Drawing.Point(20,95); $note.Size=New-Object Drawing.Size(430,48)
    $note.Text='7000 档持续维持转速；关闭窗口后在托盘运行。'; $form.Controls.Add($note)
    $script:UiBusy=$false; $script:ExitRequested=$false
    $tray=New-Object Windows.Forms.NotifyIcon
    $tray.Icon=[Drawing.SystemIcons]::Application
    $tray.Text='ASUS 风扇直控'; $tray.Visible=$true
    $menu=New-Object Windows.Forms.ContextMenuStrip
    function Refresh-View {
        $state=$null
        try{$state=Get-FanState; $cpuLabel.Text="CPU 风扇：$(Get-RpmText $state.CPURPM)"; $gpuLabel.Text="GPU 风扇：$(Get-RpmText $state.GPURPM)"}
        catch{$cpuLabel.Text='CPU 风扇：读取失败'; $gpuLabel.Text='GPU 风扇：读取失败'; $note.Text=$_.Exception.Message}
        Update-FanControl $state
        if($script:Control.Mode){
            $modeLabel.Text=Get-ModeLabel $script:Control.Mode
            if($script:Control.LastError){$note.Text='控制异常：'+$script:Control.LastError}
            elseif($script:Control.Mode -eq 'RPM7000'){$note.Text='持续维持 CPU 约 7000 转，GPU 尽量提升至最高。'}
            elseif($script:Control.Mode -eq 'RPM6300'){$note.Text='按原全速方法运行，实际转速显示在上方。'}
            else{$note.Text='正在按安静策略降速。'}
            $tray.Text='ASUS 风扇直控 - '+(Get-ModeLabel $script:Control.Mode)
        }
    }
    function Apply-UiMode([string]$Name) {
        if($script:UiBusy){return}
        $script:UiBusy=$true
        try{$note.Text='正在切换…'; $form.Refresh(); Set-RequestedFanMode $Name; Refresh-View}
        catch{$note.Text=$_.Exception.Message; [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,$form.Text)}
        finally{$script:UiBusy=$false}
    }
    function Exit-Controller {
        if($script:UiBusy){return}
        try{Set-RequestedFanMode Quiet; $script:ExitRequested=$true; $form.Close()}
        catch{$form.Show(); [void][Windows.Forms.MessageBox]::Show('恢复自动调速失败，请重试安静后退出。'+$_.Exception.Message,$form.Text)}
    }
    $index=0
    foreach($name in @('Quiet','RPM6300','RPM7000')) {
        $button=New-Object Windows.Forms.Button
        $button.Text=Get-ModeLabel $name; $button.Tag=$name
        $button.Location=New-Object Drawing.Point((20+150*$index),150); $button.Size=New-Object Drawing.Size(130,42)
        $button.Add_Click({Apply-UiMode ([string]$this.Tag)}); $form.Controls.Add($button)
        $item=$menu.Items.Add((Get-ModeLabel $name)); $item.Tag=$name
        $item.Add_Click({Apply-UiMode ([string]$this.Tag)})
        $index++
    }
    [void]$menu.Items.Add('-')
    $openItem=$menu.Items.Add('打开窗口'); $openItem.Add_Click({$form.Show(); $form.WindowState='Normal'; $form.Activate()})
    $exitItem=$menu.Items.Add('恢复安静并退出'); $exitItem.Add_Click({Exit-Controller})
    $tray.ContextMenuStrip=$menu
    $tray.Add_DoubleClick({$form.Show(); $form.WindowState='Normal'; $form.Activate()})
    $hide=New-Object Windows.Forms.Button
    $hide.Text='收起到托盘'; $hide.Location=New-Object Drawing.Point(185,207); $hide.Size=New-Object Drawing.Size(125,30)
    $hide.Add_Click({$form.Hide()}); $form.Controls.Add($hide)
    $exitButton=New-Object Windows.Forms.Button
    $exitButton.Text='安静并退出'; $exitButton.Location=New-Object Drawing.Point(325,207); $exitButton.Size=New-Object Drawing.Size(125,30)
    $exitButton.Add_Click({Exit-Controller}); $form.Controls.Add($exitButton)
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=500
    $timer.Add_Tick({
        if($null -ne $script:ShowWindowEvent -and $script:ShowWindowEvent.WaitOne(0)){
            $form.Show(); $form.WindowState='Normal'; $form.Activate()
        }
        if(-not $script:UiBusy){$script:UiBusy=$true; try{Refresh-View}finally{$script:UiBusy=$false}}
    })
    $form.Add_Shown({Refresh-View; $timer.Start()})
    $form.Add_FormClosing({
        if(-not $script:ExitRequested -and $_.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing){$_.Cancel=$true; $form.Hide()}
    })
    $form.Add_FormClosed({$timer.Stop(); $timer.Dispose(); $tray.Visible=$false; $tray.Dispose(); $menu.Dispose()})
    [void][Windows.Forms.Application]::Run($form)
}

if($LibraryOnly){return}
if($Mode -eq 'Status'){Get-FanState; return}
if($Mode -eq 'Full'){$Mode='RPM7000'}
if($Mode -eq 'High'){$Mode='RPM6300'}
$mutex=New-Object Threading.Mutex($false,'Local\AsusFanDirect.Controller')
$owns=$false
try {
    try{$owns=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException] {$owns=$true}
    if(-not $owns){
        try{
            $signal=[Threading.EventWaitHandle]::OpenExisting('Local\AsusFanDirect.ShowWindow')
            try{[void]$signal.Set()}finally{$signal.Dispose()}
            return
        } catch {throw '风扇程序已经运行，请先关闭旧版窗口，或从托盘打开已有窗口。'}
    }
    $script:ShowWindowEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,'Local\AsusFanDirect.ShowWindow')
    if($Mode -eq 'Gui'){Show-FanGui}
    else {
        Set-RequestedFanMode $Mode
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do {
            $state=$null
            try{$state=Get-FanState}catch{Write-Warning $_}
            Update-FanControl $state
            if($null -ne $state){$state}
            if($script:Control.Mode -ne $Mode){throw ('Controller fell back to Quiet: '+$script:Control.LastError)}
            if($Mode -eq 'Quiet' -and -not $script:Control.ReleasePending){break}
            Start-Sleep -Milliseconds 500
        } while($DurationSeconds -le 0 -or $watch.Elapsed.TotalSeconds -lt $DurationSeconds)
    }
} finally {
    if($owns){
        try{Invoke-QuietCommands}catch{Write-Warning $_}
        $mutex.ReleaseMutex()
    }
    if($null -ne $script:ShowWindowEvent){$script:ShowWindowEvent.Dispose()}
    $mutex.Dispose()
}

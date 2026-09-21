param(
    [ValidateSet('Gui','Full','High','Quiet','Status')]
    [string]$Mode = 'Gui',
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DeviceIds = @{
    VivoBookMode = [uint32]0x00110019
    CPUFan       = [uint32]0x00110013
    GPUFan       = [uint32]0x00110014
}

$ModeValues = @{
    Standard = [uint32]0
    Quiet = [uint32]1
    High  = [uint32]2
    Full  = [uint32]3
}

$FullReadyRpm = 6200
$FullGpuTimerStartRpm = 6300
$FullGpuStableMinRpm = 6200
$FullGpuStableMaxRpm = 6300
$HighReadyRpm = 4200
$QuietFloorRpm = 2500
$AutoCloseStableSeconds = 60
$FullSpinupSeconds = 30
$FullMaxAttempts = 3
$QuietBridgeSeconds = 12
$QuietReapplySeconds = 5
$QuietMaxAttempts = 3
$ControllerVersion = '2026.09.19.2'
$script:QuietBridgePending = $false
$script:QuietAttempts = 0
$script:AsusWmiInstance = $null

function U {
    param([int[]]$CodePoints)
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Get-AsusWmi {
    if ($null -eq $script:AsusWmiInstance) {
        $script:AsusWmiInstance = Get-CimInstance -Namespace 'root\WMI' -ClassName 'AsusAtkWmi_WMNB' -OperationTimeoutSec 3
    }

    $script:AsusWmiInstance
}

function Send-FanModeFast {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Full','High','Quiet','Standard')]
        [string]$Name
    )

    $value = $ModeValues[$Name]

    $inst = Get-AsusWmi
    $result = Invoke-CimMethod -InputObject $inst -MethodName 'DEVS' -Arguments @{
        Device_ID      = $DeviceIds.VivoBookMode
        Control_status = $value
    } -OperationTimeoutSec 3
    if ([int]$result.Result -ne 1) {
        throw "ASUS rejected mode $Name (result: $($result.Result))."
    }
    return [int]$result.Result
}

function Invoke-FullSpeedReset {
    # On H7600ZW, Full alone can retain the previous firmware fan ramp.
    # Match the user's working Fn+F sequence using the existing ASUS endpoint:
    # Standard (0), Performance (2), then Full (3) immediately afterwards.
    # Always try Full on failure so a failed transition does not leave Standard set.
    try {
        [void](Send-FanModeFast -Name Standard)
        Start-Sleep -Milliseconds 300
        [void](Send-FanModeFast -Name High)
        Start-Sleep -Milliseconds 50
    }
    finally {
        $fullResult = Send-FanModeFast -Name Full
    }
    return $fullResult
}

function Get-FullSpeedAction {
    param(
        [object]$State,
        [datetime]$LastTransitionUtc,
        [int]$Attempts,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    if ($null -eq $State -or $null -eq $State.CPURPM -or $null -eq $State.GPURPM) { return 'Unreadable' }
    if ($State.ModeValue -eq 3 -and $State.CPURPM -ge $FullReadyRpm -and $State.GPURPM -ge $FullReadyRpm) { return 'Ready' }
    if (($NowUtc - $LastTransitionUtc).TotalSeconds -lt $FullSpinupSeconds) { return 'Waiting' }
    if ($Attempts -ge $FullMaxAttempts) { return 'Limited' }
    return 'Recover'
}

function Get-QuietSpeedAction {
    param(
        [object]$State,
        [bool]$BridgePending,
        [datetime]$LastTransitionUtc,
        [int]$Attempts,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $elapsed = ($NowUtc - $LastTransitionUtc).TotalSeconds
    if ($BridgePending) {
        # The deadline also applies when sensors are unavailable.
        if ($elapsed -ge $QuietBridgeSeconds) { return 'FinishBridge' }
        if ($null -ne $State -and $null -ne $State.CPURPM -and $null -ne $State.GPURPM -and
            $State.CPURPM -le $QuietFloorRpm -and $State.GPURPM -le $QuietFloorRpm) { return 'FinishBridge' }
        return 'Waiting'
    }
    if ($null -eq $State -or $State.ModeValue -notin @(0,1,2,3)) { return 'Unreadable' }
    # High RPM alone is never a reason to keep resetting the quiet profile.
    if ($State.ModeValue -eq 1) { return 'Ready' }
    if ($elapsed -lt $QuietReapplySeconds) { return 'Waiting' }
    if ($Attempts -ge $QuietMaxAttempts) { return 'Limited' }
    return 'Reapply'
}

function Start-QuietTransition {
    param([object]$State)
    $script:QuietBridgePending = $false
    $script:QuietAttempts = 0
    if ($null -ne $State -and $null -ne $State.CPURPM -and $null -ne $State.GPURPM -and
        ($State.CPURPM -gt $QuietFloorRpm -or $State.GPURPM -gt $QuietFloorRpm)) {
        try { [void](Send-FanModeFast High) }
        catch {
            # If the bridge cannot start, still attempt the requested quiet mode.
            [void](Send-FanModeFast Quiet)
            throw
        }
        $script:QuietBridgePending = $true
    }
    else {
        $script:QuietAttempts = 1
        [void](Send-FanModeFast Quiet)
    }
    $script:LastApplyUtc = [datetime]::UtcNow
}

function Complete-QuietTransition {
    if (-not $script:QuietBridgePending) { return }
    # Consume the pending operation before writing, including on a failed write.
    $script:QuietBridgePending = $false
    $script:QuietAttempts = 1
    [void](Send-FanModeFast Quiet)
    $script:LastApplyUtc = [datetime]::UtcNow
}

function Invoke-QuietModeFast {
    # CLI callers share the same bridge; the GUI advances it without blocking.
    $state = $null
    try { $state = Get-FanState } catch { }
    Start-QuietTransition -State $state
    try {
        while ($script:QuietBridgePending) {
            if ((Get-QuietSpeedAction $null $true $script:LastApplyUtc 0) -eq 'FinishBridge') {
                Complete-QuietTransition
                break
            }
            $state = $null
            try { $state = Get-FanState } catch { }
            if ((Get-QuietSpeedAction $state $true $script:LastApplyUtc 0) -eq 'FinishBridge') {
                Complete-QuietTransition
            }
            else { Start-Sleep -Milliseconds 250 }
        }
    }
    finally { Complete-QuietTransition }
    return 1
}

function Get-AsusDeviceStatus {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$DeviceId
    )

    $inst = Get-AsusWmi
    $result = Invoke-CimMethod -InputObject $inst -MethodName 'DSTS' -Arguments @{ Device_ID = $DeviceId } -OperationTimeoutSec 3
    [uint32]$result.device_status
}

function Convert-FanStatusToRpm {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$RawValue
    )

    $low = $RawValue -band 0xffff
    if ($low -eq 0xfffe -or $low -eq 0xffff) {
        return $null
    }

    if ($low -lt 200) {
        return $low * 100
    }

    return $low
}

function Get-ModeName {
    param([uint32]$Value)

    switch ($Value) {
        0 { return (U 0x666e,0x901a) }
        1 { return (U 0x5b89,0x9759) }
        2 { return (U 0x9ad8,0x901f) }
        3 { return (U 0x5168,0x901f) }
        default { return "Unknown ($Value)" }
    }
}

function Get-FanState {
    $modeRaw = Get-AsusDeviceStatus -DeviceId $DeviceIds.VivoBookMode
    $cpuRaw = Get-AsusDeviceStatus -DeviceId $DeviceIds.CPUFan
    $gpuRaw = Get-AsusDeviceStatus -DeviceId $DeviceIds.GPUFan

    $modeValue = [uint32]($modeRaw -band 0xffff)

    [pscustomobject]@{
        ModeValue = $modeValue
        ModeName  = Get-ModeName -Value $modeValue
        CPURPM    = Convert-FanStatusToRpm -RawValue $cpuRaw
        GPURPM    = Convert-FanStatusToRpm -RawValue $gpuRaw
    }
}

function Set-FanMode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Full','High','Quiet')]
        [string]$Name
    )

    if ($Name -eq 'Full') {
        $result = Invoke-FullSpeedReset
    }
    elseif ($Name -eq 'Quiet') {
        $result = Invoke-QuietModeFast
    }
    else {
        $result = Send-FanModeFast -Name $Name
    }

    $state = Get-FanState
    $state | Add-Member -NotePropertyName SetResult -NotePropertyValue $result
    $state
}

function Format-Rpm {
    param($Value)

    if ($null -eq $Value) {
        return 'unknown'
    }

    "$Value RPM"
}

function Format-FanStateText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    @(
        "Mode: $($State.ModeName)",
        "CPU fan: $(Format-Rpm $State.CPURPM)",
        "GPU fan: $(Format-Rpm $State.GPURPM)"
    ) -join [Environment]::NewLine
}

function Show-FanGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:RequestedMode = $null
    $script:RequestedSinceUtc = [datetime]::MinValue
    $script:LastApplyUtc = [datetime]::MinValue
    $script:LastReadUtc = [datetime]::MinValue
    $script:LastState = $null
    $script:TargetStableSinceUtc = $null
    $script:IsBusy = $false
    $script:FullAttempts = 0
    $script:QuietBridgePending = $false
    $script:QuietAttempts = 0

    $textTitle = "ASUS Fan Direct $ControllerVersion"
    $textCurrentMode = U 0x5f53,0x524d,0x6a21,0x5f0f
    $textFan = U 0x98ce,0x6247
    $textFull = U 0x5168,0x901f
    $textHigh = U 0x9ad8,0x901f
    $textQuiet = U 0x5b89,0x9759
    $textClose = U 0x5173,0x95ed
    $textSetting = U 0x6b63,0x5728,0x8bbe,0x7f6e

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $textTitle
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(440, 255)
    $form.MinimumSize = New-Object System.Drawing.Size(440, 255)
    $form.MaximizeBox = $false

    $modeLabel = New-Object System.Windows.Forms.Label
    $modeLabel.AutoSize = $false
    $modeLabel.Location = New-Object System.Drawing.Point(18, 18)
    $modeLabel.Size = New-Object System.Drawing.Size(390, 34)
    $modeLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $modeLabel.Text = "${textCurrentMode}: ..."
    $form.Controls.Add($modeLabel)

    $cpuLabel = New-Object System.Windows.Forms.Label
    $cpuLabel.AutoSize = $false
    $cpuLabel.Location = New-Object System.Drawing.Point(20, 62)
    $cpuLabel.Size = New-Object System.Drawing.Size(185, 28)
    $cpuLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $cpuLabel.Text = "CPU ${textFan}: ..."
    $form.Controls.Add($cpuLabel)

    $gpuLabel = New-Object System.Windows.Forms.Label
    $gpuLabel.AutoSize = $false
    $gpuLabel.Location = New-Object System.Drawing.Point(220, 62)
    $gpuLabel.Size = New-Object System.Drawing.Size(185, 28)
    $gpuLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $gpuLabel.Text = "GPU ${textFan}: ..."
    $form.Controls.Add($gpuLabel)

    $noteLabel = New-Object System.Windows.Forms.Label
    $noteLabel.AutoSize = $false
    $noteLabel.Location = New-Object System.Drawing.Point(20, 92)
    $noteLabel.Size = New-Object System.Drawing.Size(390, 24)
    $noteLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $noteLabel.Text = U 0x5168,0x901f,0x6062,0x590d,0x20,0xb7,0x20,0x5b89,0x9759,0x5feb,0x901f,0x964d,0x901f
    $form.Controls.Add($noteLabel)

    function Test-TargetReached {
        param(
            [string]$Name,
            [object]$State
        )

        if ($null -eq $State) { return $false }
        if ($null -eq $State.CPURPM -or $null -eq $State.GPURPM) { return $false }
        if (-not $ModeValues.ContainsKey($Name) -or $State.ModeValue -ne $ModeValues[$Name]) { return $false }

        switch ($Name) {
            'Full' {
                return ($State.CPURPM -ge $FullReadyRpm -and $State.GPURPM -ge $FullReadyRpm)
            }
            'High' {
                return ($State.CPURPM -ge $HighReadyRpm -and $State.GPURPM -ge $HighReadyRpm)
            }
            'Quiet' {
                return ($State.CPURPM -le $QuietFloorRpm -and $State.GPURPM -le $QuietFloorRpm)
            }
            default {
                return $false
            }
        }
    }

    function Update-AutoCloseState {
        param([object]$State)

        if (-not $script:RequestedMode) {
            $script:TargetStableSinceUtc = $null
            return
        }

        $now = [datetime]::UtcNow
        if ($script:RequestedMode -eq 'Full') {
            if ($null -eq $State -or $State.ModeValue -ne 3 -or $null -eq $State.CPURPM -or $null -eq $State.GPURPM -or $State.CPURPM -lt $FullReadyRpm) {
                $script:TargetStableSinceUtc = $null
                return
            }

            if ($State.GPURPM -ge $FullGpuTimerStartRpm) {
                if ($null -eq $script:TargetStableSinceUtc) {
                    $script:TargetStableSinceUtc = $now
                }
            }
            elseif ($null -ne $script:TargetStableSinceUtc -and
                    $State.GPURPM -ge $FullGpuStableMinRpm -and
                    $State.GPURPM -le $FullGpuStableMaxRpm) {
                # Keep counting after first 6300 RPM hit while GPU fan floats in the normal full-speed band.
            }
            else {
                $script:TargetStableSinceUtc = $null
                return
            }

            if (($now - $script:TargetStableSinceUtc).TotalSeconds -ge $AutoCloseStableSeconds) {
                $form.Close()
            }
            return
        }

        if (Test-TargetReached -Name $script:RequestedMode -State $State) {
            if ($null -eq $script:TargetStableSinceUtc) {
                $script:TargetStableSinceUtc = $now
            }
            elseif (($now - $script:TargetStableSinceUtc).TotalSeconds -ge $AutoCloseStableSeconds) {
                $form.Close()
            }
        }
        else {
            $script:TargetStableSinceUtc = $null
        }
    }

    function Update-Labels {
        param([object]$State)

        $script:LastState = $State
        $modeLabel.Text = "${textCurrentMode}: $($State.ModeName)"
        $cpuLabel.Text = "CPU ${textFan}: $(Format-Rpm $State.CPURPM)"
        $gpuLabel.Text = "GPU ${textFan}: $(Format-Rpm $State.GPURPM)"
        Update-AutoCloseState -State $State
    }

    function Read-AndUpdateFanState {
        try {
            Update-Labels -State (Get-FanState)
            $script:LastReadUtc = [datetime]::UtcNow
            return $true
        }
        catch {
            # A transient sensor timeout is not a failed mode command.
            # Keep the request, but never recover or auto-close from stale RPM.
            $script:LastState = $null
            $script:TargetStableSinceUtc = $null
            $noteLabel.Text = $_.Exception.Message
            return $false
        }
    }

    function Apply-RequestedMode {
        param([string]$Name)

        if ($script:IsBusy) { return }
        if ($Name -eq 'Quiet' -and $script:QuietBridgePending) { return }
        $script:IsBusy = $true
        try {
            $modeLabel.Text = "${textSetting}: $((Get-ModeName -Value $ModeValues[$Name]))"
            $form.Refresh()
            $script:RequestedMode = $Name
            $script:RequestedSinceUtc = [datetime]::UtcNow
            $script:LastApplyUtc = [datetime]::MinValue
            $script:TargetStableSinceUtc = $null
            # A newer button selection owns the final mode; cancel the old bridge.
            $script:QuietBridgePending = $false
            $script:FullAttempts = 0
            if ($Name -eq 'Full') {
                $noteLabel.Text = U 0x666e,0x901a,0x20,0x2192,0x20,0x6027,0x80fd,0x20,0x2192,0x20,0x5168,0x901f
                [void](Invoke-FullSpeedReset)
                $script:FullAttempts = 1
            }
            elseif ($Name -eq 'Quiet') {
                $quietState = $null
                try { $quietState = Get-FanState } catch { }
                Start-QuietTransition -State $quietState
                if ($script:QuietBridgePending) {
                    $noteLabel.Text = U 0x6b63,0x5728,0x5feb,0x901f,0x964d,0x901f,0xff0c,0x968f,0x540e,0x8fdb,0x5165,0x5b89,0x9759
                }
                else { $noteLabel.Text = U 0x5df2,0x5207,0x6362,0x5230,0x5b89,0x9759 }
            }
            else {
                [void](Send-FanModeFast -Name $Name)
                $noteLabel.Text = ''
            }
            $script:LastApplyUtc = [datetime]::UtcNow
            [void](Read-AndUpdateFanState)
        }
        catch {
            $script:RequestedMode = $null
            $script:TargetStableSinceUtc = $null
            $noteLabel.Text = $_.Exception.Message
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $textTitle) | Out-Null
        }
        finally {
            $script:IsBusy = $false
        }
    }

    $buttonSpecs = @(
        @{ Text = $textFull;  Mode = 'Full';  X = 20  },
        @{ Text = $textHigh;  Mode = 'High';  X = 155 },
        @{ Text = $textQuiet; Mode = 'Quiet'; X = 290 }
    )

    foreach ($spec in $buttonSpecs) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $spec.Text
        $button.Tag = $spec.Mode
        $button.Location = New-Object System.Drawing.Point($spec.X, 130)
        $button.Size = New-Object System.Drawing.Size(115, 40)
        $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
        $button.Add_Click({ Apply-RequestedMode -Name $this.Tag })
        $form.Controls.Add($button)
    }

    $close = New-Object System.Windows.Forms.Button
    $close.Text = $textClose
    $close.Location = New-Object System.Drawing.Point(290, 182)
    $close.Size = New-Object System.Drawing.Size(115, 28)
    $close.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $close.Add_Click({ $form.Close() })
    $form.Controls.Add($close)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        if ($script:IsBusy) { return }

        try {
            $script:IsBusy = $true

            if ($script:RequestedMode) {
                $now = [datetime]::UtcNow
                $elapsed = ($now - $script:LastApplyUtc).TotalSeconds
                # Read before deciding: a stale RPM must not trigger another reset.
                # An expired bridge must finish even if all sensor reads time out.
                if ($script:RequestedMode -eq 'Quiet' -and $script:QuietBridgePending -and
                    (Get-QuietSpeedAction $null $true $script:LastApplyUtc 0) -eq 'FinishBridge') {
                    Complete-QuietTransition
                }
                $readOk = Read-AndUpdateFanState
                if ($script:RequestedMode -eq 'Quiet') {
                    $quietAction = Get-QuietSpeedAction $script:LastState $script:QuietBridgePending $script:LastApplyUtc $script:QuietAttempts
                    switch ($quietAction) {
                        'FinishBridge' {
                            Complete-QuietTransition
                            $noteLabel.Text = U 0x5df2,0x5feb,0x901f,0x964d,0x901f,0xff0c,0x5df2,0x5207,0x6362,0x5230,0x5b89,0x9759
                        }
                        'Reapply' {
                            $script:QuietAttempts++
                            [void](Send-FanModeFast Quiet)
                            $script:LastApplyUtc = [datetime]::UtcNow
                        }
                        'Ready' { $noteLabel.Text = U 0x5df2,0x5207,0x6362,0x5230,0x5b89,0x9759 }
                        'Limited' { $noteLabel.Text = U 0x5b89,0x9759,0x6a21,0x5f0f,0x88ab,0x6539,0x5199,0xff0c,0x5df2,0x505c,0x6b62,0x91cd,0x8bd5 }
                    }
                    return
                }
                if (-not $readOk) { return }
                if ($script:RequestedMode -eq 'Full') {
                    $fullAction = Get-FullSpeedAction -State $script:LastState -LastTransitionUtc $script:LastApplyUtc -Attempts $script:FullAttempts
                    switch ($fullAction) {
                        'Ready' {
                            # Give a later speed drop a fresh spin-up grace period.
                            $script:LastApplyUtc = [datetime]::UtcNow
                            $noteLabel.Text = U 0x5df2,0x5230,0x8fbe,0x5168,0x901f,0xff0c,0x7a33,0x5b9a,0x540e,0x81ea,0x52a8,0x5173,0x95ed
                        }
                        'Recover' {
                            $script:TargetStableSinceUtc = $null
                            $script:FullAttempts++
                            $noteLabel.Text = "$(U 0x6b63,0x5728,0x6062,0x590d,0x5168,0x901f) ($($script:FullAttempts)/$FullMaxAttempts)"
                            [void](Invoke-FullSpeedReset)
                            $script:LastApplyUtc = [datetime]::UtcNow
                        }
                        'Limited' {
                            $noteLabel.Text = U 0x672a,0x8fbe,0x76ee,0x6807,0x8f6c,0x901f,0xff0c,0x5df2,0x505c,0x6b62,0x81ea,0x52a8,0x91cd,0x8bd5
                        }
                        'Unreadable' {
                            $noteLabel.Text = U 0x6682,0x65f6,0x65e0,0x6cd5,0x8bfb,0x53d6,0x8f6c,0x901f
                        }
                    }
                    return
                }

                $shouldReapply = $false
                if ($elapsed -ge 1) {
                    $shouldReapply = $true
                }

                if ($shouldReapply) {
                    [void](Send-FanModeFast -Name $script:RequestedMode)
                    $script:LastApplyUtc = [datetime]::UtcNow
                }

            }
            else {
                $now = [datetime]::UtcNow
                if (($now - $script:LastReadUtc).TotalSeconds -ge 0.25) {
                    [void](Read-AndUpdateFanState)
                }
            }
        }
        catch {
            $script:RequestedMode = $null
            $script:TargetStableSinceUtc = $null
            $noteLabel.Text = $_.Exception.Message
        }
        finally {
            $script:IsBusy = $false
        }
    })

    $form.Add_Shown({
        try {
            [void](Read-AndUpdateFanState)
            $timer.Start()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $textTitle) | Out-Null
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:QuietBridgePending) {
            try { Complete-QuietTransition }
            catch {
                $script:RequestedMode = $null
                $script:TargetStableSinceUtc = $null
                $noteLabel.Text = $_.Exception.Message
                # Keep the window available to show the error and allow retry.
                $eventArgs.Cancel = $true
            }
        }
    })

    $form.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
    })

    [void][System.Windows.Forms.Application]::Run($form)
}

if ($LibraryOnly) { return }

if ($Mode -eq 'Status') {
    Format-FanStateText -State (Get-FanState)
    return
}

# A CLI bridge must not finish later and overwrite a newer GUI/CLI selection.
# Read-only Status remains available while the controller window is open.
$controllerMutex = New-Object System.Threading.Mutex($false, 'Local\AsusFanDirect.Controller')
$ownsController = $false
try {
    try { $ownsController = $controllerMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsController = $true }
    if (-not $ownsController) {
        throw 'ASUS Fan Direct is already running. Use its buttons or close it before starting another controller.'
    }
    switch ($Mode) {
        'Gui' { Show-FanGui }
        default { Format-FanStateText -State (Set-FanMode -Name $Mode) }
    }
}
finally {
    if ($ownsController) { $controllerMutex.ReleaseMutex() }
    $controllerMutex.Dispose()
}

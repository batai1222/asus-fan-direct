param([Parameter(Mandatory=$true)][ValidatePattern('^S-1-[0-9-]+$')][string]$UserSid)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# SAIO reader code is inserted here by the build script.
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public sealed class SaioFanReader:IDisposable {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr sec,uint create,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle handle,uint code,byte[] input,uint inputSize,byte[] output,uint outputSize,out uint returned,IntPtr overlap);
 SafeFileHandle handle;
 public SaioFanReader(){handle=CreateFile(@"\\.\AsusSAIO",0xC0000000,3,IntPtr.Zero,3,0x80,IntPtr.Zero);if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());}
 public byte[] Call(byte[] args,bool read){
  var input=new byte[16];var output=new byte[16];Array.Copy(args,input,args.Length);input[10]=(byte)(read?1:0);uint returned;
  if(!DeviceIoControl(handle,2148540528u,input,16,output,16,out returned,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());
  if(returned<12)throw new Exception("Short ASUS diagnostic response: "+returned);
  return output;
 }
 public string Init(){return BitConverter.ToString(Call(new byte[]{187,1,80},true));}
 public int Count(){return Call(new byte[]{221,3,2,48},true)[11];}
 public int Speed(byte fan){if(fan>1)throw new ArgumentException();Call(new byte[]{221,3,130,50,fan},false);for(int i=0;i<3;i++){int high=Call(new byte[]{221,3,2,52},true)[11];int low=Call(new byte[]{221,3,2,51},true)[11];int check=Call(new byte[]{221,3,2,52},true)[11];if(high==check)return high*256+low;}return -1;}
 public int Duty(byte fan){if(fan>1)throw new ArgumentException();Call(new byte[]{221,3,130,50,fan},false);return Call(new byte[]{221,3,2,53},true)[11];}
 public void Percent(byte fan,int percent){if(fan>1 || percent<80 || percent>100)throw new ArgumentException();Call(new byte[]{221,3,130,50,fan},false);Call(new byte[]{221,3,130,53,(byte)(255*percent/100)},false);}
 public void Manual(bool enabled){Call(new byte[]{221,3,130,49,(byte)(enabled?1:0)},false);}
 public void Max(byte fan){if(fan>1)throw new ArgumentException();Call(new byte[]{221,3,130,50,fan},false);Call(new byte[]{221,3,130,53,255},false);}
 public void Dispose(){if(handle!=null)handle.Dispose();}
}
'@

$pipe=$null;$device=$null;$manualAttempted=$false;$wmi=$null
$pipeName='AsusFanDirect.GpuSaio.'+$UserSid
function Get-WorkerWmi {
 if($null -eq $script:wmi){$script:wmi=Get-CimInstance -Namespace root\WMI -ClassName AsusAtkWmi_WMNB -OperationTimeoutSec 2}
 return $script:wmi
}
function Get-WorkerProfile {
 $r=Invoke-CimMethod -InputObject (Get-WorkerWmi) -MethodName DSTS -Arguments @{Device_ID=[uint32]0x00110019} -OperationTimeoutSec 2
 $raw=[uint32]$r.device_status
 if($raw -in @([uint32]::MaxValue,([uint32]::MaxValue-1))){throw 'Profile unavailable'}
 $value=$raw -band 0xffff
 if($value -notin @(0,1,2,3)){throw 'Profile invalid'}
 return $value
}
function Restore-WorkerAuto {
 $errors=New-Object 'System.Collections.Generic.List[string]'
 if($manualAttempted -and $null -ne $device){try{$device.Manual($false)}catch{$errors.Add($_.Exception.Message)}}
 foreach($id in @([uint32]0x00110013,[uint32]0x00110014)){
  try{$r=Invoke-CimMethod -InputObject (Get-WorkerWmi) -MethodName DEVS -Arguments @{Device_ID=$id;Control_status=[uint32]0} -OperationTimeoutSec 2;if($r.Result -ne 1){throw 'AUTO rejected'}}catch{$errors.Add($_.Exception.Message)}
 }
 if($errors.Count){throw ($errors -join '; ')}
 $script:manualAttempted=$false
}
try {
 $security=New-Object IO.Pipes.PipeSecurity
 foreach($sidText in @($UserSid,'S-1-5-18')){
  $sid=New-Object Security.Principal.SecurityIdentifier($sidText)
  $security.AddAccessRule((New-Object IO.Pipes.PipeAccessRule($sid,[IO.Pipes.PipeAccessRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)))
 }
 $pipe=New-Object IO.Pipes.NamedPipeServerStream($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,16,16,$security)
 $connecting=$pipe.BeginWaitForConnection($null,$null)
 try {if(-not $connecting.AsyncWaitHandle.WaitOne(15000)){throw 'No controller connected'};$pipe.EndWaitForConnection($connecting)}finally{$connecting.AsyncWaitHandle.Close()}
 $heartbeat=[datetime]::UtcNow;$profileChecked=[datetime]::MinValue
 $buffer=New-Object byte[] 1
 $pending=$pipe.BeginRead($buffer,0,1,$null,$null)
 while($pipe.IsConnected){
  $now=[datetime]::UtcNow
  if(($now-$heartbeat).TotalSeconds -ge 12){throw 'Controller heartbeat lost'}
  if(($now-$profileChecked).TotalSeconds -ge 1){
   if((Get-WorkerProfile) -ne 3){throw 'External profile changed'}
   $profileChecked=[datetime]::UtcNow
  }
  if(-not $pending.AsyncWaitHandle.WaitOne(100)){continue}
  try{$read=$pipe.EndRead($pending)}finally{$pending.AsyncWaitHandle.Close()}
  if($read -ne 1){throw 'Controller disconnected'}
  if($buffer[0] -eq 0){Restore-WorkerAuto;$pipe.WriteByte(1);$pipe.Flush();break}
  if($buffer[0] -ne 1){throw 'Invalid control command'}
  if((Get-WorkerProfile) -ne 3){throw 'External profile changed before write'}
  if($null -eq $device){$device=New-Object SaioFanReader;[void]$device.Init();if($device.Count() -ne 2){throw 'Fan count mismatch'}}
  if(-not $manualAttempted){$manualAttempted=$true;$device.Manual($true)}
  $device.Max(0);$device.Max(1)
  if($device.Duty(1) -ne 255){throw 'GPU100 readback mismatch'}
  $heartbeat=[datetime]::UtcNow
  $pipe.WriteByte(1);$pipe.Flush()
  $pending=$pipe.BeginRead($buffer,0,1,$null,$null)
 }
} catch {
 if($null -ne $pipe -and $pipe.IsConnected){try{$pipe.WriteByte(0);$pipe.Flush()}catch{}}
} finally {
 if($manualAttempted){try{Restore-WorkerAuto}catch{}}
 if($null -ne $device){$device.Dispose()}
 if($null -ne $pipe){$pipe.Dispose()}
}

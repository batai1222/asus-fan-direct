[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Build with Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler was not found.' }
$exe = Join-Path $OutputDirectory 'AsusFanDirect.exe'
$source = Join-Path $repoRoot 'AsusFanDirect.ps1'
$test = Join-Path $repoRoot 'tests\Test-FanController.ps1'
$worker = Join-Path $repoRoot 'GpuSaioWorker.ps1'
$installer = Join-Path $repoRoot 'Install.ps1'
$version = [regex]::Match([IO.File]::ReadAllText($source), "ControllerVersion='([^']+)'").Groups[1].Value
if (-not $version) { throw 'Controller version missing.' }
foreach ($scriptPath in @($source, $test, $worker, $installer)) {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
& $test -SourceText ([IO.File]::ReadAllText($source))
$sma = [System.Management.Automation.PowerShell].Assembly.Location
$compilerArguments = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    "/out:$exe", "/reference:$sma", '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
    "/win32manifest:$(Join-Path $repoRoot 'launcher\app.manifest')",
    "/win32icon:$(Join-Path $repoRoot 'assets\fan.ico')",
    "/resource:$source,AsusFanDirect.ps1",
    "/resource:$test,Test-FanController.ps1",
    (Join-Path $repoRoot 'launcher\Program.cs')
)
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed: $LASTEXITCODE" }

# Load assembly bytes only; do not invoke its entry point or touch real hardware.
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
foreach ($entry in @(
    @{Name='AsusFanDirect.ps1'; Path=$source},
    @{Name='Test-FanController.ps1'; Path=$test}
)) {
    $resource = $assembly.GetManifestResourceStream($entry.Name)
    if ($null -eq $resource) { throw "Missing EXE resource: $($entry.Name)" }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $embeddedHash = [BitConverter]::ToString($sha256.ComputeHash($resource)).Replace('-','') }
    finally { $sha256.Dispose(); $resource.Dispose() }
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.Path).Hash
    if ($embeddedHash -ne $sourceHash) { throw "Embedded resource mismatch: $($entry.Name)" }
    Write-Output "Verified embedded $($entry.Name): $embeddedHash"
}

$runId = [Guid]::NewGuid().ToString('N')
$stdout = Join-Path $OutputDirectory ".selftest-$runId.out"
$stderr = Join-Path $OutputDirectory ".selftest-$runId.err"
try {
    $process = Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        $process.WaitForExit()
        throw 'The EXE self-test exceeded its 30-second limit.'
    }
    $exitCode = $process.ExitCode
    $result = Get-Content -Raw -LiteralPath $stdout
    $errors = Get-Content -Raw -LiteralPath $stderr
    if ($exitCode -ne 0 -or $result -notmatch 'PASS: 44 offline integration assertions; no hardware writes\.' -or $result -notmatch 'PASS: embedded controller, Windows PowerShell host, and GUI dependencies\.') {
        throw "EXE self-test failed ($exitCode): $result $errors"
    }
    Write-Output $result.Trim()
}
finally {
    foreach ($logPath in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
    }
}
$packageFiles=@('AsusFanDirect.ps1','GpuSaioWorker.ps1','Install.ps1','Install.cmd','README.md')
foreach ($name in $packageFiles) { Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination (Join-Path $OutputDirectory $name) -Force }
$assetDirectory=Join-Path $OutputDirectory 'assets'
New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets\fan.ico') -Destination (Join-Path $assetDirectory 'fan.ico') -Force
& (Join-Path $repoRoot 'tests\Test-Package.ps1') -PackageDirectory $OutputDirectory
$payload=@('AsusFanDirect.exe')+$packageFiles+@('assets\fan.ico')
$checksums=Join-Path $OutputDirectory 'SHA256SUMS.txt'
@($payload | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $OutputDirectory $_)).Hash,$_.Replace('\','/') }) | Set-Content -LiteralPath $checksums -Encoding ASCII
$zip=Join-Path $OutputDirectory ("AsusFanDirect-$version-win-x64.zip")
$zipInputs=@(@('AsusFanDirect.exe')+$packageFiles+@('SHA256SUMS.txt','assets') | ForEach-Object { Join-Path $OutputDirectory $_ })
Compress-Archive -LiteralPath $zipInputs -DestinationPath $zip -Force
'{0}  {1}' -f (Get-FileHash -LiteralPath $zip).Hash,(Split-Path -Leaf $zip) | Add-Content -LiteralPath $checksums -Encoding ASCII
Write-Output "Built and verified: $exe"
Write-Output "Packaged: $zip"

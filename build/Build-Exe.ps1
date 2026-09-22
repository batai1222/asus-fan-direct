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
$sma = [System.Management.Automation.PowerShell].Assembly.Location
$compilerArguments = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    "/out:$exe", "/reference:$sma", '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
    "/win32manifest:$(Join-Path $repoRoot 'launcher\app.manifest')",
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
    if ($exitCode -ne 0 -or $result -notmatch 'PASS: 33 assertions; no hardware writes\.' -or $result -notmatch 'PASS: embedded controller, Windows PowerShell host, and GUI dependencies\.') {
        throw "EXE self-test failed ($exitCode): $result $errors"
    }
    Write-Output $result.Trim()
}
finally {
    foreach ($logPath in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
    }
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
"$hash  AsusFanDirect.exe" | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Write-Output "Built and verified: $exe"

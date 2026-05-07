[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = '.\standalone.config.json',

    [Parameter(Mandatory = $false)]
    [ValidateSet('firefox', 'edge', 'chrome')]
    [string]$Browser = 'firefox',

    [Parameter(Mandatory = $false)]
    [switch]$CopyCookieToClipboard
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ConfigPath))
$extractScript = Join-Path $repoRoot 'extract-nyt-cookie-header.ps1'
$runScript = Join-Path $repoRoot 'run-local.ps1'

if (-not (Test-Path -LiteralPath $configFullPath)) {
    throw "Config file not found: $configFullPath"
}
if (-not (Test-Path -LiteralPath $extractScript)) {
    throw "Missing helper script: $extractScript"
}
if (-not (Test-Path -LiteralPath $runScript)) {
    throw "Missing runner script: $runScript"
}

Write-Host 'Step 1/2: Refreshing NYT cookie header...'
$extractArgs = @(
    '-ExecutionPolicy', 'Bypass',
    '-File', $extractScript,
    '-Browser', $Browser,
    '-UpdateConfig',
    '-ConfigPath', $configFullPath
)
if ($CopyCookieToClipboard) {
    $extractArgs += '-CopyToClipboard'
}

& powershell @extractArgs
if ($LASTEXITCODE -ne 0) {
    throw "Cookie refresh failed with exit code $LASTEXITCODE"
}

Write-Host 'Step 2/2: Running local delivery...'
& powershell -ExecutionPolicy Bypass -File $runScript -ConfigPath $ConfigPath
if ($LASTEXITCODE -ne 0) {
    throw "Local delivery failed with exit code $LASTEXITCODE"
}

Write-Host 'Workflow complete.'

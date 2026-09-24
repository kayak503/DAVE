[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $PSScriptRoot
$previousPath = $env:PATH
$previousSdk = $env:LOCALVOICE_DOTNET
try {
    $toolchain = Join-Path $PSScriptRoot '.cache\windows-toolchain'
    $sdk = Join-Path $toolchain 'dotnet\dotnet.exe'
    if (!(Test-Path -LiteralPath $sdk)) {
        $sdkCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        if (!$sdkCommand) { throw 'Install the .NET 8 SDK. No SDK was found in PATH or the local toolchain.' }
        $sdk = $sdkCommand.Source
    }
    $env:LOCALVOICE_DOTNET = $sdk

    # The build extracts the bundled Node runtime. Run packaging with a different
    # Node installation so Windows does not lock the archive's destination.
    $bundledNode = Join-Path $toolchain 'node-windows\node-v22.16.0-win-x64'
    $codexNode = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
    $node = $null
    foreach ($candidate in @($codexNode) + @(Get-Command node.exe -All -ErrorAction SilentlyContinue | ForEach-Object Source)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate) -and !$candidate.StartsWith($bundledNode, [StringComparison]::OrdinalIgnoreCase)) {
            $node = $candidate
            break
        }
    }
    if (!$node) { throw 'Install Node.js 22 or newer. A Node installation outside the bundled runtime is required for packaging.' }
    $env:PATH = (Split-Path -Parent $node) + ';' + $bundledNode + ';' + $previousPath
    if (!(Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'npm.cmd was not found. Install Node.js with npm.' }

    if ($Check) {
        Write-Host "Project: $PSScriptRoot"
        Write-Host "Node:    $node"
        Write-Host "SDK:     $sdk"
        & $node --version
        if ($LASTEXITCODE -ne 0) { throw 'Node could not start.' }
        & $sdk --list-sdks
        if ($LASTEXITCODE -ne 0) { throw '.NET could not start.' }
        Write-Host 'Build paths verified. Run .\rebuild.ps1 to build and launch.'
    } else {
        & $node (Join-Path $PSScriptRoot 'windows\scripts\build-check.mjs') --parity
        if ($LASTEXITCODE -ne 0) {
            throw 'Rebuild failed; DAVE was not launched. See the error above and test-results\windows-ui\result.txt. If Application Control blocked DAVE.dll, a trusted signature or administrator approval is required; repeating the build will not resolve that policy.'
        }
        $application = Join-Path $PSScriptRoot 'release\windows-parity\DAVE\DAVE.exe'
        if (!(Test-Path -LiteralPath $application)) { throw 'The build finished without creating DAVE.exe.' }
        # This is the interactive app the user asked to build and run.
        Start-Process -FilePath $application -WorkingDirectory (Split-Path -Parent $application)
        Write-Host "Launched the new build: $application"
    }
} finally {
    $env:PATH = $previousPath
    $env:LOCALVOICE_DOTNET = $previousSdk
    Pop-Location
}

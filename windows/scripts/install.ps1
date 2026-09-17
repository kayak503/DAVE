# Run from an extracted release: powershell -File .\install.ps1
[CmdletBinding()]
param([string]$Source = '')
if (-not $Source) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'LocalVoice.exe')) { $Source = $PSScriptRoot }
    else { $Source = Join-Path $PSScriptRoot '..\..\release\windows\Local Voice' }
}
$ErrorActionPreference = 'Stop'
$Source = [IO.Path]::GetFullPath($Source)
$Destination = Join-Path $env:LOCALAPPDATA 'Programs\Local Voice'
foreach ($relative in @('LocalVoice.exe', 'LocalVoice.dll', 'runtime\node.exe', 'runtime\cpu\whisper-cli.exe', 'runtime\cuda\whisper-cli.exe', 'backend\service.mjs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Source $relative) -PathType Leaf)) { throw "Incomplete Local Voice package: missing $relative in $Source" }
}
if (Get-Process -Name LocalVoice -ErrorAction SilentlyContinue) { throw 'Save your work and quit Local Voice before installing. The installer will not close it for you.' }
if ($Source.TrimEnd('\') -eq $Destination.TrimEnd('\')) { throw 'Extract the download outside the installation folder before running the installer.' }
$Parent = Split-Path $Destination
if ($Parent.StartsWith($Source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $Parent.Equals($Source, [StringComparison]::OrdinalIgnoreCase)) { throw 'Choose the extracted Local Voice app folder as Source, not one of its parent installation directories.' }
New-Item -ItemType Directory -Path $Parent -Force | Out-Null
$Stage = Join-Path $Parent ('Local Voice.install-' + [guid]::NewGuid().ToString('N'))
$Backup = Join-Path $Parent ('Local Voice.backup-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $Stage | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Stage -Recurse -Force
    if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $Backup }
    try { Move-Item -LiteralPath $Stage -Destination $Destination }
    catch { if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $Destination }; throw }
    $Menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Local Voice.lnk'
    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut($Menu)
    $Shortcut.TargetPath = Join-Path $Destination 'LocalVoice.exe'
    $Shortcut.WorkingDirectory = $Destination
    $Shortcut.Description = 'Local Voice 1.0.0 — private local speech'
    $Shortcut.Save()
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
    Write-Output "Installed Local Voice 1.0.0 at $Destination. Open Local Voice from the Start menu. Your models and preferences were preserved."
}
finally { if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force } }

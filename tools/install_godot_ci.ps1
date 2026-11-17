[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string[]]$TemplateFiles
)
$ErrorActionPreference = 'Stop'
$engineRoot = Join-Path $env:RUNNER_TEMP 'godot'
New-Item -ItemType Directory -Path $engineRoot -Force | Out-Null
$base = "https://github.com/godotengine/godot-builds/releases/download/$env:GODOT_VERSION-stable"
$editorName = "Godot_v$env:GODOT_VERSION-stable_win64.exe.zip"
$templateName = "Godot_v$env:GODOT_VERSION-stable_export_templates.tpz"
Invoke-WebRequest "$base/$editorName" -OutFile "$engineRoot/editor.zip"
Invoke-WebRequest "$base/$templateName" -OutFile "$engineRoot/templates.zip"
Invoke-WebRequest "$base/SHA512-SUMS.txt" -OutFile "$engineRoot/SHA512-SUMS.txt"
$sums = Get-Content -LiteralPath "$engineRoot/SHA512-SUMS.txt"
foreach ($pair in @(@($editorName,'editor.zip'),@($templateName,'templates.zip'))) {
  $line = @($sums | Where-Object { ($_ -split '\s+')[-1].TrimStart('*') -eq $pair[0] })
  if ($line.Count -ne 1) { throw "Official SHA512 entry missing: $($pair[0])" }
  $expected = ($line[0] -split '\s+')[0].ToLowerInvariant()
  if ((Get-FileHash "$engineRoot/$($pair[1])" -Algorithm SHA512).Hash.ToLowerInvariant() -ne $expected) { throw 'Toolchain checksum mismatch' }
}
Expand-Archive -LiteralPath "$engineRoot/editor.zip" -DestinationPath $engineRoot
Add-Type -AssemblyName System.IO.Compression.FileSystem
$templateRoot = Join-Path $env:APPDATA "Godot/export_templates/$env:GODOT_VERSION.stable"
New-Item -ItemType Directory -Path $templateRoot -Force | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead("$engineRoot/templates.zip")
try {
  foreach ($name in $TemplateFiles) {
    $entry = $zip.GetEntry("templates/$name")
    if ($null -eq $entry) { throw "Template missing: $name" }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $templateRoot $name),$true)
  }
} finally { $zip.Dispose() }
"GODOT_BIN=$engineRoot/Godot_v$env:GODOT_VERSION-stable_win64_console.exe" >> $env:GITHUB_ENV

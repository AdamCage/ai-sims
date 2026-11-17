[CmdletBinding()]
param([string]$Godot=$env:GODOT_BIN,[string]$Version,[switch]$SkipTests)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(-not $Version){
  $projectSettings=[IO.File]::ReadAllText((Join-Path $projectRoot 'project.godot'))
  $Version=[regex]::Match($projectSettings,'(?m)^config/version="([^"]+)"').Groups[1].Value
  if(-not $Version){throw 'Missing application version in project.godot'}
}
$buildRoot=Join-Path $projectRoot 'build'
$sourceRoot=Join-Path $buildRoot 'web-source'
$outputRoot=Join-Path $buildRoot 'web-next'
$publishedRoot=Join-Path $buildRoot 'web'
$mapRoot=Join-Path $buildRoot 'web-map-source'
if(-not $Godot){$Godot=Join-Path $env:USERPROFILE '.codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe'}
function Reset-WebDirectory([string]$Path){$resolved=[IO.Path]::GetFullPath($Path);$allowed=[IO.Path]::GetFullPath($buildRoot).TrimEnd('\')+'\';if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove outside build'};if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force};New-Item -ItemType Directory -Path $resolved -Force|Out-Null}
function Run-WebGodot([string[]]$Arguments){
  $result=(& $Godot @Arguments 2>&1|Out-String)
  if($LASTEXITCODE -ne 0 -or $result -match 'SCRIPT ERROR:|ERROR:|Parse Error:'){
    [IO.File]::WriteAllText((Join-Path $buildRoot 'web-export-error.log'),$result)
    throw (($result -split "`n"|Select-String -Pattern 'SCRIPT ERROR:|ERROR:|Parse Error:' -Context 0,2|Out-String)+' See build/web-export-error.log')
  }
}
if(-not $SkipTests){& node (Join-Path $projectRoot 'tests\test_alpha_web.mjs');if($LASTEXITCODE-ne 0){throw 'Web unit fixtures failed'}}
Reset-WebDirectory $sourceRoot
Reset-WebDirectory $outputRoot
Reset-WebDirectory $mapRoot
foreach($name in @('project.godot','export_presets.cfg','scripts','scenes','assets','web')){Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $sourceRoot $name) -Recurse -Force}
$webSettingsPath=Join-Path $sourceRoot 'project.godot'
$webSettings=[IO.File]::ReadAllText($webSettingsPath).Replace('run/main_scene="res://scenes/release.tscn"','run/main_scene="res://scenes/web_boot.tscn"')
[IO.File]::WriteAllText($webSettingsPath,$webSettings,[Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'tools') -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build_web_maps.gd') -Destination (Join-Path $sourceRoot 'tools\build_web_maps.gd')
# Avoid copying .godot from the working tree: texture imports must target Web.
Run-WebGodot @('--headless','--path',$sourceRoot,'--editor','--import','--quit')
Run-WebGodot @('--headless','--path',$sourceRoot,'--script','res://tools/build_web_maps.gd','--',$mapRoot)
Run-WebGodot @('--headless','--path',$sourceRoot,'--export-release','Web Alpha',(Join-Path $outputRoot 'index.html'))
& node (Join-Path $PSScriptRoot 'build_web_pack.mjs') (Join-Path $outputRoot 'index.pck') $outputRoot $mapRoot $Version
if($LASTEXITCODE-ne 0){throw 'Web pack split failed'}
 $runtimeFiles=@(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'web') -File|Where-Object{$_.Extension -in @('.mjs','.css')}|Sort-Object Name)
 $runtimeFingerprints=($runtimeFiles|ForEach-Object{$_.Name+' '+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash})-join "`n"
 $runtimeHash=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($runtimeFingerprints)))).Replace('-','').ToLowerInvariant().Substring(0,16)
 $runtimeRelative='runtime/'+$runtimeHash
 $runtimeRoot=Join-Path $outputRoot $runtimeRelative
 New-Item -ItemType Directory -Path $runtimeRoot -Force|Out-Null
 foreach($file in $runtimeFiles){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtimeRoot $file.Name) -Force}
 $htmlPath=Join-Path $outputRoot 'index.html'
 $html=[IO.File]::ReadAllText($htmlPath).Replace('href="app.css"','href="'+$runtimeRelative+'/app.css"').Replace('src="app.mjs"','src="'+$runtimeRelative+'/app.mjs"')
 [IO.File]::WriteAllText($htmlPath,$html,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $outputRoot '_headers'),"/*.bin`n  Cache-Control: public, max-age=31536000, immutable`n/runtime/*`n  Cache-Control: public, max-age=31536000, immutable`n/content-manifest.json`n  Cache-Control: no-cache`n/index.html`n  Cache-Control: no-cache`n",[Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot 'copy_game_notices.ps1') -DestinationRoot $outputRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/BETA_TEST.md') -Destination (Join-Path $outputRoot 'PLAYTEST.md')
[IO.File]::WriteAllText((Join-Path $outputRoot 'credits.txt'),"AI Sims $Version — Godot 4.7.2 (MIT), Quaternius and Kenney (CC0). Full notices are in LICENSES/. File origins and hashes are in asset-manifest.json.",[Text.UTF8Encoding]::new($false))
$previousRoot=Join-Path $buildRoot 'web-previous'
if(Test-Path -LiteralPath $previousRoot){
  $checked=[IO.Path]::GetFullPath($previousRoot)
  if($checked -ne [IO.Path]::Combine($projectRoot,'build','web-previous')){throw 'Unexpected previous output path'}
  Remove-Item -LiteralPath $checked -Recurse -Force
}
if(Test-Path -LiteralPath $publishedRoot){[IO.Directory]::Move($publishedRoot,$previousRoot)}
try{[IO.Directory]::Move($outputRoot,$publishedRoot)}catch{
  if(Test-Path -LiteralPath $previousRoot){[IO.Directory]::Move($previousRoot,$publishedRoot)}
  throw
}
Write-Host "Web game ready: $publishedRoot"

$zipPath=Join-Path $buildRoot ("AI-Sims-Web-"+$Version+".zip")
Add-Type -AssemblyName System.IO.Compression.FileSystem
$nextZip=$zipPath+'.tmp'
if(Test-Path -LiteralPath $nextZip){Remove-Item -LiteralPath $nextZip}
[IO.Compression.ZipFile]::CreateFromDirectory($publishedRoot,$nextZip,[IO.Compression.CompressionLevel]::Fastest,$false)
Move-Item -LiteralPath $nextZip -Destination $zipPath -Force
$digest=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($zipPath+'.sha256',$digest+'  '+[IO.Path]::GetFileName($zipPath),[Text.UTF8Encoding]::new($false))
Write-Host "Browser package: $zipPath"

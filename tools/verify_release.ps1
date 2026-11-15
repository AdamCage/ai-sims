[CmdletBinding()]
param(
    [string]$Archive,
    [switch]$RendererSmoke
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = Join-Path $projectRoot 'build'
if (-not $Archive) { $Archive = Join-Path $buildRoot 'AI-Sims-Windows-x64.zip' }
$Archive = [IO.Path]::GetFullPath($Archive)
if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw "Archive not found: $Archive" }
$verificationRoot = Join-Path $buildRoot ('verification-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $verificationRoot -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-PublicPath([string]$Path) {
    if ($Path -match '(^|/)(\.env($|[./])|\.git($|/)|\.github($|/)|tests?($|/)|test-output($|/)|docs($|/)|tools($|/)|build($|/)|\.example($|/))' -or
        $Path -match '(^|/)(preview|animation_probe|profile_release|run_release_tests|run_tests|inspect_catalog)\.gd' -or
        $Path -match '(^|/)(test_[^/]*|[^/]*_(test|tests|probe))\.gd' -or
        $Path -match '(^|/)scripts/(ai|simulation|world|ui)/' -or
        $Path -match '(^|/)scripts/main\.gd' -or $Path -match '(^|/)scenes/main\.tscn' -or
        $Path -match '(?i)\.(key|pem|pfx|log|tpz|zip)$' -or $Path -match '^\.godot/editor/') {
        throw "Forbidden development or private file in release: $Path"
    }
}
function Read-PackDirectory([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt32() -ne 0x43504447) { throw 'Invalid standalone PCK magic.' }
        $format = $reader.ReadUInt32()
        if ($format -notin @(2,3,4)) { throw "Unsupported PCK format $format" }
        $engine = @($reader.ReadUInt32(),$reader.ReadUInt32(),$reader.ReadUInt32())
        if (($engine -join '.') -ne '4.7.2') { throw 'PCK engine version differs from the pinned toolchain.' }
        $flags = $reader.ReadUInt32()
        if (($flags -band 1) -ne 0) { throw 'Encrypted pack directory cannot be audited.' }
        $fileBase = $reader.ReadUInt64()
        if ($format -ge 3) { $directoryOffset = $reader.ReadUInt64(); $stream.Position = $directoryOffset }
        else { $stream.Position += 64 }
        $count = $reader.ReadUInt32()
        if ($count -lt 1 -or $count -gt 100000) { throw 'Invalid PCK entry count.' }
        $entries = @{}
        for ($index = 0; $index -lt $count; $index++) {
            $length = $reader.ReadUInt32()
            if ($length -lt 1 -or $length -gt 32768) { throw 'Invalid PCK entry path length.' }
            $name = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($length)).Trim([char]0)
            $name = $name -replace '^res://',''
            Assert-PublicPath $name
            if ($name -match '(^|/)\.\.(/|$)' -or $name.StartsWith('/') -or $name.Contains('\')) { throw 'Unsafe PCK entry path.' }
            $offset = $reader.ReadUInt64() + $fileBase
            $size = $reader.ReadUInt64()
            $null = $reader.ReadBytes(16)
            $entryFlags = $reader.ReadUInt32()
            if ($entryFlags -ne 0 -or $offset + $size -gt $stream.Length) { throw "Unsupported or invalid PCK entry: $name" }
            $entries[$name] = @{offset=$offset; size=$size}
        }
        return @{format=$format; entries=$entries}
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Read-PackedBytes([string]$Path, [hashtable]$Entry) {
    if ($Entry.size -gt 16777216) { throw 'Raw verification entry unexpectedly large.' }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $stream.Position = $Entry.offset
        $data = New-Object byte[] ([int]$Entry.size)
        $read = 0
        while ($read -lt $data.Length) {
            $amount = $stream.Read($data, $read, $data.Length - $read)
            if ($amount -eq 0) { throw 'Unexpected end of PCK.' }
            $read += $amount
        }
        return ,$data
    } finally { $stream.Dispose() }
}
function Test-ResourcePath([hashtable]$Entries, [string]$Path) {
    $relative = $Path -replace '^res://',''
    if ($Entries.ContainsKey($relative)) { return $true }
    foreach ($suffix in @('.remap','.import')) {
        if (-not $Entries.ContainsKey($relative + $suffix)) { continue }
        $mapping = [Text.Encoding]::UTF8.GetString((Read-PackedBytes $packPath $Entries[$relative + $suffix]))
        $references = [regex]::Matches($mapping, '(?m)^path(?:\.[A-Za-z0-9_]+)?="(res://[^"\r\n]+)"')
        if ($references.Count -eq 0) { return $false }
        foreach ($reference in $references) {
            if (-not $Entries.ContainsKey(($reference.Groups[1].Value -replace '^res://',''))) { return $false }
        }
        return $true
    }
    return $false
}

$zip = [IO.Compression.ZipFile]::OpenRead($Archive)
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName.Replace('\','/')
        if (-not $name -or $name.EndsWith('/')) { throw 'Unexpected directory entry in archive.' }
        $target = [IO.Path]::GetFullPath((Join-Path $verificationRoot $name))
        if (-not $target.StartsWith($verificationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe ZIP path.' }
        Assert-PublicPath $name
        if ($name -notmatch '^(AI-Sims\.(exe|pck)|README\.txt|CREDITS\.txt|build-info\.json|asset-manifest\.json|LICENSES/[A-Za-z0-9_-]+\.txt)$') { throw "Unexpected package file: $name" }
    }
} finally { $zip.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($Archive, $verificationRoot)
$checksumFile = $Archive + '.sha256'
$archiveHash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not (Test-Path -LiteralPath $checksumFile)) { throw 'Missing adjacent archive SHA256 file.' }
$expectedArchiveHash = ([IO.File]::ReadAllText($checksumFile) -split '\s+')[0].ToLowerInvariant()
if ($expectedArchiveHash -ne $archiveHash) { throw 'Archive SHA256 mismatch.' }
$metadata = Get-Content -LiteralPath (Join-Path $verificationRoot 'build-info.json') -Raw | ConvertFrom-Json
if ($metadata.platform -ne 'windows-x86_64') { throw 'Incorrect release platform.' }
foreach ($property in $metadata.files.PSObject.Properties) {
    $path = Join-Path $verificationRoot $property.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing package file: $($property.Name)" }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $property.Value) { throw "Package checksum mismatch: $($property.Name)" }
}
$expectedFiles = @($metadata.files.PSObject.Properties.Name) + @('build-info.json')
foreach ($file in Get-ChildItem -LiteralPath $verificationRoot -Recurse -File) {
    $relative = $file.FullName.Substring($verificationRoot.Length + 1).Replace('\','/')
    if ($relative -notin $expectedFiles) { throw "Package file is absent from checksum manifest: $relative" }
}
foreach ($required in @('AI-Sims.exe','AI-Sims.pck','README.txt','CREDITS.txt','asset-manifest.json','LICENSES/Godot-LICENSE.txt','LICENSES/Godot-COPYRIGHT.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $verificationRoot $required))) { throw "Missing release file: $required" }
}

$packPath = Join-Path $verificationRoot 'AI-Sims.pck'
$pack = Read-PackDirectory $packPath
foreach ($required in @('assets/release/asset_manifest.json','assets/release/bin/credential_bridge.exe','assets/release/licenses/Kenney-Furniture.txt','assets/release/licenses/Original-Art.txt','assets/release/licenses/Quaternius-Animations.txt','assets/release/licenses/Quaternius-Characters.txt')) {
    if (-not $pack.entries.ContainsKey($required)) { throw "Missing raw PCK file: $required" }
}
if (-not (Test-ResourcePath $pack.entries 'scenes/release.tscn') -or -not (Test-ResourcePath $pack.entries 'scripts/release_main.gd')) { throw 'Release entry scene or script is absent from PCK.' }
$helper = Read-PackedBytes $packPath $pack.entries['assets/release/bin/credential_bridge.exe']
$helperHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($helper)).Replace('-','').ToLowerInvariant()
if ($helperHash -ne $metadata.credential_bridge_sha256) { throw 'Packed credential helper checksum mismatch.' }
if ($helper.Length -lt 2 -or $helper[0] -ne 0x4d -or $helper[1] -ne 0x5a) { throw 'Packed credential helper is not a Windows executable.' }
$manifestData = Read-PackedBytes $packPath $pack.entries['assets/release/asset_manifest.json']
$manifest = [Text.Encoding]::UTF8.GetString($manifestData) | ConvertFrom-Json
if ((Get-FileHash -LiteralPath (Join-Path $verificationRoot 'asset-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ne [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($manifestData)).Replace('-','').ToLowerInvariant()) { throw 'Packed and external asset manifests differ.' }
$resourceCount = 0
foreach ($property in $manifest.models.PSObject.Properties) {
    if (-not (Test-ResourcePath $pack.entries ([string]$property.Value))) { throw "Missing manifest model: $($property.Name)" }
    $resourceCount++
}
foreach ($material in $manifest.textures.PSObject.Properties) {
    foreach ($channel in $material.Value.PSObject.Properties) {
        if (-not (Test-ResourcePath $pack.entries ([string]$channel.Value))) { throw "Missing texture: $($material.Name)/$($channel.Name)" }
        $resourceCount++
    }
}

# The helper is audited as bytes. Never execute its real credential get operation here.
# --test-profile skips the user's key and redirects saves/ledger to a test profile.
$stdoutPath = Join-Path $buildRoot 'release-smoke.stdout.log'
$stderrPath = Join-Path $buildRoot 'release-smoke.stderr.log'
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = Join-Path $verificationRoot 'AI-Sims.exe'
$start.Arguments = '--headless --quit-after 8 -- --test-profile'
if ($RendererSmoke) { $start.Arguments = '--rendering-method gl_compatibility --resolution 1280x720 --quit-after 120 -- --test-profile' }
$start.WorkingDirectory = $verificationRoot
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = New-Object Diagnostics.Process
$process.StartInfo = $start
if (-not $process.Start()) { throw 'Could not launch standalone export.' }
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(180000)) { $process.Kill(); throw 'Standalone export timed out.' }
$process.WaitForExit()
[IO.File]::WriteAllText($stdoutPath, $stdout.Result)
[IO.File]::WriteAllText($stderrPath, $stderr.Result)
$output = $stdout.Result + "`n" + $stderr.Result
if ($process.ExitCode -ne 0 -or $output -match '(?m)^(SCRIPT ERROR:|ERROR:|Parse Error:|USER ERROR:)') { throw "Standalone export failed. Inspect $stdoutPath and $stderrPath" }
$report = [ordered]@{
    archive=[IO.Path]::GetFileName($Archive); archive_sha256=$archiveHash;
    verified_utc=[DateTime]::UtcNow.ToString('o'); version=$metadata.version;
    archive_integrity='passed'; pck_format=$pack.format; pck_entries=$pack.entries.Count;
    manifest_resource_references=$resourceCount; packed_credential_helper='passed';
    startup='passed'; renderer_smoke=[bool]$RendererSmoke; test_profile=$true;
    offline_tests=$metadata.offline_tests;
    png_encoder_tests=$(if ('png_encoder_tests' -in $metadata.PSObject.Properties.Name) { $metadata.png_encoder_tests } else { 'not_recorded' });
    live_ai='not_run'; target_hardware_performance='not_run';
    extraction_directory=$verificationRoot
}
$reportPath = Join-Path $buildRoot 'release-verification.json'
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Write-Host "Verified archive integrity, $($pack.entries.Count) PCK files, $resourceCount manifest resources, packed credential helper and standalone startup."
Write-Host "Verification report: $reportPath"
Write-Host "Extracted standalone package: $verificationRoot"

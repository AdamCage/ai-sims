[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DestinationRoot)
$ErrorActionPreference="Stop"
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$licenseRoot = Join-Path $DestinationRoot 'LICENSES'
New-Item -ItemType Directory -Path $licenseRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\release\asset_manifest.json') -Destination (Join-Path $DestinationRoot 'asset-manifest.json')
Get-ChildItem -LiteralPath (Join-Path $projectRoot 'assets\release\licenses') -File -Filter '*.txt' | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $licenseRoot }
$licenseCache = Join-Path $projectRoot 'build/toolchain-licenses'
New-Item -ItemType Directory -Path $licenseCache -Force | Out-Null
$engineNotices = @{
    'LICENSE.txt' = 'b0435e3b3e4e55238f05f4b306f30524a1b2e20147810d436eaa554fa6855c80';
    'COPYRIGHT.txt' = 'cb1980c88089573bcacd7221d777c689bb8bbd778799f24c27fca0fe5f774d6d'
}
foreach ($name in $engineNotices.Keys) {
    $cached = Join-Path $licenseCache $name
    if (-not (Test-Path -LiteralPath $cached)) {
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/$name" -OutFile $cached
    }
    if ((Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash.ToLowerInvariant() -ne $engineNotices[$name]) { throw "Godot license checksum mismatch: $name" }
    Copy-Item -LiteralPath $cached -Destination (Join-Path $licenseRoot ('Godot-' + $name))
}

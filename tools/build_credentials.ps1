$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$outputDir = Join-Path $projectRoot 'assets\release\bin'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
& $compilerPath /nologo /optimize+ /target:winexe "/out:$outputDir\credential_bridge.exe" (Join-Path $PSScriptRoot 'CredentialBridge.cs')
if ($LASTEXITCODE -ne 0) { throw 'Credential bridge compilation failed' }

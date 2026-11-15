[CmdletBinding()]
param(
    [string]$Godot = $env:GODOT_BIN,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.2.0',
    [switch]$SkipTests,
    [switch]$SkipVerify
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = Join-Path $projectRoot 'build'
$sourceRoot = Join-Path $buildRoot 'release-source'
$packageRoot = Join-Path $buildRoot 'AI-Sims-Windows-x64'
$logRoot = Join-Path $buildRoot 'release-logs'
$archivePath = Join-Path $buildRoot 'AI-Sims-Windows-x64.zip'
$engineVersion = '4.7.2'
if (-not $Godot) { $Godot = Join-Path $env:USERPROFILE '.codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe' }
$Godot = [IO.Path]::GetFullPath($Godot)
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) { throw 'Godot 4.7.2 console executable not found. Supply -Godot or GODOT_BIN.' }

function Reset-BuildDirectory([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $allowed = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\') + '\'
    if (-not $absolute.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to reset outside build directory: $absolute" }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    New-Item -ItemType Directory -Path $absolute -Force | Out-Null
}
function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-Engine([string]$Name, [string[]]$EngineArguments, [int]$TimeoutSeconds = 300) {
    $log = Join-Path $logRoot ($Name + '.log')
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Godot
    $start.Arguments = ($EngineArguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    $start.WorkingDirectory = $projectRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "Could not start Godot ($Name)." }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); throw "Godot timed out ($Name)." }
    $process.WaitForExit()
    $output = $stdout.Result + [Environment]::NewLine + $stderr.Result
    [IO.File]::WriteAllText($log, ($output + "`nPROCESS_EXIT_CODE=" + $process.ExitCode), (New-Object Text.UTF8Encoding($false)))
    if ($process.ExitCode -ne 0 -or $output -match '(?m)^(SCRIPT ERROR:|ERROR:|Parse Error:|USER ERROR:)') {
        throw "Godot failed ($Name, exit $($process.ExitCode)). Inspect $log"
    }
    return $output
}
function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

New-Item -ItemType Directory -Path $buildRoot, $logRoot -Force | Out-Null
$reportedVersion = (& $Godot --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $reportedVersion -notmatch '^4\.7\.2\.stable') { throw "Expected Godot 4.7.2 stable; received $reportedVersion" }
$templateRoot = Join-Path $env:APPDATA 'Godot\export_templates\4.7.2.stable'
$template = Join-Path $templateRoot 'windows_release_x86_64.exe'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { throw "Windows x64 release export template missing: $template. See docs/RELEASE_BUILD.md." }
# Snapshot source provenance before compiling the generated helper. The legacy
# Framework compiler can change its executable metadata on every compilation.
$gitCommit = (& git -C $projectRoot rev-parse HEAD 2>$null | Out-String).Trim()
$dirty = [bool]((& git -C $projectRoot status --porcelain 2>$null | Out-String).Trim())

Write-Host 'Compiling local Windows Credential Manager helper...'
& (Join-Path $PSScriptRoot 'build_credentials.ps1')
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'assets\release\bin\credential_bridge.exe'))) { throw 'Credential helper was not generated.' }
$offlineStatus = 'skipped'
$pngStatus = 'skipped'
if (-not $SkipTests) {
    Write-Host 'Running offline release suites...'
    $testOutput = Invoke-Engine 'offline-tests' @('--headless', '--path', $projectRoot, '--script', 'res://tests/run_release_tests.gd', '--', '--test-profile') 1800
    if ($testOutput -notmatch 'RELEASE RESULT: 0 failures') { throw 'Offline tests did not report successful completion.' }
    $offlineStatus = 'passed'
    Write-Host 'Running headless lossless PNG encoder lifecycle checks...'
    $pngOutput = Invoke-Engine 'png-encoder-tests' @('--headless', '--path', $projectRoot, '--script', 'res://tests/png_encoder_qa.gd', '--', '--test-profile') 120
    $pngResult = [regex]::Match($pngOutput, 'PNG ENCODER QA: ([0-9]+) checks; 0 failures')
    if (-not $pngResult.Success -or [int]$pngResult.Groups[1].Value -lt 9) { throw 'PNG encoder suite did not report all required checks passing.' }
    $pngStatus = 'passed'
} else { Write-Warning 'Offline suites explicitly skipped. This package still requires acceptance testing.' }

Reset-BuildDirectory $sourceRoot
Reset-BuildDirectory $packageRoot
$files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($relative in @('project.godot', 'export_presets.cfg', 'scenes\release.tscn', 'scripts\release_main.gd', 'assets\icon.svg')) {
    $files.Add((Get-Item -LiteralPath (Join-Path $projectRoot $relative)))
}
$excludedScripts = @('run_release_tests.gd', 'profile_release.gd', 'run_tests.gd', 'inspect_catalog.gd', 'preview.gd', 'animation_probe.gd', 'flow_probe.gd')
foreach ($directory in @('scripts\game', 'scripts\release_ai', 'scripts\release_world', 'scripts\release_ui', 'scripts\release_storage')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot $directory) -Recurse -File) {
        $scriptName = $file.Name -replace '\.uid$',''
        if ($file.Extension -in @('.gd', '.gdshader', '.uid') -and $scriptName -notin $excludedScripts -and $scriptName -notmatch '(^test_|_test\.gd$|_tests\.gd$|_probe\.gd$)') { $files.Add($file) }
    }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'assets\release') -Recurse -File) {
    if ($file.Extension -in @('.glb', '.png', '.svg', '.wav', '.json', '.txt', '.import') -or $file.FullName -eq (Join-Path $projectRoot 'assets\release\bin\credential_bridge.exe')) { $files.Add($file) }
}
foreach ($file in $files | Sort-Object FullName -Unique) {
    $relative = $file.FullName.Substring($projectRoot.Length + 1)
    $destination = Join-Path $sourceRoot $relative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination
}
$stagedPreset = Join-Path $sourceRoot 'export_presets.cfg'
$preset = [IO.File]::ReadAllText($stagedPreset) -replace 'application/file_version="[^"]*"', ('application/file_version="' + $Version + '.0"') -replace 'application/product_version="[^"]*"', ('application/product_version="' + $Version + '.0"')
Write-Utf8 $stagedPreset $preset
$stagedProject = Join-Path $sourceRoot 'project.godot'
$project = [IO.File]::ReadAllText($stagedProject)
$project = $project -replace '(?m)^config/version=.*\r?\n',''
$project = $project -replace '(?m)^config/name="AI Sims"', ('config/name="AI Sims"' + "`n" + 'config/version="' + $Version + '"')
Write-Utf8 $stagedProject $project
$sourceHashes = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Sort-Object FullName) {
    $relative = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\','/')
    $sourceHashes.Add(($relative + ' ' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()))
}
$sourceHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(($sourceHashes -join "`n")))).Replace('-','').ToLowerInvariant()

Write-Host 'Importing the clean runtime source copy...'
$null = Invoke-Engine 'import' @('--headless', '--path', $sourceRoot, '--editor', '--import') 600
Write-Host 'Exporting Windows x64 EXE and PCK...'
$null = Invoke-Engine 'export' @('--headless', '--path', $sourceRoot, '--export-release', 'Windows Desktop', (Join-Path $packageRoot 'AI-Sims.exe')) 600
foreach ($required in @('AI-Sims.exe','AI-Sims.pck')) {
    if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $required))) { throw "Missing export: $required" }
}

$licenseRoot = Join-Path $packageRoot 'LICENSES'
New-Item -ItemType Directory -Path $licenseRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\release\asset_manifest.json') -Destination (Join-Path $packageRoot 'asset-manifest.json')
Get-ChildItem -LiteralPath (Join-Path $projectRoot 'assets\release\licenses') -File -Filter '*.txt' | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $licenseRoot }
$licenseCache = Join-Path $buildRoot 'toolchain-licenses'
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
Write-Utf8 (Join-Path $packageRoot 'CREDITS.txt') @"
AI Sims $Version

Godot Engine 4.7.2 (MIT), https://godotengine.org/
Full engine and bundled library notices: LICENSES/Godot-LICENSE.txt and Godot-COPYRIGHT.txt.
Characters and animation: Quaternius, CC0, https://quaternius.com/
Furniture: Kenney, CC0, https://kenney.nl/
Original tileable textures, clothing assembly and sound effects: AI Sims, CC0.
Asset provenance and hashes: asset-manifest.json. Detailed asset notices: LICENSES/.
Third-party asset licenses do not change the ownership or license of the game code.
"@
Write-Utf8 (Join-Path $packageRoot 'README.txt') @"
AI Sims $Version — Windows 10/11 x64

РУССКИЙ
Распакуйте весь ZIP в доступную для записи папку и запустите AI-Sims.exe.
AI-Sims.pck должен оставаться рядом с EXE. Установка Godot, Python и редактора не требуется.
Для 3D нужен поддерживаемый графическим драйвером режим OpenGL Compatibility.
Локальный помощник для Windows Credential Manager использует системный .NET Framework 4.x.

Начните с главного меню: карта, сценарий, число персонажей и новая сессия.
Демонстрационный режим работает локально без ключа и не является настоящим AI.
Настоящий AI включается явно в настройках RouterAI; он требует личного ключа и оплачиваемого API.
Ключ хранится в Windows Credential Manager. Сохранения и журнал расхода находятся в пользовательских данных Godot/AI Sims.
Лимит расходов в настройках ограничивает новые запросы; при неизвестной стоимости проверяйте баланс у провайдера.
Переключение RU/EN, качество, звук и скорость доступны в настройках.
Мышь: выбор персонажа левой кнопкой; средняя кнопка — панорама; правая — вращение; колесо — масштаб.
Используйте экранные кнопки для запуска/паузы, наблюдения от первого лица, редактора и вмешательств.

ENGLISH
Extract the complete ZIP and run AI-Sims.exe with AI-Sims.pck alongside it.
No Godot editor or Python installation is needed. The credential helper uses Windows .NET Framework 4.x.
Choose a map, scenario and population in the main menu. Local demo mode needs no API key.
Real AI is an explicit RouterAI setting and uses your own paid API account.
Keys stay in Windows Credential Manager; saves and spending records use Godot's per-user AI Sims data folder.
Use the on-screen controls for play/pause, first-person observation, customization, saves and interventions.
Middle mouse pans, right mouse orbits, and the wheel zooms. Settings include RU/EN and graphics quality.

Integrity and attribution: build-info.json, asset-manifest.json, CREDITS.txt and LICENSES/.
This build process does not certify performance on the target minimum GPU or live AI acceptance.
"@
$payloadHashes = [ordered]@{}
foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Sort-Object FullName) {
    $payloadHashes[$file.FullName.Substring($packageRoot.Length + 1).Replace('\','/')] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$metadata = [ordered]@{
    product='AI Sims'; version=$Version; platform='windows-x86_64'; engine=$reportedVersion;
    build_utc=[DateTime]::UtcNow.ToString('o'); git_commit=$gitCommit; source_dirty=$dirty;
    runtime_source_sha256=$sourceHash; offline_tests=$offlineStatus; png_encoder_tests=$pngStatus;
    engine_executable_sha256=(Get-FileHash -LiteralPath $Godot -Algorithm SHA256).Hash.ToLowerInvariant();
    export_template_sha256=(Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant();
    credential_bridge_sha256=(Get-FileHash -LiteralPath (Join-Path $projectRoot 'assets\release\bin\credential_bridge.exe') -Algorithm SHA256).Hash.ToLowerInvariant();
    real_ai_acceptance='not_run_by_build'; target_gpu_acceptance='not_run_by_build'; files=$payloadHashes
}
Write-Utf8 (Join-Path $packageRoot 'build-info.json') ($metadata | ConvertTo-Json -Depth 8)

Write-Host 'Creating release ZIP...'
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($packageRoot, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Utf8 ($archivePath + '.sha256') ($archiveHash + '  ' + [IO.Path]::GetFileName($archivePath) + "`n")
if (-not $SkipVerify) { & (Join-Path $PSScriptRoot 'verify_release.ps1') -Archive $archivePath }
Write-Host "Release archive: $archivePath"
Write-Host "SHA256: $archiveHash"
Write-Host "Offline suites: $offlineStatus. Hardware and paid-AI acceptance are recorded separately."

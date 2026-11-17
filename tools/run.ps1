param(
    [string]$Godot = $env:GODOT_BIN,
    [switch]$Tests,
    [switch]$Smoke,
    [switch]$AutoRun,
    [ValidateSet('closed_block','residence','research_station')][string]$Map = 'closed_block',
    [ValidateSet('episode','sandbox','scarcity','last_ration','deception')][string]$Scenario = 'episode',
    [ValidateRange(3,20)][int]$Agents = 8,
    [switch]$LegacyTests
)
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Godot) {
    $installed = Get-Command godot, godot4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($installed) { $Godot = $installed.Source }
}
if (-not $Godot) {
    $cachedEngine = Join-Path $env:USERPROFILE '.codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe'
    if (Test-Path -LiteralPath $cachedEngine) { $Godot = $cachedEngine }
}
if (-not $Godot -or -not (Test-Path -LiteralPath $Godot)) {
    throw 'Set GODOT_BIN to a Godot 4.7.2 executable, put godot on PATH, or pass -Godot <absolute path>.'
}
$engineArguments = @('--path', $projectRoot)
if ($LegacyTests) { $engineArguments += @('--headless', '--script', 'res://tests/run_tests.gd') }
elseif ($Tests) { $engineArguments += @('--headless', '--script', 'res://tests/run_release_tests.gd','--','--test-profile') }
elseif ($Smoke) { $engineArguments += @('--script', 'res://tests/release_ui_qa.gd','--','--test-profile') }
else {
    $engineArguments += '--'
    if ($AutoRun -or $PSBoundParameters.ContainsKey('Map') -or $PSBoundParameters.ContainsKey('Agents') -or $PSBoundParameters.ContainsKey('Scenario')) {
        $engineArguments += @("--scenario=$Scenario", "--map=$Map", "--agents=$Agents")
    }
    if ($AutoRun) { $engineArguments += '--auto-run' }
}
& $Godot @engineArguments
exit $LASTEXITCODE

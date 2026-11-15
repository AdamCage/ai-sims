param(
    [string]$Godot = $env:GODOT_BIN,
    [switch]$Tests,
    [switch]$Smoke,
    [switch]$AutoRun,
    [ValidateSet('closed_block', 'last_ration')][string]$Scenario = 'closed_block'
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
if ($Tests) { $engineArguments += @('--headless', '--script', 'res://tests/run_tests.gd') }
elseif ($Smoke) { $engineArguments += @('--script', 'res://tests/render_smoke.gd') }
else {
    $engineArguments += @('--', "--scenario=$Scenario")
    if ($AutoRun) { $engineArguments += '--auto-run' }
}
& $Godot @engineArguments
exit $LASTEXITCODE

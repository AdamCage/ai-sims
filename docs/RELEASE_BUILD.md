# Сборка браузерной версии

В Windows установите Godot 4.7.2 со стандартными web export templates и Node.js. Из корня репозитория выполните следующую команду.

```powershell
.\tools\build_web.ps1
python -m http.server 8732 --bind 127.0.0.1 --directory build/web
```

Откройте [AI Sims](http://127.0.0.1:8732/). Для распространения отдавайте всё содержимое `build/web` с одного статического HTTPS-адреса. Обычный HTTP работает на loopback. Приложение использует WebGL 2, WebAssembly, Web Locks, IndexedDB и DecompressionStream. Браузеру нужен доступ к файлам при первой загрузке карты. Для подключения RouterAI ему также нужен выход к провайдеру.

Экспорт использует одиночный поток Godot и отдельный JS-воркер для PNG. Имена пакетов, скриптов и движка содержат хеши. Обновляйте сборку целиком. Для сохранения старых игр используйте прежний origin. Перед сменой домена игрок может скачать резервную копию.

# Windows standalone release build

The release package is a Windows 10/11 x64 Godot export: `AI-Sims.exe` plus `AI-Sims.pck`, attribution, asset provenance and checksum metadata. It does not need an installed Godot editor or Python. The local Windows Credential Manager bridge is compiled against the system .NET Framework 4.x and embedded as a raw PCK file. API credentials, saves and spending ledgers are user data and are never part of the package.

## Build prerequisites

- Windows x64, Windows PowerShell 5.1 or PowerShell 7, Git and the Windows .NET Framework C# compiler at `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`.
- Standard Godot **4.7.2 stable**, including the console executable. Set `GODOT_BIN` or supply `-Godot`. The local fallback is `%USERPROFILE%\.codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe`.
- Matching standard export templates. The Windows x64 release template must exist at `%APPDATA%\Godot\export_templates\4.7.2.stable\windows_release_x86_64.exe`.
- First build: internet access for the pinned Godot license and third-party notices. Subsequent builds use `build/toolchain-licenses/`; both files are checked against fixed SHA256 values before redistribution.

Download the engine, matching templates and `SHA512-SUMS.txt` from the [official 4.7.2 release](https://github.com/godotengine/godot-builds/releases/tag/4.7.2-stable). Check downloads against the official sums. Install the templates through Godot's template manager, or extract `templates/windows_release_x86_64.exe`, its console wrapper, and `templates/version.txt` into the directory above. Web templates alone do not provide Windows export support. See [Godot Windows export documentation](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_windows.html).

## Commands

From the repository root:

```powershell
./tools/build_release.ps1
# Or choose the installed engine and release version:
./tools/build_release.ps1 -Godot 'C:\tools\Godot_v4.7.2-stable_win64_console.exe' -Version '0.2.0'
```

The script compiles the credential helper, runs `tests/run_release_tests.gd` and the separate headless `tests/png_encoder_qa.gd` lossless-worker/lifecycle suite (at least nine successful checks required), copies an allowlist of runtime source/assets into `build/release-source/`, imports that clean project, exports the release preset, adds notices and metadata, packages the ZIP, and verifies the extracted artifact. It does not call a paid AI provider. The process fails on a nonzero exit or Godot script/engine errors, including errors that Godot sometimes reports while exiting with code zero.

`-SkipTests` and `-SkipVerify` are explicit iteration options. A package created with either option still needs the omitted checks. `build-info.json` records whether the offline suites and PNG encoder suite ran. The build process cannot establish real AI quality or minimum hardware performance.

Outputs:

- `build/AI-Sims-Windows-x64.zip` and `.zip.sha256` — distributable candidate and integrity checksum.
- `build/AI-Sims-Windows-x64/` — the uncompressed package.
- `build/release-logs/` — import, export and offline suite logs.
- `build/release-verification.json`, `build/release-smoke.stdout.log`, `build/release-smoke.stderr.log` — archive and standalone startup evidence.
- `build/verification-<id>/` — the extracted package used for the standalone smoke test; it can be launched manually for visual review.

Only `project.godot`, the release scene/main script, release runtime directories, and whitelisted `assets/release/` resources are copied into the clean export project. Test drivers, preview/profiling scripts, legacy code, documentation, screenshots, tool/source download caches and secret file types are omitted. Godot's runtime `.godot/imported` resources are necessary packed game data; editor caches are omitted. Raw asset manifests, license TXT files and `credential_bridge.exe` are explicitly retained by `export_presets.cfg`.

The package contains `build-info.json` with engine/template/helper hashes, the Git revision, pre-build dirty state, a runtime source fingerprint and a hash for each shipped file. Git state is captured before helper compilation, which may update generated executable metadata even for unchanged C# source. `asset-manifest.json` preserves asset provenance; the same manifest is packed for runtime use. This gives a repeatable, pinned build process and traceable artifacts. It is not a promise of byte-identical ZIPs: the build timestamp, ZIP timestamps, native compiler metadata and engine import output may change.

## Verify an existing candidate

```powershell
./tools/verify_release.ps1
./tools/verify_release.ps1 -Archive 'C:\releases\AI-Sims-Windows-x64.zip'
# Optional local OpenGL Compatibility startup check; this is not a visual review:
./tools/verify_release.ps1 -RendererSmoke
```

Verification checks ZIP path safety, a strict package file allowlist, SHA256 integrity and all per-file hashes. It parses the unencrypted PCK directory, rejects development/private paths, checks the raw credential helper's content/hash, requires asset license notices and validates every model/texture reference in the packed asset manifest. It then launches **the extracted release EXE** from the extraction folder, not the editor or source project. Startup always passes `-- --test-profile`, which skips the user's stored credential and redirects session/ledger writes into a test profile. The helper's real credential target is never read by this verifier.

Default startup is `--headless --quit-after 8`. Optional renderer startup uses OpenGL Compatibility, 1280×720 and 120 frames. Neither mode certifies functional UI flows, FPS, long-session stability, audio quality, live paid AI decisions or Windows machines with different installed software. Record those in the release acceptance report, with actual hardware and results.

The standard 4.7.2 release executable does not expose `--script` in its help and ignores an external GDScript driver, even when that path does not exist. Do not interpret normal startup with that argument as a successful UI test. Run the automated renderer driver with the editor executable against source, and separately review the actual extracted release EXE through native UI interaction. The release package does not contain test drivers.

## Manual CI and publication

The **Build Windows release candidate** GitHub Actions workflow is `workflow_dispatch` only. It downloads Godot 4.7.2 and matching templates, checks the official SHA512 sums, builds with offline suites enabled, verifies the standalone candidate and uploads artifacts. It has read-only repository permissions and does not publish releases or call RouterAI.

Before publication, use a fresh candidate built from the final reviewed revision with the default checks enabled. Review all three maps and supported population sizes, RU/EN UI, customization, camera controls, saves/loading/replay, interventions, observer/private views and bounded real AI behavior. Test the standalone package on the actual minimum target and on a clean Windows account or machine without Godot/Python. Record GPU/driver, resolution, preset, FPS/frame-time and session duration. A stronger development GPU is not minimum-GPU evidence.

After acceptance, the owner can manually create a draft GitHub release (or equivalent store draft), attach the ZIP and its SHA256, and include the reviewed change list, install instructions, measured system requirements, third-party credits and known limitations. Review the draft and explicitly publish it. No packaging command creates a release, pushes a branch or publishes a store page.

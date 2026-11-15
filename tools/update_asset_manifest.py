"""Hash distributable original/source-derived art; no runtime Python dependency.

Run after rebuilding/importing characters and materials. --check verifies without
rewriting. The credential binary is compiled and verified by build_release.ps1.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "assets/release"
MANIFEST = BASE / "asset_manifest.json"

def inventory():
    return [{"path": path.relative_to(ROOT).as_posix(),
             "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
             "bytes": path.stat().st_size}
            for path in sorted(BASE.rglob("*"))
            if path.is_file() and path.suffix.lower() in {".glb", ".png", ".wav"}]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    actual = inventory()
    if options.check:
        if manifest.get("files") != actual:
            raise SystemExit("Asset hashes are stale. Run tools/update_asset_manifest.py.")
        print(f"Verified {len(actual)} art files")
    else:
        manifest["files"] = actual
        MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Updated {len(actual)} art hashes")

if __name__ == "__main__":
    main()

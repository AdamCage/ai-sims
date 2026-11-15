"""Recreate CC0 source cache and Kenney props used by build_characters.py.

Only public free Standard downloads are used; there is no purchase or login.
The committed GLBs work directly, so normal builds do not need this script.
"""
import argparse
import hashlib
import http.cookiejar
import json
from pathlib import Path
import re
import shutil
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "test-output/asset-downloads"
MIRROR_REVISION = "3694c6879e487c108f55677be7dd2ca75b07cc3b"
PACKS = [
    ("universal-base-characters", "15861669", "fdbf1804c90dfc1ea03e992bff7da2dfd1a79318e13270a660180f9308455f40"),
    ("universal-animation-library", "17958403", "cc73fc4e495b82958207316596317a3f40b9fa38065bde1027937452da537724"),
]
PROPS = ["bedSingle", "bedBunk", "bookcaseOpen", "cabinetBed", "cardboardBoxClosed", "chair", "chairDesk", "desk", "table", "tableRound", "kitchenFridge", "pottedPlant", "computerScreen", "computerKeyboard", "lampRoundFloor", "lampSquareTable", "bathroomSink", "toilet", "rugRectangle", "televisionModern", "trashcan"]

def digest(path):
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()

def request(opener, url, fields=None):
    data = urllib.parse.urlencode(fields).encode() if fields is not None else None
    packet = urllib.request.Request(url, data=data, headers={"User-Agent": "AI-Sims-CC0-asset-builder/1", "Referer": "https://quaternius.itch.io/"})
    return opener.open(packet, timeout=90)

def csrf(html):
    match = re.search(r'<meta name="csrf_token" (?:value|content)="([^"]+)"', html)
    if not match:
        raise RuntimeError("Public itch.io download form changed; no purchase will be attempted.")
    return match.group(1)

def fetch_pack(slug, upload, expected, cache_only):
    archive = CACHE / (slug + ".zip")
    if not archive.exists() or digest(archive) != expected:
        if cache_only:
            raise RuntimeError(f"Missing verified source archive: {archive.name}")
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        base = "https://quaternius.itch.io/" + slug
        html = request(opener, base).read().decode()
        download = json.load(request(opener, base + "/download_url", {"csrf_token": csrf(html)}))
        html = request(opener, download["url"]).read().decode()
        link = json.load(request(opener, base + "/file/" + upload, {"csrf_token": csrf(html)}))["url"]
        temporary = archive.with_suffix(".download")
        with request(opener, link) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        if digest(temporary) != expected:
            temporary.unlink()
            raise RuntimeError(f"Upstream archive changed: {slug}; review source/license before updating its pinned hash.")
        temporary.replace(archive)
    extracted = CACHE / slug
    if not extracted.exists():
        extracted.mkdir()
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                destination = (extracted / member.filename).resolve()
                if not destination.is_relative_to(extracted.resolve()):
                    raise RuntimeError("Unsafe source archive path")
            source.extractall(extracted)
    print(f"Verified CC0 source: {slug}")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-only", action="store_true", help="Verify local archives without network access")
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    (ROOT / "test-output/.gdignore").touch()
    for pack in PACKS:
        fetch_pack(*pack, args.cache_only)
    props = ROOT / "assets/release/props"
    props.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "assets/release/asset_manifest.json").read_text(encoding="utf-8"))
    expected = {Path(x["path"]).name: x["sha256"] for x in manifest["files"]}
    for name in PROPS:
        target = props / (name + ".glb")
        if not target.exists():
            if args.cache_only:
                raise RuntimeError(f"Missing prop {target.name}")
            url = f"https://raw.githubusercontent.com/shorepine/kenney/{MIRROR_REVISION}/3d/furniture/{target.name}"
            with urllib.request.urlopen(url, timeout=60) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
        if digest(target) != expected.get(target.name):
            raise RuntimeError(f"Prop hash mismatch: {target.name}")
    print(f"Verified {len(PROPS)} CC0 props at {MIRROR_REVISION}")

if __name__ == "__main__":
    main()

"""macOS Safari acceptance with Apple's native safaridriver.

    safaridriver --enable
    python3 -m venv /tmp/ai-sims-safari
    /tmp/ai-sims-safari/bin/pip install selenium
    /tmp/ai-sims-safari/bin/python tests/browser_safari.py --url http://localhost:8732/

"""
import argparse
import base64
import hashlib
import json
import platform
import struct
import time
from pathlib import Path

from selenium import webdriver
from selenium.common.exceptions import WebDriverException
from selenium.webdriver.common.actions.action_builder import ActionBuilder
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait


def visit(url):
    browser = webdriver.Safari()
    browser.get(url)
    extra = browser.execute_script("return [outerWidth-innerWidth, outerHeight-innerHeight]")
    try:
        browser.set_window_size(1440 + extra[0], 946 + extra[1])
    except WebDriverException:
        browser.maximize_window()
    WebDriverWait(browser, 150).until(lambda d: d.execute_script("return document.querySelector('#boot').hidden"))
    # Preserve the tested game aspect ratio on smaller macOS runner displays.
    browser.execute_script("""
      const main = document.querySelector('main');
      const factor = Math.min(1,innerWidth/1440,(innerHeight-main.offsetTop)/900);
      main.style.width = Math.floor(1440*factor) + 'px';
      main.style.height = Math.floor(900*factor) + 'px';
    """)
    return browser


def tap(browser, x, y):
    position = browser.execute_script("""
      const b=document.querySelector('canvas').getBoundingClientRect();
      return [Math.round(b.x+b.width*arguments[0]/1440),Math.round(b.y+b.height*(arguments[1]-46)/900)];
    """, x, y)
    actions = ActionBuilder(browser)
    actions.pointer_action.move_to_location(*position)
    actions.pointer_action.click()
    actions.perform()


def export_copy(browser):
    # Observe the exact downloadable Blob before Safari hands it to Finder.
    # The temporary automation session need not change Safari download preferences.
    browser.execute_script("""
      window.testBackup = null;
      if (!window.copyObserved) {
        window.copyObserved = true;
        const click = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function() {
          if (this.download !== 'AI-Sims.aisims') return click.call(this);
          fetch(this.href).then(r => r.blob()).then(blob => {
            const reader = new FileReader();
            reader.onload = () => window.testBackup = reader.result.split(',')[1];
            reader.readAsDataURL(blob);
          });
        };
      }
    """)
    browser.find_element(By.ID, "backup").click()
    WebDriverWait(browser, 150).until(lambda d: d.execute_script("return Boolean(window.testBackup)"))
    return base64.b64decode(browser.execute_script("return window.testBackup"))


def validate_copy(data):
    assert data[:4] == b"AIS2"
    offset = struct.unpack(">I", data[4:8])[0] + 8
    manifest = json.loads(data[8:offset])
    for item in manifest["media"]:
        end = offset + item["size"]
        assert hashlib.sha256(data[offset:end]).hexdigest() == item["hash"]
        offset = end
    assert offset == len(data)
    payload = json.loads(json.loads(manifest["slots"]["slot_3.json"])["payload"])["data"]
    return payload["world"]["world"], manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:8732/")
    parser.add_argument("--output", type=Path, default=Path("test-output/beta-browser-safari"))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Apple Safari and its driver require macOS.")
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"platform":platform.platform(), "url":args.url, "scenarios":[]}
    browser = visit(args.url)
    try:
        report["browser"] = browser.capabilities["browserName"]
        report["version"] = browser.capabilities["browserVersion"]
        assert report["browser"].lower() == "safari"
        assert browser.execute_script("return !!document.querySelector('canvas').getContext('webgl2')")
        for index, name in enumerate(("closed_block", "residence", "research_station")):
            if index:
                tap(browser, 1380, 96)
                time.sleep(.5)
            tap(browser, (262, 720, 1168)[index], 850)
            time.sleep(.5)
            tap(browser, 720, 611)
            time.sleep(3)
            tap(browser, 85, 815)
            time.sleep(8)
            tap(browser, 85, 815)
            data = export_copy(browser)
            world, manifest = validate_copy(data)
            assert world["map_id"] == name and world["elapsed_minutes"] > 0
            assert len(world["agents"]) == 8 and len(world["events"]) > 1
            report["scenarios"].append({"map":name, "events":len(world["events"]), "images":len(manifest["media"])})
            browser.save_screenshot(str(args.output / f"{name}.png"))
        archive = (args.output / "Safari.aisims").resolve()
        archive.write_bytes(data)
    finally:
        browser.quit()
    browser = visit(args.url)
    try:
        assert browser.execute_script("return AISimsWeb.getSlot('slot_3.json')") == ""
        browser.find_element(By.ID, "import-file").send_keys(str(archive))
        WebDriverWait(browser, 150).until(lambda d: d.execute_script("return document.querySelector('#storage-status').textContent.includes('Выберите слот')"))
        assert browser.execute_script("return AISimsWeb.getSlot('slot_3.json')") == manifest["slots"]["slot_3.json"]
        saved_world, restored = validate_copy(export_copy(browser))
        assert restored["media"] == manifest["media"]
        report["fresh_profile_restores_original_media"] = True
        tap(browser, 1090, 103)
        time.sleep(2)
        resumed, _ = validate_copy(export_copy(browser))
        assert resumed["run_id"] > saved_world["run_id"]
        assert resumed["map_id"] == saved_world["map_id"] and resumed["tick"] == saved_world["tick"]
        report["loaded_into_live_world"] = True
        report["passed"] = True
    finally:
        browser.quit()
        (args.output / "safari.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()

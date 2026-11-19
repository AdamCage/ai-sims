"""macOS Safari acceptance with Apple's native safaridriver.

    safaridriver --enable
    python3 -m venv /tmp/ai-sims-safari
    /tmp/ai-sims-safari/bin/pip install selenium pillow
    /tmp/ai-sims-safari/bin/python tests/browser_safari.py --url http://localhost:8732/

"""
import argparse
import base64
import ctypes
import hashlib
import json
import platform
import struct
import subprocess
import tempfile
import time
from io import BytesIO
from pathlib import Path

from PIL import Image
from selenium import webdriver
from selenium.common.exceptions import WebDriverException
from selenium.webdriver.common.actions.action_builder import ActionBuilder
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait


def visit(url):
    browser = webdriver.Safari()
    browser.get(url)
    width,height = browser.execute_script("""return [Math.min(screen.availWidth,1440+outerWidth-innerWidth),
        Math.min(screen.availHeight,946+outerHeight-innerHeight)]""")
    try:
        browser.set_window_rect(x=0,y=0,width=width,height=height)
    except WebDriverException:
        browser.maximize_window()
    wait_for_game(browser)
    return browser


def wait_for_game(browser):
    WebDriverWait(browser, 150).until(lambda d: d.execute_script("return document.querySelector('#boot').hidden"))
    # Preserve the tested game aspect ratio on smaller macOS runner displays.
    browser.execute_script("""
      const main = document.querySelector('main');
      const factor = Math.min(1,innerWidth/1440,(innerHeight-main.offsetTop)/900);
      main.style.width = Math.floor(1440*factor) + 'px';
      main.style.height = Math.floor(900*factor) + 'px';
    """)


def tap(browser, x, y):
    position = browser.execute_script("""
      const b=document.querySelector('canvas').getBoundingClientRect();
      return [Math.round(b.x+b.width*arguments[0]/1440),Math.round(b.y+b.height*(arguments[1]-46)/900)];
    """, x, y)
    actions = ActionBuilder(browser)
    actions.pointer_action.move_to_location(*position)
    actions.pointer_action.click()
    actions.perform()


def tap_story_action(browser, action, hero=False):
    """Wait for the amber primary action in the hero or story popup."""
    pointer = ActionBuilder(browser)
    pointer.pointer_action.move_to_location(8, 160)
    pointer.perform()
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        x, y, width, height, page_width, page_height = browser.execute_script("""
            const box = document.getElementById('canvas').getBoundingClientRect();
            return [box.x, box.y, box.width, box.height, innerWidth, innerHeight];
        """)
        with Image.open(BytesIO(browser.get_screenshot_as_png())) as screenshot:
            frame = screenshot.convert("RGB")
        sx, sy = frame.width / page_width, frame.height / page_height
        markers = (48, 51, 230, 233) if hero else (420, 520, 915, 1010)
        columns = [round((x + width * column / 1440) * sx) for column in markers]
        run = 0
        for row in range(400 if hero else 200, 800):
            pixel_y = round((y + height * (row - 46) / 900) * sy)
            amber = all(
                all(abs(actual - expected) < 10 for actual, expected in
                    zip(frame.getpixel((column, pixel_y)), (228, 183, 117)))
                for column in columns
            )
            run = run + 1 if amber else 0
            if run == 18:
                tap(browser, 143 if hero else 720, row - 5)
                return
        time.sleep(.2)
    raise AssertionError(f"{action} action did not appear")


def select_story(browser, index):
    tap(browser, (264, 720, 1176)[index], 885)
    tap_story_action(browser, "Open story", hero=True)


def export_copy(browser):
    # Observe the exact downloadable Blob before Safari hands it to Finder.
    # The temporary automation session need not change Safari download preferences.
    browser.execute_script("""
      window.testBackup = null;
      window.qaExport = {stage:'armed',buttonClicks:0};
      if (!window.copyObserved) {
        window.copyObserved = true;
        document.querySelector('#backup').addEventListener('click', event => {
          window.qaExport.buttonClicks++;
          window.qaExport.trusted = event.isTrusted;
        }, true);
        const objectURL=URL.createObjectURL;
        let prepared;
        URL.createObjectURL = function(blob) {
          const href=objectURL.call(this,blob);
          if(blob instanceof Blob) prepared={href,blob};
          return href;
        };
        const click = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function() {
          if (this.download !== 'AI-Sims.aisims') return click.call(this);
          window.qaExport.stage='download';
          if(prepared?.href!==this.href) {window.qaExport.stage='unknown_url';return;}
          window.qaDownloadBlob=prepared.blob;
          window.qaExport.bytes=prepared.blob.size;
          const reader=new FileReader();
          reader.onload=()=>{window.testBackup=reader.result.split(',')[1];window.qaExport.stage='complete';};
          reader.onerror=()=>{window.qaExport.stage='read_error';};
          reader.readAsDataURL(prepared.blob);
        };
      }
    """)
    backup=browser.find_element(By.ID, "backup")
    browser.execute_script("arguments[0].focus()",backup)
    backup.send_keys(Keys.ENTER)
    state=WebDriverWait(browser, 75).until(lambda d: d.execute_script("""
      if(window.qaExport.stage!=='armed')return ['complete','read_error','unknown_url'].includes(window.qaExport.stage) && window.qaExport.stage;
      return /Не удалось создать|Could not create/.test(document.querySelector('#storage-status').textContent) && 'game_error';
    """))
    assert state=='complete',state
    return base64.b64decode(browser.execute_script("return window.testBackup"))


def validate_copy(data):
    assert data[:4] == b"AIS2"
    offset = struct.unpack(">I", data[4:8])[0] + 8
    manifest = json.loads(data[8:offset])
    assert manifest["schema"] == "ai-sims-backup-v2"
    for wrapper_text in manifest["slots"].values():
        wrapper = json.loads(wrapper_text)
        assert hashlib.sha256(wrapper["payload"].encode("utf-8")).hexdigest() == wrapper["sha256"], "exported slot checksum"
    for item in manifest["media"]:
        end = offset + item["size"]
        assert hashlib.sha256(data[offset:end]).hexdigest() == item["hash"]
        offset = end
    assert offset == len(data)
    payload = json.loads(json.loads(manifest["slots"]["slot_3.json"])["payload"])["data"]
    return payload["world"]["world"], manifest


def capture_compositor(browser, path):
    # An independent picture of the visible Safari window from macOS. Some
    # hosted runners deny Screen Recording; record that outcome explicitly.
    quartz = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    quartz.CGPreflightScreenCaptureAccess.restype = ctypes.c_bool
    if not quartz.CGPreflightScreenCaptureAccess():
        return False
    rect = browser.get_window_rect()
    bounds = ",".join(str(round(rect[key])) for key in ("x","y","width","height"))
    try:
        result = subprocess.run(
            ["/usr/sbin/screencapture","-x","-R"+bounds,str(path)], capture_output=True, timeout=12)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and path.is_file() and path.stat().st_size > 0


def diagnostics(browser, report, output):
    try:
        report["diagnostics"] = browser.execute_script("""
          const input=document.getElementById('import-file'), s=JSON.parse(AISimsWeb.getStatus());
          return {status:document.getElementById('storage-status').textContent, hasFileInput:!!input,
            files:input?.files?.length, fileEvents:window.qaFileEvents || [],
            export:window.qaExport || null, viewport:[innerWidth,innerHeight,screen.availWidth,screen.availHeight],
            operation:document.getElementById('storage-status').dataset.operation || '',
            failure:document.getElementById('storage-status').dataset.failure || '',
            storageError:s.storage_error, lease:s.lease, saveRevision:s.save_revision,
            committed:s.save_persisted};
        """)
        if browser.execute_script("return Boolean(window.qaChosenFile)"):
            # Compare the actual selected disk File with the bytes validated in
            # Python. Report only lengths, signatures and matching digests.
            report["diagnostics"]["selectedFile"] = browser.execute_async_script("""
              const expected=arguments[0],done=arguments[arguments.length-1],file=window.qaChosenFile;
              const out={size:file.size,secure:isSecureContext,subtle:!!crypto.subtle};
              const safe=e=>['NotReadableError','NotFoundError','SecurityError','AbortError','TypeError'].includes(e?.name)?e.name:'other';
              async function probe(read) {
                try {
                  const data=await read(), view=new Uint8Array(data);
                  const actual=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',data)),x=>x.toString(16).padStart(2,'0')).join('');
                  return {bytes:view.length,ais2:view[0]===65&&view[1]===73&&view[2]===83&&view[3]===50,exact:actual===expected};
                } catch(e) { return {error:safe(e)}; }
              }
              (async()=>{
                out.fileReader=await probe(()=>new Promise((resolve,reject)=>{
                  const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(reader.error);reader.readAsArrayBuffer(file);
                }));
                out.blob=await probe(()=>file.arrayBuffer());
                try {
                  const app=document.querySelector('script[type="module"][src$="/app.mjs"]');
                  const {readArchive}=await import(new URL('alpha-core.mjs',app.src).href);
                  await readArchive(file);
                  out.validator='pass';
                } catch(e) {out.validator=/^[a-z][a-z0-9_]{0,40}$/.test(e?.archiveCode)?e.archiveCode:safe(e);}
                done(out);
              })().catch(e=>done({error:safe(e)}));
            """, report.get("export_sha256",""))
        browser.save_screenshot(str(output / "failure.png"))
        report["diagnostics"]["compositor"] = capture_compositor(browser,output/"failure-compositor.png")
    except WebDriverException:
        report["diagnostics_unavailable"] = True


def play_map(browser, name, index, output, report):
    report["stage"] = "play " + name
    select_story(browser, index)
    tap_story_action(browser, "Begin story")
    time.sleep(1)
    tap_story_action(browser, "Start observing")
    time.sleep(8)
    tap(browser, 951, 879)
    data = export_copy(browser)
    world, manifest = validate_copy(data)
    assert world["map_id"] == name and world["elapsed_minutes"] > 0
    assert len(world["agents"]) == 8 and len(world["events"]) > 1
    report["scenarios"].append({"map":name, "events":len(world["events"]), "images":len(manifest["media"])})
    browser.save_screenshot(str(output / f"{name}.png"))
    report["scenarios"][-1]["compositor"] = capture_compositor(browser,output/f"{name}-compositor.png")
    # Safari's WebDriver screen capture can omit its compositor's
    # WebGL layer. An agent's archived capture comes from Godot itself.
    if manifest["media"]:
        offset = struct.unpack(">I", data[4:8])[0] + 8
        size = manifest["media"][0]["size"]
        (output / f"{name}-camera.png").write_bytes(data[offset:offset+size])
    return data, manifest


def persisted_photos(browser, manifest):
    """Read hashes from Godot's actual IDBFS files, independent of its live in-memory archive."""
    expected=[item["hash"] for item in manifest["media"]]
    assert expected, "No original photos"
    actual=browser.execute_async_script("""
      const ids=arguments[0],done=arguments[arguments.length-1];
      const request=req=>new Promise((resolve,reject)=>{
        req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);
      });
      (async()=>{
        const opening=indexedDB.open('/userfs');
        opening.onupgradeneeded=()=>opening.transaction.abort();
        const db=await request(opening);
        try {
          const files=()=>db.transaction('FILE_DATA','readonly').objectStore('FILE_DATA');
          const keys=await request(files().getAllKeys());
          return await Promise.all(ids.map(async id=>{
            const path=keys.find(key=>typeof key==='string' && key.endsWith('/ai_media/'+id+'.png'));
            if(!path)return 'missing';
            const {contents}=await request(files().get(path));
            const hash=await crypto.subtle.digest('SHA-256',contents);
            return Array.from(new Uint8Array(hash),x=>x.toString(16).padStart(2,'0')).join('');
          }));
        } finally {db.close();}
      })().then(done,e=>done({error:e.name}));
    """,expected)
    assert actual==expected, "Restored IDBFS photograph bytes differ"
    return len(actual)


def restore_driver(args, archive, manifest, report):
    browser = visit(args.url)
    try:
        report["stage"] = "new profile"
        assert browser.execute_script("return AISimsWeb.getSlot('slot_3.json')") == ""
        browser.execute_script("""
          window.qaFileEvents=[];
          const field=document.querySelector('#import-file');
          for(const name of ['input','change'])field.addEventListener(name,()=>{
            if(field.files[0])window.qaChosenFile=field.files[0];
            window.qaFileEvents.push({type:name,bytes:field.files[0]?.size || 0});
          },true);
        """)
        report["stage"] = "file input"
        browser.find_element(By.ID, "import-file").send_keys(str(archive))
        WebDriverWait(browser, 15).until(lambda d: d.execute_script("return window.qaFileEvents.length>0"))
        report["stage"] = "validate and commit"
        operation = WebDriverWait(browser, 150).until(lambda d: d.execute_script("""
          const {operation,failure}=document.querySelector('#storage-status').dataset;
          return failure || (operation==='complete' && operation);
        """))
        assert operation == "complete", operation
        slot=manifest["slots"]["slot_3.json"]
        assert browser.execute_script("return AISimsWeb.getSlot('slot_3.json')") == slot
        report["disk_file_import"]=True
        report["stage"]="verify durable photographs"
        report["durable_photo_checksums"]=persisted_photos(browser,manifest)
        report["fresh_profile_restores_original_media"] = True
        report["stage"]="reload restored slot"
        browser.refresh()
        wait_for_game(browser)
        assert browser.execute_script("return AISimsWeb.getSlot('slot_3.json')")==slot
        report["reload_preserved"]=True
        report["stage"] = "reopen live story"
        tap(browser, 1142, 102)
        time.sleep(2)
        report["stage"]="download resumed story"
        resumed, restored = validate_copy(export_copy(browser))
        saved_world=json.loads(json.loads(slot)["payload"])["data"]["world"]["world"]
        assert resumed["run_id"] > saved_world["run_id"]
        assert resumed["map_id"] == saved_world["map_id"] and resumed["tick"] == saved_world["tick"]
        assert sorted(item["hash"] for item in restored["media"])==sorted(item["hash"] for item in manifest["media"])
        report["photos_survived_reload"]=True
        report["loaded_into_live_world"] = True
    except Exception:
        diagnostics(browser,report,args.output)
        raise
    finally:
        browser.quit()
        (args.output / "safari.json").write_text(json.dumps(report, indent=2), encoding="utf-8")



SCENARIOS = ("closed_block", "residence", "research_station")


def run_scenario(args, name, report):
    report["stage"]="boot " + name
    browser = visit(args.url)
    try:
        report["browser"] = browser.capabilities["browserName"]
        report["version"] = browser.capabilities["browserVersion"]
        assert report["browser"].lower() == "safari"
        assert browser.execute_script("return !!document.querySelector('canvas').getContext('webgl2')")
        data, manifest = play_map(browser,name,SCENARIOS.index(name),args.output,report)
        if name != "closed_block":
            return
        report["export_sha256"] = hashlib.sha256(data).hexdigest()
        report["in_memory_export_read"] = browser.execute_async_script("""
          const done=arguments[arguments.length-1];
          (async()=>{
            const app=document.querySelector('script[type="module"][src$="/app.mjs"]');
            const {readArchive}=await import(new URL('alpha-core.mjs',app.src).href);
            const archive=await readArchive(window.qaDownloadBlob);
            return {ok:true,images:archive.images.size,slots:Object.keys(archive.slots).length};
          })().then(done,e=>done({ok:false,reason:/^[a-z][a-z0-9_]{0,40}$/.test(e?.archiveCode)?e.archiveCode:'archive_read_failed'}));
        """)
    except Exception:
        diagnostics(browser,report,args.output)
        raise
    finally:
        browser.quit()
    # safaridriver grants read access to real files inside Safari's sandbox.
    container=Path.home()/"Library/Containers/com.apple.Safari/Data/tmp"
    with tempfile.TemporaryDirectory(prefix="ai-sims-",dir=container) as directory:
        archive = Path(directory) / "Safari.aisims"
        archive.write_bytes(data)
        report["import_method"] = "safaridriver_container_file"
        restore_driver(args,archive,manifest,report)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:8732/")
    parser.add_argument("--output", type=Path, default=Path("test-output/beta-browser-safari"))
    parser.add_argument("--scenario", choices=SCENARIOS)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Apple Safari and its driver require macOS.")
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"platform":platform.platform(),"url":args.url,"scenarios":[],"passed":False}
    try:
        for name in (args.scenario,) if args.scenario else SCENARIOS:
            run_scenario(args,name,report)
        report["stage"] = "complete"
        report["passed"] = True
    finally:
        (args.output/"safari.json").write_text(json.dumps(report,indent=2),encoding="utf-8")


if __name__ == "__main__":
    main()

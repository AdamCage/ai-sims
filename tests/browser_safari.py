"""macOS Safari acceptance with Apple's native safaridriver.

    safaridriver --enable
    python3 -m venv /tmp/ai-sims-safari
    /tmp/ai-sims-safari/bin/pip install selenium
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
            window.qaDownloadBlob = blob;
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


def canvas_sample(browser):
    try:
        return browser.execute_async_script("""
          const finish=arguments[arguments.length-1],canvas=document.querySelector('#canvas');
          let done=false,attempts=0;
          const complete=result=>{if(!done){done=true;finish(result);}};
          // Background WebGL pages may receive no animation frame. This is an
          // optional diagnostic alongside the archived individual camera and OS screenshot.
          setTimeout(()=>complete({colors:0,reason:'no_animation_frame'}),1500);
          function capture(){
            if(done)return;
            try {
              const thumb=document.createElement('canvas');thumb.width=64;thumb.height=40;
              const ctx=thumb.getContext('2d');ctx.drawImage(canvas,0,0,64,40);
              const colors=new Set(new Uint32Array(ctx.getImageData(0,0,64,40).data.buffer)).size;
              if(colors>32)return complete({colors,png:canvas.toDataURL().split(',')[1]});
              if(++attempts>=12)return complete({colors,reason:'empty_compositor_layer'});
              requestAnimationFrame(capture);
            } catch {complete({colors:0,reason:'canvas_read_failed'});}
          }
          requestAnimationFrame(capture);
        """)
    except WebDriverException:
        return {"colors":0,"reason":"webdriver_capture_unavailable"}


def diagnostics(browser, report, output):
    try:
        report["diagnostics"] = browser.execute_script("""
          const input=document.getElementById('import-file'), s=JSON.parse(AISimsWeb.getStatus());
          return {status:document.getElementById('storage-status').textContent, hasFileInput:!!input,
            files:input?.files?.length, fileEvents:window.qaFileEvents || [],
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
            report["stage"] = "play " + name
            if index:
                tap(browser, 1380, 96)
                time.sleep(.5)
            tap(browser, (262, 720, 1168)[index], 850)
            time.sleep(.5)
            tap(browser, 720, 611)
            time.sleep(3)
            tap(browser, 720, 699)
            time.sleep(8)
            tap(browser, 85, 815)
            data = export_copy(browser)
            world, manifest = validate_copy(data)
            assert world["map_id"] == name and world["elapsed_minutes"] > 0
            assert len(world["agents"]) == 8 and len(world["events"]) > 1
            report["scenarios"].append({"map":name, "events":len(world["events"]), "images":len(manifest["media"])})
            browser.save_screenshot(str(args.output / f"{name}.png"))
            report["scenarios"][-1]["compositor"] = capture_compositor(browser,args.output/f"{name}-compositor.png")
            pixels = canvas_sample(browser)
            report["scenarios"][-1]["canvas_colors"] = pixels["colors"]
            if "reason" in pixels:
                report["scenarios"][-1]["capture_note"] = pixels["reason"]
            if "png" in pixels:
                (args.output / f"{name}-canvas.png").write_bytes(base64.b64decode(pixels["png"]))
            # Safari's WebDriver screen capture can omit its compositor's
            # WebGL layer. An agent's archived capture comes from Godot itself.
            if manifest["media"]:
                offset = struct.unpack(">I", data[4:8])[0] + 8
                size = manifest["media"][0]["size"]
                (args.output / f"{name}-camera.png").write_bytes(data[offset:offset+size])
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
        (args.output / "safari.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
        raise
    finally:
        browser.quit()
    browser = visit(args.url)
    upload = tempfile.TemporaryDirectory(prefix="ai-sims-safari-", dir="/private/tmp")
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
        # Keep a real disk file available to safaridriver for the entire restore,
        # outside the source checkout and independent of CI artifact permissions.
        archive = Path(upload.name) / "Safari.aisims"
        archive.write_bytes(data)
        browser.find_element(By.ID, "import-file").send_keys(str(archive))
        WebDriverWait(browser, 15).until(lambda d: d.execute_script("return window.qaFileEvents.length>0"))
        report["stage"] = "validate and commit"
        status = WebDriverWait(browser, 150).until(lambda d: d.execute_script("""
          const t=document.querySelector('#storage-status').textContent;
          return /Выберите слот|Не удалось/.test(t) ? t : false;
        """))
        assert "Выберите слот" in status, status
        assert browser.execute_script("return AISimsWeb.getSlot('slot_3.json')") == manifest["slots"]["slot_3.json"]
        saved_world, restored = validate_copy(export_copy(browser))
        assert restored["media"] == manifest["media"]
        report["fresh_profile_restores_original_media"] = True
        report["stage"] = "reopen live story"
        tap(browser, 1090, 103)
        time.sleep(2)
        resumed, _ = validate_copy(export_copy(browser))
        assert resumed["run_id"] > saved_world["run_id"]
        assert resumed["map_id"] == saved_world["map_id"] and resumed["tick"] == saved_world["tick"]
        report["loaded_into_live_world"] = True
        report["stage"] = "complete"
        report["passed"] = True
    except Exception:
        diagnostics(browser,report,args.output)
        raise
    finally:
        browser.quit()
        upload.cleanup()
        (args.output / "safari.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()

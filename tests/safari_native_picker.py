"""Exercise the system file chooser in ordinary Safari on an isolated macOS runner."""
import ctypes
import hashlib
import json
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def apple(script, *args):
    result = subprocess.run(["osascript","-e",script,*args], capture_output=True, text=True, timeout=8)
    if result.returncode:
        raise RuntimeError("safari_apple_events_unavailable")
    return result.stdout.strip()


def wait_title(expected, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        title = apple('tell application "Safari" to get name of current tab of front window')
        if title.startswith("QA:"):
            value = json.loads(title[3:])
            if value["stage"] == "failed":
                raise RuntimeError(value["reason"])
            if value["stage"] == expected:
                return value
        time.sleep(.3)
    raise RuntimeError("native_timeout_" + expected)


class Point(ctypes.Structure):
    _fields_ = [("x",ctypes.c_double),("y",ctypes.c_double)]


class NativeInput:
    def __init__(self):
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.cg.CGPreflightPostEventAccess.restype = ctypes.c_bool
        if not self.cg.CGPreflightPostEventAccess():
            raise RuntimeError("native_input_permission_unavailable")
        self.cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p,ctypes.c_uint16,ctypes.c_bool]
        self.cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p,ctypes.c_uint32,Point,ctypes.c_uint32]
        self.cg.CGEventCreateKeyboardEvent.restype = self.cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        self.cg.CGEventSetFlags.argtypes = [ctypes.c_void_p,ctypes.c_uint64]
        self.cg.CGEventPost.argtypes = [ctypes.c_uint32,ctypes.c_void_p]
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]

    def post(self, event):
        if not event:
            raise RuntimeError("native_input_failed")
        self.cg.CGEventPost(0,event)
        self.cf.CFRelease(event)
        time.sleep(.08)

    def key(self, code, flags=0):
        for down in (True,False):
            event = self.cg.CGEventCreateKeyboardEvent(None,code,down)
            self.cg.CGEventSetFlags(event,flags)
            self.post(event)

    def click(self, xy):
        for event_type in (5,1,2):
            self.post(self.cg.CGEventCreateMouseEvent(None,event_type,Point(*xy),0))


JS = """
<script type="module">
const expected = EXPECTATIONS;
const {readArchive,sha256}=await import(new URL('alpha-core.mjs',document.querySelector('script[type="module"][src$="/app.mjs"]').src));
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const stage=(name,data={})=>{document.title='QA:'+JSON.stringify({stage:name,...data});};
const fail=reason=>stage('failed',{reason});
const screenPoint=(x,y)=>[screenX+(outerWidth-innerWidth)/2+x,screenY+outerHeight-innerHeight+y];
const elementPoint=e=>{const r=e.getBoundingClientRect();return screenPoint(r.left+r.width/2,r.top+r.height/2);};
while(!document.querySelector('#boot').hidden) await sleep(100);
if(AISimsWeb.getSlot('slot_3.json')){fail('native_profile_already_has_slots');throw Error();}
const main=document.querySelector('main'),scale=Math.min(1,innerWidth/1440,(innerHeight-main.offsetTop)/900);
main.style.width=Math.floor(1440*scale)+'px';main.style.height=Math.floor(900*scale)+'px';
document.querySelector('#import').scrollIntoView({block:'nearest',inline:'nearest'});
await sleep(150);
const input=document.getElementById('import-file');
let trustedSelection=false;
input.addEventListener('change',e=>{trustedSelection=e.isTrusted && input.files.length===1;},true);
stage('ready',{xy:elementPoint(document.getElementById('import'))});
const status=document.querySelector('#storage-status');
while(!status.dataset.failure && status.dataset.operation!=='complete')await sleep(100);
if(status.dataset.failure)fail(status.dataset.failure);
else if(!trustedSelection)fail('no_trusted_native_selection');
else if(await sha256(new TextEncoder().encode(AISimsWeb.getSlot('slot_3.json')))!==expected.slot)fail('native_slot_mismatch');
else {
  let snapshots=0,before;
  const click=HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click=function(){
    if(this.download!=='AI-Sims.aisims')return click.call(this);
    (async()=>{
      const archive=await readArchive(await (await fetch(this.href)).blob());
      const actual=[];
      for(const [id,part] of archive.images){
        if(await sha256(await part.arrayBuffer())!==id)throw Error();
        actual.push(id);
      }
      const world=JSON.parse(JSON.parse(archive.slots['slot_3.json']).payload).data.world.world;
      if(!snapshots++){
        if(actual.sort().join(',')!==expected.images.join(','))return fail('native_photo_mismatch');
        before=world;
        const r=document.querySelector('#canvas').getBoundingClientRect();
        stage('resume',{xy:screenPoint(r.x+r.width*1090/1440,r.y+r.height*(103-46)/900),images:actual.length});
        document.addEventListener('pointerup',()=>setTimeout(()=>document.querySelector('#backup').click(),2400),{once:true,capture:true});
      } else if(world.run_id>before.run_id && world.tick===before.tick && world.map_id===before.map_id)stage('verified',{images:actual.length});
      else fail('native_live_resume_mismatch');
    })().catch(()=>fail('native_export_validation'));
  };
  document.querySelector('#backup').click();
}
</script>
"""


def restore(export_dir, archive, manifest, report):
    """Use production shell/handlers. Test instrumentation only observes the selected file and downloads."""
    writer = NativeInput()
    root = Path(export_dir).resolve()
    expected = {"slot":hashlib.sha256(manifest["slots"]["slot_3.json"].encode()).hexdigest(),
                "images":sorted(item["hash"] for item in manifest["media"])}
    page = (root/"index.html").read_text(encoding="utf-8").replace("</body>",JS.replace("EXPECTATIONS",json.dumps(expected))+"</body>")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1",0))
        port = probe.getsockname()[1]
    with tempfile.NamedTemporaryFile(mode="w",encoding="utf-8",suffix=".html",prefix="qa-picker-",dir=root,delete=False) as target:
        target.write(page)
    path = Path(target.name)
    url = f"http://127.0.0.1:{port}/{path.name}"
    server = subprocess.Popen(["node","tests/serve_web.mjs",str(root),str(port)],stdout=subprocess.DEVNULL)
    opened = False
    try:
        deadline = time.monotonic()+8
        while time.monotonic()<deadline:
            try:
                with socket.create_connection(("127.0.0.1",port),timeout=.3):
                    break
            except OSError:
                time.sleep(.1)
        apple('on run argv\ntell application "Safari"\nactivate\nmake new document with properties {URL:item 1 of argv}\nend tell\nend run',url)
        opened = True
        point = wait_title("ready",150)["xy"]
        writer.click(point)
        # The standard NSOpenPanel accepts Shift-Command-G, a full path, then Open.
        time.sleep(.8)
        writer.key(5, (1<<17)|(1<<20))
        subprocess.run(["/usr/bin/pbcopy"],input=str(archive.resolve()).encode(),check=True)
        time.sleep(.35)
        writer.key(9,1<<20)
        writer.key(36)
        time.sleep(.7)
        writer.key(36)
        ready = wait_title("resume",75)
        report["native_picker"] = {"trusted_selection":True,"images":ready["images"]}
        writer.click(ready["xy"])
        wait_title("verified",35)
    finally:
        if opened:
            try:
                apple('on run argv\ntell application "Safari"\nif (URL of current tab of front window as text) is item 1 of argv then close front window\nend tell\nend run',url)
            except (RuntimeError,subprocess.TimeoutExpired):
                pass
        server.terminate()
        server.wait(timeout=8)
        path.unlink(missing_ok=True)

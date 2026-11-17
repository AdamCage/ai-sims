"""Check Safari's displayed game pixels independently of Godot and its WebGL framebuffer."""
import argparse
import json
import platform
import time
from pathlib import Path

from PIL import Image, ImageChops


def state(browser):
    return browser.execute_script("""
        const canvas=document.querySelector('canvas'), box=canvas.getBoundingClientRect();
        const ctx=canvas.GLctxObject, gl=ctx?.GLctx || canvas.getContext('webgl2');
        return {
          canvas:[canvas.width,canvas.height], rect:[box.x,box.y,box.width,box.height],
          inner:[innerWidth,innerHeight], outer:[outerWidth,outerHeight],
          screen:[screen.width,screen.height], devicePixelRatio, visibility:document.visibilityState,
          webgl:!!gl, lost:gl?.isContextLost(), drawingBuffer:[gl?.drawingBufferWidth,gl?.drawingBufferHeight],
          attributes:ctx?.attributes || null, actualAttributes:gl?.getContextAttributes() || null,
          defaultFbo:!!ctx?.defaultFbo, defaultFboForbidBlitFramebuffer:ctx?.defaultFboForbidBlitFramebuffer ?? null,
          engineFps:window.AISimsWeb?.renderingFps?.(),
          presentation:JSON.parse(window.AISimsWeb?.presentationStatus?.() || '{}')
        };
    """)


def canvas_crop(path, info, window=None):
    with Image.open(path) as source:
        x,y,width,height=info["rect"]
        visible_w,visible_h=info["inner"]
        if window:
            # screencapture clips windows larger than the physical CI display.
            left,top=window["x"],window["y"]
            visible_w=min(left+window["width"],info["screen"][0])-max(0,left)
            visible_h=min(top+window["height"],info["screen"][1])-max(0,top)
            x+=min(0,left)
            y+=min(0,top)+max(0,info["outer"][1]-info["inner"][1])
        if min(visible_w,visible_h)<=0:
            raise ValueError("Safari is outside the capture display")
        sx,sy=source.width/visible_w,source.height/visible_h
        box=(max(0,round(x*sx)),max(0,round(y*sy)),
             min(source.width,round((x+width)*sx)),min(source.height,round((y+height)*sy)))
        if box[2]-box[0]<64 or box[3]-box[1]<64:
            raise ValueError("Canvas is too small or outside the visible window")
        return source.crop(box).convert("RGB")


def inspect_image(canvas):
    # Exclude window chrome, the dock and edges. Quantization rejects small
    # compression/color-profile differences in an otherwise solid rectangle.
    w,h=canvas.size
    sample=canvas.crop((w//8,h//6,7*w//8,3*h//4)).resize((160,96),Image.Resampling.BOX)
    colors=sample.point(lambda value: value//16*16).getcolors(4096)
    dominant=max(count for count,_ in colors)/(sample.width*sample.height)
    stats={"crop_pixels":[w,h],"color_bins":len(colors),"dominant_fraction":round(dominant,4)}
    stats["visible"]=len(colors)>=12 and dominant<.97
    return sample,stats


def capture(browser,output,stage,report,capture_compositor,before=None):
    entry=report["stages"][stage]={}
    end=time.monotonic()+25
    while True:
        info=entry["context"]=state(browser)
        driver_path=output/f"display-{stage}-webdriver.png"
        browser.save_screenshot(str(driver_path))
        canvas=canvas_crop(driver_path,info)
        canvas.save(output/f"display-{stage}-webdriver-canvas.png")
        _,entry["webdriver"]=inspect_image(canvas)
        os_path=output/f"display-{stage}-compositor.png"
        entry["compositor_captured"]=capture_compositor(browser,os_path)
        if not entry["compositor_captured"]:
            raise RuntimeError("macOS screen capture unavailable; the displayed Safari window could not be verified")
        canvas=canvas_crop(os_path,info,browser.get_window_rect())
        canvas.save(output/f"display-{stage}-compositor-canvas.png")
        sample,entry["compositor"]=inspect_image(canvas)
        if before is not None:
            differences=ImageChops.difference(before,sample).convert("L").histogram()
            entry["changed_fraction"]=round(sum(differences[12:])/sum(differences),4)
        if entry["compositor"]["visible"] and (before is None or entry["changed_fraction"]>.05):
            return sample
        if time.monotonic()>=end:
            return sample
        time.sleep(2)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url",default="http://127.0.0.1:8732/")
    parser.add_argument("--output",type=Path,default=Path("test-output/beta-browser-safari"))
    args=parser.parse_args()
    if platform.system()!="Darwin":
        parser.error("Apple Safari and macOS screen capture require a Mac")
    from browser_safari import capture_compositor, tap, visit
    args.output.mkdir(parents=True,exist_ok=True)
    report={"url":args.url,"passed":False,"stages":{}}
    browser=None
    try:
        browser=visit(args.url)
        report["browser"]=browser.capabilities.get("browserName")
        report["version"]=browser.capabilities.get("browserVersion")
        before=capture(browser,args.output,"menu",report,capture_compositor)
        tap(browser,262,850)
        report["menu_click_sent"]=True
        capture(browser,args.output,"story-options",report,capture_compositor,before)
        menu,options=report["stages"].values()
        if not all(s["context"]["webgl"] and not s["context"]["lost"] for s in (menu,options)):
            raise AssertionError("WebGL context missing or lost")
        if not menu["compositor"]["visible"] or not options["compositor"]["visible"]:
            raise AssertionError("macOS compositor shows a blank game canvas")
        if options["changed_fraction"]<=.05:
            raise AssertionError("The story selection click produced no visible menu transition")
        report["passed"]=True
        print("PASS Safari visibly rendered the story menu and responded to selection")
    except Exception as error:
        report["failure"]=f"{type(error).__name__}: {error}"
        raise
    finally:
        (args.output/"safari-display.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
        if browser:
            browser.quit()


if __name__=="__main__":
    main()

// Present Godot's finished offscreen framebuffer through Canvas 2D on WebKit.
// The WebGL canvas remains the original input and accessibility surface.
export function installWebKitPresentation(canvas) {
  if (navigator.vendor !== 'Apple Computer, Inc.') return null;
  const picture = document.createElement('canvas');
  picture.id = 'game-picture';
  picture.hidden = true;
  picture.setAttribute('aria-hidden', 'true');
  const painter = picture.getContext('2d', {alpha:false, willReadFrequently:true, desynchronized:false});
  if (!painter) return null;
  canvas.after(picture);
  let pixels, frame, rows, packParameters, next = 0;
  const previousPack = new Int32Array(4);
  const wantedPack = [4,0,0,0];
  const state = {mode:'software-2d', presented:0, colors:0, width:0, height:0, error:''};

  function resize(width, height) {
    const stride = width * 4;
    picture.width = width;
    picture.height = height;
    frame = painter.createImageData(width, height);
    pixels = new Uint8Array(stride * height);
    rows = Array.from({length:height}, (_, y) => pixels.subarray(y * stride, (y + 1) * stride));
    state.width = width;
    state.height = height;
  }

  function present(context) {
    const now = performance.now();
    if (document.hidden || now < next) return true;
    next = now + 1000 / 30;
    const gl = context.GLctx, w = gl.drawingBufferWidth, h = gl.drawingBufferHeight;
    if (!w || !h || gl.isContextLost()) {
      state.error = 'context_unavailable';
      return false;
    }
    if (!frame || w !== state.width || h !== state.height) resize(w, h);
    const previous = gl.getParameter(gl.READ_FRAMEBUFFER_BINDING);
    const pack = gl.getParameter(gl.PIXEL_PACK_BUFFER_BINDING);
    if (!packParameters) packParameters = [gl.PACK_ALIGNMENT,gl.PACK_ROW_LENGTH,gl.PACK_SKIP_ROWS,gl.PACK_SKIP_PIXELS];
    for (let i = 0; i < packParameters.length; i++) previousPack[i] = gl.getParameter(packParameters[i]);
    let previousAttachment;
    try {
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, context.defaultFbo);
      if (gl.checkFramebufferStatus(gl.READ_FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
        state.error = 'incomplete_framebuffer';
        return false;
      }
      if (pack) gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
      previousAttachment = gl.getParameter(gl.READ_BUFFER);
      if (previousAttachment !== gl.COLOR_ATTACHMENT0) gl.readBuffer(gl.COLOR_ATTACHMENT0);
      for (let i = 0; i < packParameters.length; i++) {
        if (previousPack[i] !== wantedPack[i]) gl.pixelStorei(packParameters[i], wantedPack[i]);
      }
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    } finally {
      for (let i = 0; i < packParameters.length; i++) {
        if (previousPack[i] !== wantedPack[i]) gl.pixelStorei(packParameters[i], previousPack[i]);
      }
      if (previousAttachment !== undefined && previousAttachment !== gl.COLOR_ATTACHMENT0) gl.readBuffer(previousAttachment);
      if (pack) gl.bindBuffer(gl.PIXEL_PACK_BUFFER, pack);
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, previous);
    }
    const stride = w * 4;
    for (let y = 0; y < h; y++) frame.data.set(rows[h - 1 - y], y * stride);
    painter.putImageData(frame, 0, 0);
    picture.hidden = false;
    if (state.presented % 30 === 0) {
      const colors = new Set();
      for (let y = 5; y < h; y += 37) for (let x = 5; x < w; x += 37) {
        const i = (y*w+x)*4;
        colors.add((pixels[i]<<16)|(pixels[i+1]<<8)|pixels[i+2]);
      }
      state.colors = colors.size;
    }
    state.presented++;
    state.error = '';
    return true;
  }
  canvas.presentGodotFrame = context => {
    try {
      if (present(context)) return true;
    } catch {
      state.error = 'presentation_failed';
    }
    picture.hidden = true;
    return false;
  };
  return state;
}

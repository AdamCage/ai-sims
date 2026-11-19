const MAX_LONG_EDGE = 3840;
const MAX_SHORT_EDGE = 2160;

export function canvasBackingSize(cssWidth, cssHeight, devicePixelRatio) {
  const landscape = cssWidth >= cssHeight;
  const maxWidth = landscape ? MAX_LONG_EDGE : MAX_SHORT_EDGE;
  const maxHeight = landscape ? MAX_SHORT_EDGE : MAX_LONG_EDGE;
  const scale = Math.min(devicePixelRatio || 1, maxWidth / cssWidth, maxHeight / cssHeight);
  return {
    width: Math.max(1, Math.round(cssWidth * scale)),
    height: Math.max(1, Math.round(cssHeight * scale)),
  };
}

export function observeCanvasSize(canvas) {
  const host = canvas.parentElement;
  let pixelRatio = 0;
  const resize = () => {
    const box = host.getBoundingClientRect();
    if (!box.width || !box.height) return;
    pixelRatio = window.devicePixelRatio || 1;
    const {width, height} = canvasBackingSize(box.width, box.height, pixelRatio);
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
  };
  resize();
  new ResizeObserver(resize).observe(host);
  // A monitor or zoom change can alter the backing density without changing the CSS box.
  window.setInterval(() => {
    if (!document.hidden && pixelRatio !== (window.devicePixelRatio || 1)) resize();
  }, 500);
}

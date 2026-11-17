import {encodePNG} from './png-codec.mjs';
self.onmessage = async ({data}) => {
  const {id, rgba, width, height} = data;
  try { const png = await encodePNG(new Uint8Array(rgba), width, height); self.postMessage({id, png: png.buffer}, [png.buffer]); }
  catch { self.postMessage({id, error: 'PNG encoding failed'}); }
};

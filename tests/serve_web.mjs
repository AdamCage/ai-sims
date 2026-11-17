import {createReadStream} from 'node:fs';
import {stat} from 'node:fs/promises';
import {createServer} from 'node:http';
import {resolve, sep, extname} from 'node:path';

// Serve the built game to safaridriver over loopback, without LAN discovery.
const root = resolve(process.argv[2] || 'build/web');
const port = Number(process.argv[3] || 8732);
const types = {'.html':'text/html; charset=utf-8', '.js':'text/javascript', '.mjs':'text/javascript',
  '.css':'text/css', '.json':'application/json', '.png':'image/png', '.txt':'text/plain; charset=utf-8'};

createServer(async (req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, {Allow:'GET, HEAD'}).end();
    return;
  }
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
    const file = resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (!file.startsWith(root + sep)) throw new Error('Outside the export');
    const info = await stat(file);
    if (!info.isFile()) throw new Error('Missing file');
    res.writeHead(200, {'Content-Length':info.size, 'Content-Type':types[extname(file)] || 'application/octet-stream'});
    if (req.method === 'HEAD') res.end();
    else createReadStream(file).on('error', () => res.destroy()).pipe(res);
  } catch {
    res.writeHead(404).end();
  }
}).listen(port, '127.0.0.1');

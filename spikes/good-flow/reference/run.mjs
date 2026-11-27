// Usage: node spikes/good-flow/reference/run.mjs   (renders all reference stills in headless Chrome)
//   Controls (step 3): OUT=build/reference-run2 (a second run, must equal the first); FRINGE=0 OUT=build/reference-fringe0
//   (the look with fringe 0: must FAIL the equality bar against the reference). OUT is relative to spikes/good-flow.
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import {spawn} from 'node:child_process'; import {fileURLToPath} from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url)), root = path.resolve(here, '..');
const out = path.resolve(root, process.env.OUT || 'build/reference'), prof = path.join(root, 'build/chrome-profile');
const SRC = process.env.HOME + '/Developer/Ops/design-refs/living-layer/good-flow-bench-source.md';
const md = fs.readFileSync(SRC, 'utf8'); const blocks = [...md.matchAll(/```glsl\n([\s\S]*?)```/g)].map(m => m[1]);
if (blocks.length < 2) throw new Error('glsl blocks: ' + blocks.length);
const shaders = {vs: blocks[0], fs: blocks[1]};
fs.mkdirSync(out, {recursive: true}); fs.rmSync(prof, {recursive: true, force: true});
const flags = (process.env.CHROME_FLAGS || '--headless=new --use-angle=metal --enable-gpu --ignore-gpu-blocklist').split(' ');
let finish; const done = new Promise(r => finish = r);
const srv = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (req.method === 'GET') {
    if (u.pathname === '/') { res.setHeader('content-type', 'text/html'); return res.end(fs.readFileSync(path.join(here, 'page.html'))); }
    if (u.pathname === '/shaders.json') return res.end(JSON.stringify(shaders));
    if (u.pathname === '/look.json') {
      const L = JSON.parse(fs.readFileSync(path.join(root, 'look.json'), 'utf8'));
      if (process.env.FRINGE !== undefined) L.look.fringe = Number(process.env.FRINGE);
      return res.end(JSON.stringify(L));
    }
  } else {
    const ch = []; req.on('data', c => ch.push(c)); req.on('end', () => {
      const b = Buffer.concat(ch);
      if (u.pathname === '/png') fs.writeFileSync(path.join(out, path.basename(u.searchParams.get('name'))), b);
      if (u.pathname === '/json') fs.writeFileSync(path.join(out, path.basename(u.searchParams.get('name'))), b);
      if (u.pathname === '/log') console.log(b.toString());
      if (u.pathname === '/done') finish();
      res.end('ok');
    }); return;
  }
  res.statusCode = 404; res.end();
});
await new Promise(r => srv.listen(0, '127.0.0.1', r));
const port = srv.address().port; const t0 = Date.now();
const ch = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [...flags, '--user-data-dir=' + prof, '--no-first-run', '--no-default-browser-check', '--window-size=800,600', `http://127.0.0.1:${port}/`], {stdio: 'ignore'});
const bail = setTimeout(() => { console.log('TIMEOUT'); ch.kill(); process.exit(1); }, 20 * 60e3);
await done; clearTimeout(bail); ch.kill(); srv.close();
console.log('total wall s', ((Date.now() - t0) / 1000).toFixed(1)); process.exit(0);

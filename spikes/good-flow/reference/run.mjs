// Usage: node spikes/good-flow/reference/run.mjs   (renders all reference stills in headless Chrome)
//   Controls (step 3): OUT=build/reference-run2 (a second run, must equal the first); FRINGE=0 OUT=build/reference-fringe0
//   (the look with fringe 0: must FAIL the equality bar against the reference). OUT is relative to spikes/good-flow.
//   HASH=stable OUT=build/reference-stable (step 3B): the bench with the stable hash (hash11's argument snapped).
//   POOLS=table (round 2): the pools from look.json's table (uPool); CHROME_FLAGS='--headless=new --use-angle=swiftshader' = a different renderer.
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import {spawn} from 'node:child_process'; import {fileURLToPath} from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url)), root = path.resolve(here, '..');
const out = path.resolve(root, process.env.OUT || 'build/reference'), prof = path.join(root, 'build/chrome-profile');
const SRC = process.env.HOME + '/Developer/Ops/design-refs/living-layer/good-flow-bench-source.md';
const md = fs.readFileSync(SRC, 'utf8'); const blocks = [...md.matchAll(/```glsl\n([\s\S]*?)```/g)].map(m => m[1]);
if (blocks.length < 2) throw new Error('glsl blocks: ' + blocks.length);
const HASH_OLD = 'float hash11(float n){ return fract(sin(n*127.1)*43758.5453); }';
// HASH=stable (step 3B): the spike's "stable hash" — hash11's argument snapped to 1/1024 (roundEven = Metal's rint), so
// FMA / fast-maths differences between compilers cannot move the pools. Same snap as GoodFlow.metal's stable hash.
let fsSrc = blocks[1];
if (process.env.HASH === 'stable') {
  if (!fsSrc.includes(HASH_OLD)) throw new Error('hash11 not found in the bench source');
  fsSrc = fsSrc.replace(HASH_OLD, 'float hash11(float n){ n = roundEven(n*1024.)/1024.; return fract(sin(n*127.1)*43758.5453); }');
}
// POOLS=table (round 2, outcome 5): the bench reads the pool table (look.json "pools", the values the port passes in)
// instead of calling hash11 for the pools, so ANY renderer (another GPU, SwiftShader on the CPU) draws T's bench arrangement.
if (process.env.POOLS === 'table') {
  const subs = [['hash11(fi*7.3+e.seed*19.)', 'uPool[i].x'], ['hash11(fi*3.9+e.seed*29.)', 'uPool[i].y'], ['hash11(fi*5.7+e.seed*7.)', 'uPool[i].z']];
  for (const [a, b] of subs) { if (!fsSrc.includes(a)) throw new Error('not found: ' + a); fsSrc = fsSrc.replace(a, b); }
  fsSrc = fsSrc.replace('float hash11(float n){', 'uniform vec3 uPool[6];\nfloat hash11(float n){');
}
const shaders = {vs: blocks[0], fs: fsSrc};
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

// Good Flow spike · round 2 (outcome 5): the pool table AS THE BENCH DREW IT.
// The bench's Flow path calls hash11 three times per pool (six pools) to place and size the pools, from the entry's seed
// only. This page runs exactly those three expressions, inside the same six-step loop, in headless Chrome (ANGLE Metal,
// the reference stills' renderer) and reads the 18 values per entry back from an RGBA32F target: the table the bench
// itself computed on this Mac. Output: build/pools/bench-pools.json {entry id: [[h1,h2,h3] × 6]} (+ renderer).
//   node spikes/good-flow/tools/bench_pools.mjs            (entries from look.json)
// The values then go into look.json ("pools") and the port reads them instead of calling hash11 (GFPools, Look.swift).
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import {spawn} from 'node:child_process'; import {fileURLToPath} from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url)), root = path.resolve(here, '..');
const out = path.join(root, 'build/pools'); fs.mkdirSync(out, {recursive: true});
const prof = path.join(out, 'chrome-profile'); fs.rmSync(prof, {recursive: true, force: true});
const L = JSON.parse(fs.readFileSync(path.join(root, 'look.json'), 'utf8'));
const seeds = L.entries.map(e => ({id: e.id, seed: e.seed}));
// The bench's own hash11 and loop header, verbatim (good-flow-bench-source.md, flowBody).
const fsSrc = `#version 300 es
precision highp float;
uniform float uSeed;
out vec4 o;
float hash11(float n){ return fract(sin(n*127.1)*43758.5453); }
void main(){
  int row = int(gl_FragCoord.y);
  vec3 h = vec3(0.);
  for(int i=0;i<6;i++){
    float fi = float(i);
    vec3 v = vec3(hash11(fi*7.3+uSeed*19.), hash11(fi*3.9+uSeed*29.), hash11(fi*5.7+uSeed*7.));
    if(i==row) h = v;
  }
  o = vec4(h, 1.);
}`;
const vsSrc = `#version 300 es
in vec2 a; void main(){ gl_Position = vec4(a, 0., 1.); }`;
const page = `<!doctype html><canvas id=c></canvas><script>
(async()=>{ try {
const S = await (await fetch('/seeds.json')).json();
const gl = document.getElementById('c').getContext('webgl2');
if (!gl.getExtension('EXT_color_buffer_float')) throw new Error('no EXT_color_buffer_float');
const dbg = gl.getExtension('WEBGL_debug_renderer_info');
const renderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : 'unknown';
const mk = (t, s) => { const o = gl.createShader(t); gl.shaderSource(o, s); gl.compileShader(o); if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(o)); return o; };
const pr = gl.createProgram(); gl.attachShader(pr, mk(gl.VERTEX_SHADER, ${JSON.stringify(vsSrc)})); gl.attachShader(pr, mk(gl.FRAGMENT_SHADER, ${JSON.stringify(fsSrc)})); gl.linkProgram(pr); gl.useProgram(pr);
const vb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, vb); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
const al = gl.getAttribLocation(pr, 'a'); gl.enableVertexAttribArray(al); gl.vertexAttribPointer(al, 2, gl.FLOAT, false, 0, 0);
const tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex); gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA32F, 1, 6);
const fb = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fb); gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
gl.viewport(0, 0, 1, 6);
const res = {renderer, entries: {}};
for (const s of S) {
  gl.uniform1f(gl.getUniformLocation(pr, 'uSeed'), s.seed);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  const px = new Float32Array(24); gl.readPixels(0, 0, 1, 6, gl.RGBA, gl.FLOAT, px);
  res.entries[s.id] = [0,1,2,3,4,5].map(i => [px[i*4], px[i*4+1], px[i*4+2]]);
}
await fetch('/out', {method:'POST', body: JSON.stringify(res)});
} catch (e) { await fetch('/out', {method:'POST', body: JSON.stringify({error: e.message})}); } })();</script>`;
let finish; const done = new Promise(r => finish = r);
const srv = http.createServer((req, res) => {
  if (req.method === 'GET') {
    if (req.url === '/') { res.setHeader('content-type', 'text/html'); return res.end(page); }
    if (req.url === '/seeds.json') return res.end(JSON.stringify(seeds));
    res.statusCode = 404; return res.end();
  }
  const ch = []; req.on('data', c => ch.push(c)); req.on('end', () => {
    const b = JSON.parse(Buffer.concat(ch).toString());
    fs.writeFileSync(path.join(out, 'bench-pools.json'), JSON.stringify(b, null, 1)); console.log(b.error ? 'ERROR ' + b.error : 'renderer ' + b.renderer); res.end('ok'); finish();
  });
});
await new Promise(r => srv.listen(0, '127.0.0.1', r));
const flags = (process.env.CHROME_FLAGS || '--headless=new --use-angle=metal --enable-gpu --ignore-gpu-blocklist').split(' ');
const ch = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [...flags, '--user-data-dir=' + prof, '--no-first-run', '--no-default-browser-check', '--window-size=400,300', `http://127.0.0.1:${srv.address().port}/`], {stdio: 'ignore'});
const bail = setTimeout(() => { console.log('TIMEOUT'); ch.kill(); process.exit(1); }, 90e3);
await done; clearTimeout(bail); ch.kill(); srv.close(); process.exit(0);

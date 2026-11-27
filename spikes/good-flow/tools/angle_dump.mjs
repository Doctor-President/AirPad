import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import {spawn} from 'node:child_process';
// Good Flow spike · dumps Chrome's own ANGLE (Metal) translation of the bench shader (WEBGL_debug_shaders) to
// build/angle/translated.txt. Then: python3 tools/angle_wrap.py, copy build/angle/angle_wrapped.metal into the app's
// Documents, run -RenderStills <dir> -ShaderVariant angle-fast-fastfn (reproduces the reference) or angle-safe-precisefn.
const here = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../build/angle'); fs.mkdirSync(here, {recursive: true});
const SRC = process.env.HOME + '/Developer/Ops/design-refs/living-layer/good-flow-bench-source.md';
const md = fs.readFileSync(SRC, 'utf8'); const blocks = [...md.matchAll(/```glsl\n([\s\S]*?)```/g)].map(m => m[1]);
const shaders = {vs: blocks[0], fs: blocks[1]};
const page = `<!doctype html><canvas id=c></canvas><script>
(async()=>{const sh=await (await fetch('/shaders.json')).json();
const gl=document.getElementById('c').getContext('webgl2');
const ext=gl.getExtension('WEBGL_debug_shaders');
const exts = gl.getSupportedExtensions().join(' ');
const o=gl.createShader(gl.FRAGMENT_SHADER);gl.shaderSource(o,sh.fs);gl.compileShader(o);
const ok = gl.getShaderParameter(o, gl.COMPILE_STATUS);
const t = ext ? ext.getTranslatedShaderSource(o) : 'NO EXT; exts: '+exts;
await fetch('/out',{method:'POST',body:'ok='+ok+'\\n'+t});})();</script>`;
let finish; const done = new Promise(r => finish = r);
const srv = http.createServer((req, res) => {
  if (req.method === 'GET') { if (req.url === '/') { res.setHeader('content-type','text/html'); return res.end(page); } if (req.url === '/shaders.json') return res.end(JSON.stringify(shaders)); res.statusCode=404; return res.end(); }
  const ch=[]; req.on('data',c=>ch.push(c)); req.on('end',()=>{ fs.writeFileSync(path.join(here,'translated.txt'), Buffer.concat(ch)); res.end('ok'); finish(); });
});
await new Promise(r => srv.listen(0,'127.0.0.1',r));
const prof = path.join(here,'prof'); fs.rmSync(prof,{recursive:true,force:true});
const ch = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new','--use-angle=metal','--enable-gpu','--ignore-gpu-blocklist','--enable-privileged-webgl-extensions','--user-data-dir='+prof,'--no-first-run','--window-size=400,300',`http://127.0.0.1:${srv.address().port}/`], {stdio:'ignore'});
const bail = setTimeout(()=>{console.log('TIMEOUT'); ch.kill(); process.exit(1);}, 60e3);
await done; clearTimeout(bail); ch.kill(); srv.close(); process.exit(0);

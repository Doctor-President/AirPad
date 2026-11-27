// Good Flow spike (throwaway, never merged) · A, the faithful port.
// The bench's Flow path (Ops design-refs/living-layer/good-flow-bench-source.md §4), line for line, GLSL ES 3.00 → MSL.
// What changed, and only this:
//   - the bench's mutable globals (gTank, gTH, gSpread, gWide, gGround, gHalf, gPx, gNz) live in a thread struct `G`;
//   - uniforms come from one constant buffer (`GFUniforms`, GFShared.h);
//   - gl_FragCoord counts from the bottom, [[position]] from the top: fc = (x − org.x, res.y − (y − org.y));
//   - only Flow (look 2), sdShape's theme-0 / shape-0 circle, tankSpace (gTank 1 only), body's Flow branch;
//   - two spike switches the bench does not have: `grainOn` (0 = bake without the final grain term) and `flat`.
// Compiled with MTL_FAST_MATH = NO (hash11 is fract(sin·43758): sin precision moves the pools).
// Step 3B adds, without changing A's maths:
//   - the STABLE HASH (default): hash11's argument snapped to 1/1024 and its sin = metal::fast::sin, the sin Chrome ran
//     the bench on (function constant kBenchHash = false), so FMA / reassociation cannot move the pools; same entry, same
//     picture on Mac, iPhone, still and live, and = the bench with the same snap. kBenchHash = true is the bench's own
//     unsnapped sin hash as this compiler computes it (a switch: pools sit where they fall);
//   - A's main() split into slotSetup() + finish() so the two-pass variants share every line with A;
//   - the two-pass variants (B, BD75, BD50): gf_body draws the composed body once into an offscreen picture (linear,
//     rgba16Float + the rim glow in r16Float) at s × the slot's pixels; gf_fringe takes R / G / B from it at p·(1−fr),
//     p, p·(1+fr) (bilinear), composes over the ground and runs finish(). The edge bend and the glass flutes move p
//     BEFORE the lookup, exactly as they move it before body() in A;
//   - the Map pass (gf_map_*): the orb stills drawn as instanced quads, grain added at screen scale.
#include <metal_stdlib>
#include "GFShared.h"
using namespace metal;

constant bool kBenchHash [[function_constant(0)]];

#ifndef GF_SIN
#define GF_SIN(x) sin(x)
#endif

struct E { float hue; float mass; float parts; float conn; float tempo; float amp; float patina; float seed; float rot; };
struct Hit { float3 col; float a; float glow; float3 rimc; };
struct G {   // the bench's globals
    int tank = 0; float2 TH = float2(1.); float spread = 1.; bool wide = true;
    float3 ground = float3(0.); float2 hlf = float2(1.); float px = .003; float nz = 0.;
};
#define U constant GFUniforms& u

static float tOf(U, E e){ return u.live==1 ? u.liveT : u.time*(.06+1.3*e.tempo); }

static float hash11(float n){
#ifdef GF_QHASH   // diagnostic only (-ShaderVariant …-qhash): snap the argument so FMA / reassociation cannot move it
  n = rint(n*1024.f)/1024.f;
#else
  // The stable hash (step 3B default): the argument snapped to 1/1024 AND the sin the bench ran on (Chrome compiles
  // the bench with fast maths on Metal: metal::fast::sin). Measured: = the bench with the same snap, 120/120 stills,
  // mean 0.03. The rest of the shader stays safe maths.
  if(!kBenchHash){ n = rint(n*1024.f)/1024.f; return fract(metal::fast::sin(n*127.1f)*43758.5453f); }
#endif
  return fract(GF_SIN(n*127.1f)*43758.5453f); }
static float ihash(float2 p){ uint2 q = uint2(int2(p))*uint2(1597334673u,3812015801u); uint n = (q.x^q.y)*1597334673u; return float(n)*(1.f/4294967295.f); }
static float hash21(float2 p){ p = fract(p*float2(123.34,456.21)); p += dot(p,p+45.32); return fract(p.x*p.y); }
static float vnoise(float2 p){ float2 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
  float a=hash21(i), b=hash21(i+float2(1.,0.)), c=hash21(i+float2(0.,1.)), d=hash21(i+float2(1.,1.));
  return mix(mix(a,b,f.x),mix(c,d,f.x),f.y); }
static float fbm(float2 p){ float s=0., a=.5; for(int i=0;i<3;i++){ s+=a*vnoise(p); p=p*2.03+17.1; a*=.5; } return s; }

static float3 oklab2lin(float3 c){
  float l_=c.x+0.3963377774*c.y+0.2158037573*c.z;
  float m_=c.x-0.1055613458*c.y-0.0638541728*c.z;
  float s_=c.x-0.0894841775*c.y-1.2914855480*c.z;
  float l=l_*l_*l_, m=m_*m_*m_, s=s_*s_*s_;
  return float3( 4.0767416621*l-3.3077115913*m+0.2309699292*s,
                -1.2684380046*l+2.6097574011*m-0.3413193965*s,
                -0.0041960863*l-0.7034186147*m+1.7076147010*s);
}
static float3 vivid(float hdeg){
  float h = hdeg*0.017453292519943295f;   // GLSL radians()
  float3 c = oklab2lin(float3(.66, .11*cos(h), .11*sin(h)));
  c -= min(min(c.r,c.g),c.b)*.93;
  c /= max(max(c.r,c.g),max(c.b,1e-4));
  return c*pow(.45/max(dot(c,float3(.2126,.7152,.0722)),.03), .22);
}
static float3 shoulder(float3 c){
  c = max(c,0.); float m = max(max(c.r,c.g),max(c.b,1e-5));
  return mix(c*((1.-exp(-m))/m), 1.-exp(-c), .4);
}
static float3 grade(U, float3 lin){
  float3 g = pow(clamp(lin,0.,1.), float3(1./2.2));
  g = clamp(mix(float3(dot(g,float3(.2126,.7152,.0722))), g, u.sat),0.,1.);
  g = mix(g, g*g*(3.-2.*g), u.contrast);
  return pow(g, float3(2.2));
}
constant float HOFF[5] = {0., 1., .5, .25, .75};

static float sdShape(U, thread G& g, float2 p, float R, E e, float t){
  // uTheme 1 (merged lobes) and uShape 1/2 belong to other looks: not ported.
  float d = length(p)-R;
  float2 uu = p/max(length(p),1e-3);
  d -= R*.05*e.amp*u.flow*(vnoise(uu*1.6+e.seed*9.+t*.35)-.5);
  return d;
}

static float2 tankSpace(U, thread G& g, float2 p, E e){
  g.wide = g.TH.x>=g.TH.y;
  float k = clamp(max(g.TH.x,g.TH.y)/max(min(g.TH.x,g.TH.y),1e-3), 1., 2.4);
  float occ = mix(.62,.86,e.mass), t = tOf(u, e);
  g.spread = 1.+(k-1.)*.8;
  float asp = u.look==2 ? (u.fall==0 ? min(k,2.2) : k) : min(k,1.6);
  float2 ext = occ*.92*(g.wide ? float2(asp,1.) : float2(1.,asp));
  float2 room = max(g.TH-ext, 0.);
  return p - room*.75*u.tdrift*float2(sin(t*.11+e.seed*9.), .8*sin(t*.083+e.seed*5.));
}

constant float YO[6] = {.05, -.38, .42, -.02, .68, -.7};

static float3 blendLine(float3 lin, float la, int mode, bool darkLine){
  float3 gg = pow(clamp(lin,0.,1.), float3(1./2.2)), L = float3(darkLine ? 0. : 1.), r;
  if(mode==1) r = gg*(1.-la);
  else if(mode==2) r = 1.-(1.-gg)*(1.-la);
  else if(mode==3) r = mix(gg, mix(2.*gg*L, 1.-2.*(1.-gg)*(1.-L), step(.5,gg)), la);
  else r = mix(gg, 1.-gg, la);
  return pow(r, float3(2.2));
}

static Hit flowBody(U, thread G& g, float2 p, E e){
  float t = tOf(u, e);
  bool tank = g.tank==1;
  bool freeF = (u.theme==1) || tank, grid = u.grid.x*u.grid.y>1.5, slot = u.slot==1;
  int fall = (tank && u.theme==0) ? 1 : (freeF ? u.fall : 0);
  bool framed = fall>=2, held = !freeF || (framed && (grid || slot));
  float R = framed ? .8 : (.30+.48*e.mass)*(1.+.03*e.amp*sin(t*1.7+e.seed*40.))*(freeF ? (fall==1 ? .62 : (grid ? .5 : .45)) : 1.);
  float st = 1.+3.2*u.stretch, kT = 1.;
  float ang = tank ? (g.wide ? 0. : 1.5708)+e.rot*.25 : u.light+e.rot, ca = cos(ang), sa = sin(ang);
  float2 p0 = p, tExt = float2(1.);
  if(tank){
    float occ = mix(.62,.86,e.mass); kT = clamp(max(g.TH.x,g.TH.y)/max(min(g.TH.x,g.TH.y),1e-3),1.,2.4);
    tExt = occ*.9*(g.wide ? float2(kT,1.) : float2(1.,kT));
    R = (fall==1 ? occ*.9/1.45 : min(occ*.9/1.3, kT*occ*.9/(1.15+.6*st)))*(1.+.03*e.amp*sin(t*1.7+e.seed*40.));
  }
  float2 q = float2(ca*p.x+sa*p.y, -sa*p.x+ca*p.y)/R;
  float amp = u.stir*(.3+.7*e.amp), f = mix(.45,2.2,u.detail);
  float2 so = float2(e.seed*37.1, e.seed*91.7), fq = float2(f/(1.+.35*(st-1.)), f);
  float2 w1 = float2(fbm(q*fq+so+float2(0.,t*.07)), fbm(q*fq+so+float2(5.2,1.3)-float2(t*.05,0.)))-.44;
  q += w1*2.5*amp;
  float2 w2 = float2(fbm(q*fq*1.9+so+1.7), fbm(q*fq*1.9+so+float2(9.2,t*.04)))-.44;
  q += w2*.9*amp;
  float env = 1.;
  if(freeF && fall==0){
    env = 1.-smoothstep(1.3,2.3, length(float2(q.x/st*1.05,q.y)));
    if(grid) env *= 1.-smoothstep(.72,.98,max(abs(p.x),abs(p.y)));
  }
  float r0 = mix(.25,.8,u.size), sh = mix(9.,1.3,u.lsoft), wand = .12*(.2+.8*e.amp);
  float3 em = float3(0.), deepC = float3(0.); float Dl = 0., sw = 0., swc = 0., wd = 0., gmax = 1e-6; float gsA[6];
  for(int i=0;i<6;i++){
    float fi = float(i);
    float w = (i==0) ? min(u.bodyl*1.3,1.)*(tank ? mix(.35,1.,smoothstep(1.,3.,e.parts)) : 1.) : ((i==1) ? 1. : clamp(e.parts-(fi-1.),0.,1.));
    gsA[i] = 0.;
    if(w<=0.) continue;
    float2 c = float2((hash11(fi*7.3+e.seed*19.)-.5)*(i==0 ? .7 : 2.3), YO[i]*.85+(hash11(fi*3.9+e.seed*29.)-.5)*.3);
    c += wand*float2(sin(t*.21+fi*2.1), cos(t*.17+fi*1.3));
    float r = r0*(.75+.5*hash11(fi*5.7+e.seed*7.));
    float2 dq = q-c; dq.x /= st; dq.y /= mix(1.,.55,u.stretch);
    float d2 = dot(dq,dq)/(r*r);
    Dl += exp(-d2)*w;
    gsA[i] = (-d2+log(w))+50.;
    gmax = max(gmax, gsA[i]);
  }
  for(int i=0;i<6;i++){
    if(gsA[i]<=0.) continue;
    float ws = exp(sh*(gsA[i]-gmax+g.nz*u.gmix*1.2)); sw += ws;
    if(i==0){ wd = ws; deepC = pow(min(vivid(e.hue),float3(1.)),float3(1.7))*.1; }
    else { em += ws*min(vivid(e.hue+u.spread*HOFF[i-1]),float3(1.)); swc += ws; }
  }
  em /= max(swc,1e-9); wd /= max(sw,1e-9);
  em = mix(em, em/max(max(em.r,em.g),max(em.b,1e-3)), .7);
  float cs = mix(.02,.3,u.lsoft);
  float pres = fall==0 ? Dl*env : (fall==3 ? 1. : Dl+mix(0.,.75,e.mass));
  float cover = smoothstep(.3-cs, .3+cs, pres+g.nz*u.gmix*.25*(cs+.03));
  if(tank) cover *= 1.-smoothstep(.9,1.14,length(p0/tExt));
  if(fall>0){
    float fo = 1.;
    if(fall==1) fo = 1.-smoothstep(1.2*(1.-.75*u.fsoft), 1.2*(1.+.45*u.fsoft)+.02, length(float2(q.x/mix(1.,kT,.8), q.y)));
    else if(fall==2) fo = (grid || slot) ? 1. : 1.-smoothstep(1.-.6*u.fsoft, 1.0001, max(abs(p.x)/g.hlf.x, abs(p.y)/g.hlf.y));
    else { float ext = (abs(ca)*g.hlf.x+abs(sa)*g.hlf.y)/R, m = mix(-.55,1.2,e.mass), wd2 = .06+.9*u.fsoft;
      fo = 1.-smoothstep(m-wd2, m+wd2, q.x/ext-.3*Dl); }
    if(fall==1 && grid) fo *= 1.-smoothstep(.72,.98,max(abs(p.x),abs(p.y)));
    cover *= clamp(fo+g.nz*u.gmix*3.*fo*(1.-fo), 0., 1.);
  }
  float v = (q.y*.9+Dl*.55)*u.lines*(.2+.8*e.patina)*30.;
  float fw = max(fwidth(v)*u.fwScale,1e-4);
  float line = (1.-smoothstep(.5,1.4,abs(fract(v)-.5)/fw))*(1.-smoothstep(.3,.6,fw))*cover;
  float3 paper = held ? (u.ground==1 ? float3(.90,.90,.885) : float3(.004,.004,.006)+deepC*.35) : g.ground;
  float3 pig = pow(em, float3(mix(.45,2.4,u.power)*(1.+.3*e.patina)));
  float la = line*u.lineop, l0 = (u.lblend==0) ? la : 0.;
  float3 col = (u.ground==1) ? mix(paper, pig, cover*mix(.55,1.,u.power))*(1.-.93*l0)
                             : shoulder(paper + pig*cover*mix(.6,2.6,u.power))*(1.+l0);
  col = mix(col, deepC, wd*cover);
  col = mix(col, grade(u, col), held ? 1. : cover);
  if(u.lblend>0) col = blendLine(col, la, u.lblend, u.ground==1);
  float a = 1., glow = 0.;
  if(framed && grid){
    float2 dd = abs(p)-(g.hlf*.86-.16);
    float sd = (u.grid.x*u.grid.y>20.) ? length(p)-.84 : length(max(dd,0.))+min(max(dd.x,dd.y),0.)-.16;
    a = 1.-smoothstep(-g.px, g.px, sd);
  }
  if(!freeF){
    float d = sdShape(u, g, p,R,e,t);
    float soft = R*(.006+.38*u.soft);
    a = 1.-smoothstep(-soft, soft*.6, d+g.nz*u.gmix*soft*1.3);
    glow = (d>0. ? .96*exp(-d/(R*.11))+.04*exp(-d/(R*.3)) : 1.)*(.15+.85*e.conn)*u.rim*.42;
  }
  return Hit{col,a,glow,col};
}

static Hit body(U, thread G& g, float2 p, E e){
  if(g.tank==1) p = tankSpace(u, g, p, e);
  return flowBody(u, g, p, e);   // uLook 2 only; the other looks are not ported
}

static float cellFade(U, float2 cuv){ return (u.grid.x*u.grid.y>1.5 || (u.slot==1 && u.mask==0)) ? 1.-smoothstep(.34,.5,max(abs(cuv.x),abs(cuv.y))) : 1.; }

static float3 compose(U, Hit h, float3 ground){
  if(u.ground==0) return ground*(1.-h.a) + h.col*h.a + h.rimc*h.glow*(1.-h.a)*.9;
  float3 g2 = mix(ground, ground*mix(float3(1.),h.rimc,.55), clamp(h.glow*(1.-h.a)*1.1,0.,1.));
  return mix(g2,h.col,h.a);
}

struct VOut { float4 pos [[position]]; };

vertex VOut gf_vertex(uint vid [[vertex_id]]){
  float2 a = float2(vid == 1 ? 3. : -1., vid == 2 ? 3. : -1.);   // the bench's one full-screen triangle
  VOut o; o.pos = float4(a, 0., 1.); return o;
}

// A's main(), split: everything before the fringe split …
struct Slot { float2 fc; float2 p; float2 cuv; float lensK; float rib; float hm; E e; float3 ground; };

static Slot slotSetup(U, thread G& g, float2 fc, bool displace){
  Slot s; s.fc = fc;
  float2 uv = fc/u.res;
  float2 cuv = fract(uv*u.grid)-.5;
  float2 cs = u.res/u.grid;
  float2 p = cuv*cs/(.5*min(cs.x,cs.y));
  g.hlf = cs/min(cs.x,cs.y); g.px = 1./(.5*min(cs.x,cs.y));
  float hm = .5*min(cs.x,cs.y);
  if(u.slot==1){ hm = .5*min(u.res.x,u.res.y)*u.zoom; p = (fc-.5*u.res-u.ctr)/hm; g.hlf = .5*u.res/hm; g.px = 1./hm; }
  float lensK = 0.;
  if(u.slot==1 && u.tank>0 && u.lens>0.){
    float2 ql = fc-.5*u.res; float band = 26.*u.pt; float2 m = max(abs(ql)-(.5*u.res-band), 0.);
    if(u.fadeB>0. && ql.y<0.) m.y = 0.;
    lensK = clamp(length(m)/band, 0., 1.);
    if(displace) p -= sign(ql)*m/max(length(m),1e-4)*pow(lensK,2.5)*band*1.5*u.lens*g.px;
  }
  float rib = 0.;
  if(u.slot==1 && u.tank>0 && u.glass==2){ float fwp = mix(5.,20.,u.flute)*u.pt; rib = fract(fc.x/fwp)-.5; if(displace) p.x += rib*fwp*g.px*1.8*u.glassAmt; }
  E e = E{u.hue,u.mass,u.parts,u.conn,u.tempo,u.amp,u.patina,u.seed, u.slot==1 ? u.rot : 0.};
  g.nz = ihash(fc)-.5;
  // uSheet and uGrid > 1 (the entry sheet, the bench's grid) are not ported: always 0 and (1,1) here.
  float3 ground = u.ground==0 ? float3(.0012,.0012,.0018) : float3(.83,.83,.82);
  if(u.slot==1) ground = u.surf;
  g.tank = u.slot==1 ? u.tank : 0;
  if(g.tank>0){
    g.TH = u.tankH; float yN = fc.y/u.res.y;
    if(g.tank==1){
      float2 ps = tankSpace(u, g, p,e); float occ = mix(.62,.86,e.mass), gsp = exp(-dot(ps,ps)/(occ*occ*2.6));
      float3 sp = mix(vivid(e.hue), vivid(e.hue+u.spread), smoothstep(-1.,1.,ps.x/occ));
      ground = u.ground==1 ? ground*mix(float3(1.), mix(float3(1.),min(sp,float3(1.)),.55), gsp*u.medium*.5) : ground+sp*gsp*u.medium*.045;
    }
    ground = u.ground==1 ? ground*(1.-.10*u.medium*(1.-yN)) : ground+float3(.010,.012,.018)*u.medium*yN*yN;
  }
  g.ground = ground;
  s.p = p; s.cuv = cuv; s.lensK = lensK; s.rib = rib; s.hm = hm; s.e = e; s.ground = ground;
  return s;
}

// … and everything after it (gamma, the fades, glass, lens rim light, grain, mask), shared by A and pass 2.
static float3 finish(U, float3 c, thread const Slot& s){
  float2 fc = s.fc; float lensK = s.lensK, rib = s.rib; E e = s.e;
  c = pow(clamp(c,0.,1.), float3(1./2.2));
  if(u.slot==1 && u.fade.y>0.) c = mix(c, pow(u.surf,float3(1./2.2)), smoothstep(u.fade.x,u.fade.y,fc.x/u.res.x));
  if(u.slot==1 && u.fadeV.y>0.) c = mix(c, pow(u.surf,float3(1./2.2)), smoothstep(u.fadeV.x,u.fadeV.y,1.-fc.y/u.res.y));
  float gr = ihash(fc+floor(u.time*24.)*float2(37.,17.))-.5;
  if(u.slot==1 && u.tank>0 && u.glass>0){
    float2 q = fc-.5*u.res; float r0 = (u.mask==3 && q.y>0.) ? u.maskR2 : u.maskR; float2 dd = abs(q)-(.5*u.res-r0);
    float sdg = length(max(dd,0.))+min(max(dd.x,dd.y),0.)-r0;
    float top = smoothstep(-.2,.9,q.y/(.5*u.res.y)), foot = u.fadeB>0. ? 0. : 1.;
    top *= foot;
    c *= 1.-.30*u.glassAmt*foot*exp(sdg/(10.*u.pt));
    c += u.glassAmt*.5*top*(1.-smoothstep(0.,1.6*u.pt,abs(sdg+1.6*u.pt)));
    c += u.glassAmt*.03*top*smoothstep(.55,1.,sin((q.x+q.y*.7)/u.res.x*5.+1.2));
    if(u.glass==2){ c *= 1.+.10*u.glassAmt*cos(rib*6.2832); c += .05*u.glassAmt*smoothstep(.42,.5,abs(rib)); }
  }
  c += .05*u.lens*pow(lensK,3.)*(.4+.6*dot(c,float3(.33)));
  float gk = (u.slot==1 && u.mask==0) ? smoothstep(.004,.03,length(c-pow(u.surf,float3(1./2.2)))) : 1.;
  if(u.grainOn==1) c += gk*gr*u.grain*.10*(1.+.8*e.patina)*(.3+.7*dot(c,float3(.33)));
  if(u.slot==1 && u.mask>0){
    float2 q = fc-.5*u.res; float r = (u.mask==3 && q.y>0.) ? u.maskR2 : u.maskR, sd;
    if(u.mask==2) sd = length(q)-.5*min(u.res.x,u.res.y);
    else { float2 dd = abs(q)-(.5*u.res-r); sd = length(max(dd,0.))+min(max(dd.x,dd.y),0.)-r; }
    c = mix(pow(u.back,float3(1./2.2)), c, 1.-smoothstep(-.7,.7,sd));
  }
  if(u.slot==1 && u.fadeB>0.) c = mix(pow(u.back,float3(1./2.2)), c, smoothstep(0.,u.fadeB,fc.y/u.res.y));
  return c;
}

static float2 fcOf(U, float4 pos){ return float2(pos.x-u.org.x, u.res.y-(pos.y-u.org.y)); }   // gl_FragCoord.xy − uOrg, y up
static float fringeOf(U){ return u.fringe*.04*(1.+.6*u.patina); }

// A · the faithful port: the body three times per pixel.
fragment float4 gf_fragment(VOut vin [[stage_in]], constant GFUniforms& u [[buffer(0)]]){
  if(u.flat==1) return float4(pow(u.surf, float3(1./2.2)), 1.);
  thread G g;
  Slot s = slotSetup(u, g, fcOf(u, vin.pos), true);
  float2 p = s.p; E e = s.e; float3 ground = s.ground;
  float3 c;
  float fr = u.fringe*.04*(1.+.6*e.patina);
  float cf = cellFade(u, s.cuv);
  if(fr>.0005){
    Hit r=body(u,g,p*(1.-fr),e); Hit gg=body(u,g,p,e); Hit b=body(u,g,p*(1.+fr),e);
    r.glow*=cf; gg.glow*=cf; b.glow*=cf;
    c = float3(compose(u,r,ground).r, compose(u,gg,ground).g, compose(u,b,ground).b);
  } else {
    Hit h1=body(u,g,p,e); h1.glow*=cf; c = compose(u,h1,ground);
  }
  return float4(finish(u, c, s), 1.);
}

// B / BD · pass 1: the body once per texel of the offscreen picture (field space, linear). A texel's slot position:
// fc = (x0 + x/s, y1 − y/s); at s = 1 with x0, y1 whole pixels, texel centres sit on slot pixel centres (G is exact).
struct BodyOut { float4 colA [[color(0)]]; float glow [[color(1)]]; };
fragment BodyOut gf_body(VOut vin [[stage_in]], constant GFUniforms& u [[buffer(0)]]){
  thread G g;
  float2 fc = float2(u.r1.x + vin.pos.x/u.r1.z, u.r1.y - vin.pos.y/u.r1.z);
  Slot s = slotSetup(u, g, fc, false);
  Hit h = body(u, g, s.p, s.e);
  BodyOut o; o.colA = float4(h.col, h.a); o.glow = h.glow; return o;
}

static Hit tapBody(U, float2 p, float hm, texture2d<float> tc, texture2d<float> tg, sampler sm){
  float2 fc = p*hm + .5*u.res + u.ctr;
  float2 uv = float2((fc.x-u.r1.x)*u.r1.z, (u.r1.y-fc.y)*u.r1.z)/u.r1Size;
  float4 ca = tc.sample(sm, uv); float gl = tg.sample(sm, uv).r;
  return Hit{ca.rgb, ca.a, gl, ca.rgb};
}

// B / BD · pass 2, at the slot's full size: three bilinear taps, composed over the ground, then A's finish().
fragment float4 gf_fringe(VOut vin [[stage_in]], constant GFUniforms& u [[buffer(0)]],
                          texture2d<float> tc [[texture(0)]], texture2d<float> tg [[texture(1)]]){
  if(u.flat==1) return float4(pow(u.surf, float3(1./2.2)), 1.);
  constexpr sampler sm(filter::linear, address::clamp_to_edge);
  thread G g;
  Slot s = slotSetup(u, g, fcOf(u, vin.pos), true);
  float fr = fringeOf(u), cf = cellFade(u, s.cuv);
  float3 c;
  if(fr>.0005){
    Hit r = tapBody(u, s.p*(1.-fr), s.hm, tc, tg, sm), gg = tapBody(u, s.p, s.hm, tc, tg, sm), b = tapBody(u, s.p*(1.+fr), s.hm, tc, tg, sm);
    r.glow*=cf; gg.glow*=cf; b.glow*=cf;
    c = float3(compose(u,r,s.ground).r, compose(u,gg,s.ground).g, compose(u,b,s.ground).b);
  } else {
    Hit h1 = tapBody(u, s.p, s.hm, tc, tg, sm); h1.glow*=cf; c = compose(u,h1,s.ground);
  }
  return float4(finish(u, c, s), 1.);
}

// ── Case (c), the Map pass ────────────────────────────────────────────────────────────────────────────────────────
// One quad per orb over its still (the centre 1.25 D of the bench's padded 1.5 D slot, baked WITHOUT grain). The still
// is opaque (the orb on the bench's page colour); it is laid over the ground with an alpha that is 1 out to the disc's
// soft edge and most of its rim glow (r ≤ 0.52 D) and 0 by 0.62 D, so a neighbour's padding never covers an orb. Grain
// is added here, per SCREEN pixel (design §1's departure), with the bench's own formula and amplitude.
struct MapVOut { float4 pos [[position]]; float2 q; float diam; float3 flatCol; float patina; float ready; float slice; float uvScale; };

vertex MapVOut gf_map_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             constant GFOrbInstance* orbs [[buffer(0)]], constant GFMapUniforms& m [[buffer(1)]]){
  GFOrbInstance o = orbs[iid];
  float2 corner = float2((vid & 1) ? 1. : -1., (vid & 2) ? 1. : -1.);
  float2 w = o.center + corner*o.halfSize;
  float2 sp = float2((w.x-m.cam.x)/m.camScale + .5*m.viewPt.x, .5*m.viewPt.y - (w.y-m.cam.y)/m.camScale);   // screen pt, y down
  MapVOut v;
  v.pos = float4(sp.x/m.viewPt.x*2.-1., 1.-sp.y/m.viewPt.y*2., 0., 1.);
  v.q = corner*o.halfSize; v.diam = o.diam; v.flatCol = o.flatCol; v.patina = o.patina; v.ready = o.ready; v.slice = o.slice; v.uvScale = o.uvScale;
  return v;
}

fragment float4 gf_map_fragment(MapVOut v [[stage_in]], constant GFMapUniforms& m [[buffer(1)]],
                                texture2d_array<float> stills [[texture(0)]]){
  constexpr sampler sm(filter::linear, mip_filter::linear, address::clamp_to_edge);
  float r = length(v.q), D = v.diam;
  float3 c;
  if(m.flat==0 && v.ready > .5){
    float2 uv = (v.q/(2.*float2(D*.625, -D*.625)) + .5)*v.uvScale;   // q is y up; texture rows run down
    c = stills.sample(sm, uv, uint(v.slice + .5)).rgb;
  } else {
    c = mix(v.flatCol, m.ground, smoothstep(.5*D-.6*m.camScale, .5*D+.6*m.camScale, r));   // flat disc, ~1 pt soft edge
  }
  if(m.grainOn==1){
    float2 px = floor(v.pos.xy);
    float gr = ihash(px+floor(m.time*24.)*float2(37.,17.))-.5;
    float gk = smoothstep(.004,.03,length(c-m.ground));
    c += gk*gr*m.grain*.10*(1.+.8*v.patina)*(.3+.7*dot(c,float3(.33)));
  }
  float a = 1.-smoothstep(.52*D, .62*D, r);
  return float4(c*a, a);
}


import test from 'node:test';import assert from 'node:assert/strict';import {build} from 'esbuild';
await build({entryPoints:['plugin/src/config.ts','plugin/src/ownership.ts','plugin/src/performance.ts','plugin/src/status.ts'],outdir:'build/test',format:'esm',platform:'node',bundle:true});
const {validate,chooseSR,defaults}=await import('../build/test/config.js');
const {OwnedEffects,passExecuted}=await import('../build/test/ownership.js');
const {PerformanceGuard}=await import('../build/test/performance.js');
const {runningStatus}=await import('../build/test/status.js');
const v={w:1280,h:720,outW:1920,outH:1080,gamma:'bt.1886',primaries:'bt.709'};
test('threshold and HDR guard',()=>{const c={...defaults,master:true};assert.equal(chooseSR(c,v),'fsrcnnx');assert.equal(chooseSR(c,{...v,outW:1280,outH:720}),'off');assert.equal(chooseSR(c,{...v,gamma:'pq'}),'off');assert.equal(chooseSR(c,{...v,gamma:''}),'off');});
test('validation rejects malformed preferences',()=>{assert.equal(validate({master:'yes',fps:120,strength:NaN}).master,false);assert.equal(validate({fps:120}).fps,48);});
test('ownership preserves external live edits',()=>{let list=['user.glsl','owned.glsl'];const mpv={getNative:()=>list,set:(_,v)=>{list=v},command:()=>{}};const o=new OwnedEffects(mpv,['owned.glsl','cas.glsl']);o.replaceShader('cas.glsl');assert.deepEqual(list,['user.glsl','cas.glsl']);list.push('new-user.glsl');o.replaceShader(null);assert.deepEqual(list,['user.glsl','new-user.glsl']);});
test('missing property is not treated as empty shader list',()=>{const o=new OwnedEffects({getNative:()=>null},['mine']);assert.throws(()=>o.replaceShader(null));});
test('shader selection is not execution evidence',()=>{assert.equal(passExecuted({fresh:[]},'IIVE'),false);assert.equal(passExecuted({fresh:[{desc:'IIVE FSRCNNX',count:3}]},'IIVE'),true);});
test('fallback needs three bad samples, cooldown and explicit recovery',()=>{const g=new PerformanceGuard();g.reset(0);assert.equal(g.sample(6000,0,0,false,true),null);assert.equal(g.sample(7000,4,.2,false,true),null);assert.equal(g.sample(8000,8,.2,false,true),null);assert.match(g.sample(9000,12,.2,false,true),/disabled/);assert.equal(g.fiDisabled,true);assert.equal(g.sample(10000,20,.2,false,false),null);g.reset(11000);assert.equal(g.fiDisabled,false);});
test('decode restore does not overwrite a later external change',()=>{let hw='auto-safe';const m={getNative:()=>hw,set:(_,v)=>{hw=v},command:()=>{}};const o=new OwnedEffects(m,[]);o.acquireSoftwareDecode();assert.equal(hw,'no');o.restoreDecode();assert.equal(hw,'auto-safe');o.acquireSoftwareDecode();hw='videotoolbox';o.restoreDecode();assert.equal(hw,'videotoolbox');});
test('mpv 0.41 decoder string-list survives a software-decode lease',()=>{let hw=['auto'];const m={getNative:()=>hw,set:(_,v)=>{hw=typeof v==='string'?[v]:v},command:()=>{}};const o=new OwnedEffects(m,[]);o.acquireSoftwareDecode();assert.deepEqual(hw,['no']);o.restoreDecode();assert.deepEqual(hw,['auto']);});
const runtime={loaded:true,paused:false,seeking:false,watchdog:true,sr:'fsrcnnx',srVerified:false,motion:false,motionVerified:false,level:0,fiDisabled:false,blocked:[],fault:''};
const enabled={...defaults,master:true};
test('status requires execution evidence and identifies explicit high-capacity model',()=>{
 assert.equal(runningStatus(enabled,v,runtime).overall.phase,'verifying');
 const s=runningStatus({...enabled,srModel:'fsrcnnx16'},v,{...runtime,srVerified:true});
 assert.equal(s.overall.phase,'active');assert.equal(s.model,'FSRCNNX 16');
 assert.equal(validate({srModel:'untrusted'}).srModel,'preset');
});
test('paused, missing video and master-off never announce Active',()=>{
 const r={...runtime,srVerified:true};
 assert.equal(runningStatus(enabled,v,{...r,paused:true}).sr.phase,'paused');
 assert.equal(runningStatus(enabled,v,{...r,loaded:false}).overall.phase,'idle');
 assert.equal(runningStatus(defaults,v,r).overall.phase,'off');
});
test('status differentiates bypass, unavailable RIFE and latched fallback',()=>{
 assert.equal(runningStatus(enabled,{...v,outW:1280,outH:720},{...runtime,sr:'off'}).sr.phase,'bypassed');
 assert.equal(runningStatus({...enabled,fiEnabled:true,fi:'rife'},v,runtime).fi.phase,'unavailable');
 const s=runningStatus(enabled,v,{...runtime,sr:'cas',srVerified:true,level:1});
 assert.equal(s.overall.phase,'degraded');assert.equal(s.sr.phase,'active');assert.equal(s.fi.phase,'off');
});
test('failed execution is distinct from a size/color bypass',()=>{
 assert.equal(runningStatus(enabled,v,{...runtime,sr:'off',blocked:['fsrcnnx']}).overall.phase,'error');
 assert.equal(runningStatus(enabled,{...v,gamma:'pq'},{...runtime,sr:'off'}).sr.phase,'bypassed');
});

test('legacy minterpolate preferences migrate to disabled without changing SR',()=>{const c=validate({master:true,sr:'fsrcnnx',fiEnabled:true,fi:'motion',fps:60});assert.equal(c.fi,'off');assert.equal(c.fiEnabled,false);assert.equal(c.sr,'fsrcnnx');assert.equal(c.fps,60);});

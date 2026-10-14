import {validate, chooseSR, selectedSRModel, Video, SR} from './config';
import {runningStatus} from './status';
import {OwnedEffects, passExecuted} from './ownership';
import {PerformanceGuard} from './performance';
import fsrcnn from '../shaders/FSRCNNX_x2_8-0-4-1.glsl';
import fsrcnnHQ from '../shaders/FSRCNNX_x2_16-0-4-1.glsl';
import ravu from '../shaders/ravu-lite-r3.hook';
import cas from '../shaders/CAS.glsl';
import watchdog from '../watchdog.lua';
const {mpv, preferences, sidebar, menu, event, file, utils}=iina;
let config=validate(preferences.get('config')), ready=false, loaded=false, stopping=false;
if((preferences.get('config') as {fi?:unknown}|null)?.fi==='motion'){preferences.set('config',config);preferences.sync();}
let sr:SR='off', srPath:string|null=null, srVerified=false, srSince=0;
let fault='';
let blocked=new Set<string>(), signature='', watchdogSent=false;
let lastTick=Date.now();
const guard=new PerformanceGuard(); guard.reset(Date.now());
const paths:Record<string,string>={};
function native<T>(key:string):T|null {try{return mpv.getNative<T>(key)??null;}catch{return null;}}
function number(key:string):number|null {const v=native<unknown>(key);return typeof v==='number' && Number.isFinite(v)?v:null;}
function install(name:string,text:string):string {
 const local='@data/iive-v010-'+name;
 if(!file.exists(local) || file.read(local)!==text)file.write(local,text);
 const resolved=utils.resolvePath(local); if(!resolved)throw new Error('Cannot resolve shader cache path.');return resolved;
}
function tagged(text:string,tag:string):string {return text.replace(/\/\/!DESC /g,'//!DESC IIVE '+tag+' ');}
paths.fsrcnnx=install('fsrcnnx.glsl',tagged(fsrcnn,'FSRCNNX'));
paths.fsrcnnxHQ=install('fsrcnnx-hq.glsl',tagged(fsrcnnHQ,'FSRCNNX16'));
paths.ravu=install('ravu.glsl',tagged(ravu,'RAVU'));
// Explicit transfer variants; the upstream CAS default assumes BT.1886.
for(const [gamma,trc] of Object.entries({'bt.1886':4,'bt.709':1,'srgb':3,'gamma2.2':6,'gamma2.4':6})) {
 for(let n=0;n<=10;n++) {
  const t=tagged(cas,'CAS').replace(/\/\/!WHEN[^\n]*/g,'//!WHEN 1').replace(/#define SOURCE_TRC \d/,`#define SOURCE_TRC ${trc}`).replace(/#define TARGET_TRC \d/,`#define TARGET_TRC ${trc}`).replace(/#define CUSTOM_GAMMA 2.2/g,`#define CUSTOM_GAMMA ${gamma==='gamma2.4'?'2.4':'2.2'}`).replace('#define SHARPENING 0.0',`#define SHARPENING ${(n/10).toFixed(1)}`);
  paths[`cas-${gamma}-${n}`]=install(`cas-${gamma}-${n}.glsl`,t);
 }
}
const owner=new OwnedEffects(mpv,Object.values(paths));
const luaPath=install('watchdog.lua',watchdog);
function lease(){
 if(!native('user-data/iive-watchdog') && !watchdogSent){mpv.command('load-script',[luaPath]);watchdogSent=true;}
 mpv.command('script-message',['iive-lease',JSON.stringify({paths:owner.paths,hwdecBefore:owner.hwdecBefore})]);
}
function video():Video {
 const v=native<Record<string,any>>('video-params')??{};
 const o=native<Record<string,number>>('osd-dimensions')??{};
 return {w:v.w??0,h:v.h??0,dw:v.dw??v.w??0,dh:v.dh??v.h??0,outW:(o.w??0)-(o.ml??0)-(o.mr??0),outH:(o.h??0)-(o.mt??0)-(o.mb??0),fps:number('container-fps'),gamma:v.gamma??'',primaries:v.primaries??'',pixel:v.pixelformat??''};
}
function apply(){
 if(stopping)return;
 try {
  const v=video(); const healthy=Boolean(native('user-data/iive-watchdog'));
  let next=loaded&&healthy?chooseSR(config,v,guard.level):'off';
  if(blocked.has(next))next='off';
  const path=next==='off'?null:next==='cas'?paths[`cas-${v.gamma}-${Math.round(config.strength*10)}`]:next==='fsrcnnx'&&selectedSRModel(config)==='fsrcnnx16'?paths.fsrcnnxHQ:paths[next];
  if(path!==srPath){owner.replaceShader(path??null);srPath=path??null;sr=next;srVerified=false;srSince=Date.now();}
  else owner.replaceShader(srPath); // merge with live external changes; never restore an old snapshot
  if(!config.master){owner.clear();sr='off';srPath=null;srVerified=false;}
 }catch(e){fault=String(e);try{owner.clear();}catch{}sr='off';srPath=null;srVerified=false;}
 publish();
}
function status(v=video()){
 return runningStatus(config,v,{loaded,paused:native('pause')===true,seeking:native('seeking')===true,watchdog:Boolean(native('user-data/iive-watchdog')),sr,srVerified,level:guard.level,fiDisabled:guard.fiDisabled,blocked:[...blocked],fault});
}
function publish(){
 const v=video();
 const indicators=status(v);
 mpv.set("user-data/iive-status", {sr,srVerified,motion:false,motionVerified:false,fault,loaded,video:v,indicators,updatedAt:Date.now()});
 if(!ready)return;
 sidebar.postMessage('state',{config,video:v,indicators,fault,blocked:[...blocked],fallback:{level:guard.level,fiDisabled:guard.fiDisabled},metrics:{sourceFPS:v.fps,targetFPS:config.fiEnabled?config.fps:null,measuredOutputFPS:null,filteredFPS:number('estimated-vf-fps'),dropped:number('frame-drop-count'),decoderDropped:number('decoder-frame-drop-count'),avSync:number('avsync'),aiLatency:null},rifeAvailable:false});
}
function tick(){
 if(stopping)return;
 try{
  lease(); const v=video();const sig=JSON.stringify([v.w,v.h,v.outW,v.outH,v.gamma,v.primaries,v.fps,v.pixel,loaded,config.master,Boolean(native('user-data/iive-watchdog'))]);
  if(sig!==signature){signature=sig;apply();}
  const paused=native<boolean>('pause')===true || native<boolean>('seeking')===true;
  const now=Date.now();
  // Verification budgets count active playback, not time spent paused/seeking.
  if(paused){srSince+=now-lastTick;guard.discontinuity(now);}
  lastTick=now;
  if(srPath && !(native<string[]>('glsl-shaders')??[]).includes(srPath)){
   blocked.add(sr);fault='Owned shader was removed externally. Enhancement disabled until Retry.';apply();
  }
  if(srPath&&!srVerified){
   const marker=sr==='fsrcnnx'?(srPath===paths.fsrcnnxHQ?'IIVE FSRCNNX16 aggregation':'IIVE FSRCNNX aggregation'):sr==='ravu'?'IIVE RAVU RAVU-Lite (step2':'IIVE CAS FidelityFX Sharpening (luma)';
   if(passExecuted(native('vo-passes'),marker)){srVerified=true;}
   else if(!paused && now-srSince>5000){blocked.add(sr);fault=`${sr.toUpperCase()} did not execute in this video backend. Disabled for this file.`;apply();}
  }
  if(config.master&&config.autoPerformance){const msg=guard.sample(now,number('frame-drop-count'),number('avsync'),paused,false);if(msg){fault=msg;apply();}}
  publish();
 }catch(e){fault=String(e);publish();}
}
function update(value:unknown){
 config=validate(value);preferences.set('config',config);preferences.sync();guard.reset(Date.now());blocked.clear();fault='';
 apply();
}
let sidebarLoaded=false;
function setupSidebar(){if(sidebarLoaded)return;sidebarLoaded=true;sidebar.loadFile('ui/sidebar.html');sidebar.onMessage('ready',()=>{ready=true;publish();});sidebar.onMessage('configure',update);sidebar.onMessage('retry',()=>{guard.reset(Date.now());blocked.clear();fault='';apply();});}
event.on('iina.window-loaded',setupSidebar);
if(iina.core.window.loaded)setupSidebar();
event.on('mpv.file-loaded',()=>{loaded=true;blocked.clear();guard.reset(Date.now());fault='';signature='';apply();});
event.on('mpv.end-file',()=>{loaded=false;owner.clear();sr='off';srPath=null;srVerified=false;publish();});
event.on('mpv.seek',()=>{guard.discontinuity(Date.now());srSince=Date.now();});
event.on('mpv.speed.changed',()=>{guard.discontinuity(Date.now());srSince=Date.now();});
event.on('iina.window-will-close',()=>{stopping=true;clearInterval(timer);owner.clear();mpv.command('script-message',['iive-release']);});
menu.addItem(menu.item('Open Enhancement',()=>sidebar.show()));
menu.addItem(menu.item('Show Enhancement Status',()=>{const s=status();iina.core.osd(`${s.overall.label} · SR: ${s.sr.label} (${s.model}) · FI: ${s.fi.label}`);}));
menu.addItem(menu.item('Disable All Enhancements',()=>update({...config,master:false})));
// Release a legacy 0.1 motion lease before advertising the new shader-only lease.
mpv.command('script-message',['iive-release']);owner.removeMotion();
lease();const timer=setInterval(tick,1000);
loaded=Boolean(native('video-params')); if(loaded)apply();

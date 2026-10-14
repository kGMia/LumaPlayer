import {Config, Video, SR, sdr, requestedSR, selectedSRModel, chooseSR} from './config';

export type Phase='off'|'idle'|'waiting'|'verifying'|'active'|'bypassed'|'unavailable'|'degraded'|'paused'|'seeking'|'error';
export type Tone='neutral'|'good'|'progress'|'warning'|'danger';
export interface Indicator {phase:Phase;label:string;detail:string;tone:Tone;}
export interface Runtime {
 loaded:boolean;paused:boolean;seeking:boolean;watchdog:boolean;
 sr:SR;srVerified:boolean;
 level:number;fiDisabled:boolean;blocked:string[];fault:string;
}
const label:Record<Phase,string>={off:'Off',idle:'No video',waiting:'Waiting',verifying:'Verifying',active:'Active',bypassed:'Bypassed',unavailable:'Unavailable',degraded:'Degraded',paused:'Paused',seeking:'Seeking',error:'Error'};
function indicator(phase:Phase,detail:string):Indicator {
 const tone:Tone=phase==='active'?'good':['waiting','verifying','seeking'].includes(phase)?'progress':['degraded','unavailable'].includes(phase)?'warning':phase==='error'?'danger':'neutral';
 return {phase,label:label[phase],detail,tone};
}
export function modelName(c:Config,mode:SR):string {
 return mode==='fsrcnnx'?(selectedSRModel(c)==='fsrcnnx16'?'FSRCNNX 16':'FSRCNNX 8'):mode==='ravu'?'RAVU Lite r3':mode==='cas'?'CAS sharpening':'Off';
}
export function runningStatus(c:Config,v:Video,r:Runtime) {
 const srWanted=c.srEnabled&&c.sr!=='off', fiWanted=c.fiEnabled&&c.fi!=='off';
 const base=()=>!c.master?indicator('off','Master Switch is off.'):!r.loaded?indicator('idle','Open a video to start.'):!r.watchdog?indicator('waiting','Waiting for the cleanup watchdog.'):null;
 const sr=():Indicator=>{
  if(!srWanted)return indicator('off','Super resolution is off.');
  const common=base();if(common)return common;
  if(!sdr(v))return indicator('bypassed','HDR, wide gamut or unsupported transfer; original color preserved.');
  if(r.level>=2)return indicator('degraded','Super resolution disabled after playback overload.');
  if(r.blocked.includes(requestedSR(c,r.level)))return indicator('error','Selected shader did not execute. Retry or choose another mode.');
  if(r.sr!=='off')return indicator(r.srVerified?'active':'verifying',`${modelName(c,r.sr)} · ${r.srVerified?'GPU pass confirmed':r.paused?'resume to verify GPU execution':'waiting for GPU execution'}.`);
  if(r.fault && chooseSR(c,v,r.level)!=='off' && !r.fiDisabled && r.level===0)return indicator('error',r.fault);
  return indicator('bypassed','Output size is below the selected shader’s scaling threshold.');
 };
 const fi=():Indicator=>{
  if(!fiWanted)return indicator('off','Frame interpolation is off.');
  const common=base();if(common)return common;
  return indicator('unavailable','RIFE requires a native player integration. CPU motion compensation has been removed.');
 };
 const srState=sr(),fiState=fi(),states=[srState,fiState];
 for(const state of states){
  if(state.phase==='active'&&(r.paused||r.seeking))Object.assign(state,indicator(r.seeking?'seeking':'paused',state.detail+' Waiting for playback.'));
 }
 const downgraded=r.level>0||r.fiDisabled;
 let overall=base();
 if(!overall){
  if(!srWanted&&!fiWanted)overall=indicator('off','No enhancement selected.');
  else if(states.some(x=>x.phase==='error'))overall=indicator('error','An enhancement failed. See its status below.');
  else if(downgraded)overall=indicator('degraded','Performance fallback is latched. Retry to restore requested settings.');
  else if(r.seeking)overall=indicator('seeking','Waiting for frames at the new position.');
  else if(r.paused)overall=indicator('paused','Playback is paused; enabled effects resume with playback.');
  else if(states.some(x=>x.phase==='verifying'))overall=indicator('verifying','Checking actual execution before reporting Active.');
  else if(states.some(x=>x.phase==='active'))overall=indicator('active','Enhancement confirmed in the current playback pipeline.');
  else if(states.some(x=>x.phase==='unavailable'))overall=indicator('unavailable','Requested enhancement is unavailable in this player.');
  else overall=indicator('bypassed','Enhancement is enabled but not applicable to this video or output size.');
 }
 const performance=!c.master?indicator('off','Master Switch is off.'):downgraded?indicator('degraded','Fallback remains latched until Retry or the next file.'):!c.autoPerformance?indicator('off','Automatic performance management is off.'):!r.loaded?indicator('idle','Waiting for playback.'):r.paused||r.seeking?indicator('paused','Overload checks resume after playback settles.'):indicator('active','Monitoring dropped frames and A/V drift; not GPU utilization.');
 return {overall,sr:srState,fi:fiState,performance,model:modelName(c,r.sr)};
}

export interface MPV {getNative<T=unknown>(name:string):T;set(name:string,value:any):void;command(name:string,args:string[]):void;}
export const FILTER_LABEL='iive-motion';
export class OwnedEffects {
 hwdecBefore:string|string[]|null=null;
 constructor(private mpv:MPV, readonly paths:string[]){}
 acquireSoftwareDecode(){
  if(this.hwdecBefore!==null)return;
  const before=this.mpv.getNative<unknown>('hwdec');
  if(typeof before!=='string' && !(Array.isArray(before)&&before.every(v=>typeof v==='string')))throw new Error('Cannot read decoder setting');
  this.hwdecBefore=Array.isArray(before)?[...before]:before as string;
  this.mpv.set('hwdec','no');
 }
 restoreDecode(){
  if(this.hwdecBefore===null)return;
  const current=this.mpv.getNative<unknown>('hwdec');
  // mpv 0.41 changed this option from a scalar to a native string list.
  if(current==='no'||(Array.isArray(current)&&current.length===1&&current[0]==='no'))this.mpv.set('hwdec',this.hwdecBefore);
  this.hwdecBefore=null;
 }
 replaceShader(path:string|null){
  const current=this.mpv.getNative<unknown>('glsl-shaders');
  if(!Array.isArray(current))throw new Error('Cannot read current shader list; leaving it unchanged.');
  const next=current.filter(p=>!this.paths.includes(p)); if(path)next.push(path);
  if(JSON.stringify(next)!==JSON.stringify(current))this.mpv.set('glsl-shaders',next);
 }
 removeMotion(){const vf=this.mpv.getNative<any[]>('vf'); if(Array.isArray(vf)&&vf.some(f=>f.label===FILTER_LABEL))this.mpv.command('vf',['remove','@'+FILTER_LABEL]);}
 clear(){this.replaceShader(null);this.removeMotion();this.restoreDecode();}
}
export function passExecuted(passes:unknown, marker:string):boolean {
 if(!passes || typeof passes!=='object')return false;
 const p=passes as Record<string,unknown>;
 return ['fresh','redraw'].some(k=>Array.isArray(p[k]) && (p[k] as any[]).some(v=>typeof v.desc==='string' && v.desc.includes(marker) && typeof v.count==='number' && v.count>0));
}

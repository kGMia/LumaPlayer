export type SR = 'off' | 'auto' | 'fsrcnnx' | 'ravu' | 'cas';
export type Preset = 'performance' | 'balanced' | 'quality';
export interface Config { master: boolean; srEnabled: boolean; sr: SR; srModel:'preset'|'fsrcnnx8'|'fsrcnnx16'; fiEnabled: boolean; fi: 'off' | 'rife'; fps: 48 | 60; preset: Preset; autoPerformance: boolean; strength: number; }
export const defaults: Config = { master:false, srEnabled:true, sr:'auto', srModel:'preset', fiEnabled:false, fi:'off', fps:48, preset:'balanced', autoPerformance:true, strength:0.3 };
export function validate(value: unknown): Config {
 const x = value && typeof value === 'object' ? value as Record<string,unknown> : {};
 const c = {...defaults};
 for (const k of ['master','srEnabled','fiEnabled','autoPerformance'] as const) if(typeof x[k]==='boolean') c[k]=x[k];
 if(['off','auto','fsrcnnx','ravu','cas'].includes(String(x.sr))) c.sr=x.sr as SR;
 if(['preset','fsrcnnx8','fsrcnnx16'].includes(String(x.srModel)))c.srModel=x.srModel as Config['srModel'];
 if(['off','rife'].includes(String(x.fi))) c.fi=x.fi as Config['fi'];
 if(['performance','balanced','quality'].includes(String(x.preset))) c.preset=x.preset as Preset;
 if(x.fps===48 || x.fps===60)c.fps=x.fps;
 if(typeof x.strength==='number' && Number.isFinite(x.strength)) c.strength=Math.round(Math.max(0,Math.min(1,x.strength))*10)/10;
 // Retired CPU minterpolate must not reactivate from persisted 0.1 settings.
 if(x.fi==='motion'){c.fi='off';c.fiEnabled=false;}
 return c;
}
export interface Video { w:number; h:number; dw:number; dh:number; outW:number; outH:number; fps:number|null; gamma:string; primaries:string; pixel:string; }
export function sdr(v: Video): boolean { return ['bt.1886','bt.709','srgb','gamma2.2','gamma2.4'].includes(v.gamma) && !['bt.2020','display-p3'].includes(v.primaries); }
export function selectedSRModel(c:Config):'fsrcnnx8'|'fsrcnnx16' {return c.srModel==='preset'?(c.preset==='quality'?'fsrcnnx16':'fsrcnnx8'):c.srModel;}
export function requestedSR(c:Config,level=0):SR {return c.sr==='auto' ? (c.preset==='performance' || level===1 ? 'cas' : 'fsrcnnx') : (level===1 && c.sr!=='off' ? 'cas' : c.sr);}
export function chooseSR(c: Config,v:Video,level=0): SR {
 if(!c.master || !c.srEnabled || level>=2 || !sdr(v)) return 'off';
 const mode = requestedSR(c,level);
 // Shaders scale the coded LUMA grid, not the display aspect-ratio grid.
 if(mode==='fsrcnnx' && !(v.outW/v.w>1.3 && v.outH/v.h>1.3))return 'off';
 if(mode==='ravu' && !(v.outW/v.w>Math.SQRT2 && v.outH/v.h>Math.SQRT2))return 'off';
 return mode;
}

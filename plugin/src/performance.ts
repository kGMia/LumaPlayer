// A one-way ladder per file avoids oscillation. Recovery is explicit or on next file.
export class PerformanceGuard {
 level=0; fiDisabled=false; private bad=0; private previous:number|null=null; private grace=0;
 reset(now:number) { this.level=0; this.fiDisabled=false; this.bad=0; this.previous=null; this.grace=now+5000; }
 discontinuity(now:number) {this.previous=null;this.bad=0;this.grace=now+5000;}
 sample(now:number,drops:number|null,avsync:number|null,paused:boolean,fi:boolean):string|null {
  if(paused || now<this.grace || drops===null) {this.previous=drops;this.bad=0;return null;}
  const delta=this.previous===null?0:Math.max(0,drops-this.previous); this.previous=drops;
  this.bad=(delta>=3 || (avsync!==null && Math.abs(avsync)>0.15)) ? this.bad+1 : Math.max(0,this.bad-1);
  if(this.bad<3)return null;
  this.bad=0;this.grace=now+10000;
  if(fi && !this.fiDisabled){this.fiDisabled=true;return 'Motion compensation disabled: sustained playback overload.';}
  if(this.level<2){this.level++;return this.level===1?'Reduced to CAS: sustained playback overload.':'Enhancement disabled: sustained playback overload.';}
  return null;
 }
}

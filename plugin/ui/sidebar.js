// Strings are isolated here/HTML to allow a future locale dictionary.
let config={};
let lastReceived=0,stale=false;
const fields=['master','srEnabled','sr','srModel','fiEnabled','fi','fps','preset','autoPerformance','strength'];
const setText=(id,text)=>{const el=document.getElementById(id);if(el.textContent!==text)el.textContent=text;};
function renderIndicator(id,state){document.getElementById(id==='runtime'?'runtime':`${id}-status`).dataset.tone=state.tone;setText(`${id}-label`,state.label);setText(`${id}-detail`,state.detail);}
function unavailable(){
 stale=true;
 renderIndicator('runtime',{tone:'warning',label:'Status unavailable',detail:'Player updates stopped. Current enhancement state is unknown.'});
 for(const id of ['sr','fi','performance'])renderIndicator(id,{tone:'neutral',label:'Unknown',detail:'Waiting for fresh player telemetry.'});
 document.getElementById('metrics').replaceChildren();
 const dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent='Telemetry';dd.textContent='N/A';document.getElementById('metrics').append(dt,dd);
}
for(const key of fields)document.getElementById(key).addEventListener('change',e=>{
 const el=e.target;config[key]=el.type==='checkbox'?el.checked:['fps','strength'].includes(key)?Number(el.value):el.value;
 iina.postMessage('configure',config);
});
document.getElementById('retry').onclick=()=>iina.postMessage('retry');
const fmt=(v,d=2)=>typeof v==='number'&&Number.isFinite(v)?v.toFixed(d):'N/A';
iina.onMessage('state',s=>{
 lastReceived=Date.now();stale=false;
 config=s.config;
 for(const k of fields){const el=document.getElementById(k);if(document.activeElement===el)continue;if(el.type==='checkbox')el.checked=config[k];else el.value=String(config[k]);}
 for(const k of ['fsrcnnx','ravu','cas'])document.querySelector(`#sr option[value="${k}"]`).disabled=s.blocked.includes(k);
 renderIndicator('runtime',s.indicators.overall);
 for(const id of ['sr','fi','performance'])renderIndicator(id,s.indicators[id]);
 setText('heartbeat','Live · player updates every second');
 document.getElementById('fault').hidden=!s.fault;setText('fault',s.fault);
 const rows=[['Current SR Model',s.indicators.model],['Source Resolution',s.video.w?`${s.video.w} × ${s.video.h}`:'N/A'],['Output Area',s.video.outW?`${s.video.outW} × ${s.video.outH}`:'N/A'],['Source FPS',fmt(s.metrics.sourceFPS)],['Target FPS',fmt(s.metrics.targetFPS,0)],['Measured Output FPS',fmt(s.metrics.measuredOutputFPS)],['Filtered FPS (estimate)',fmt(s.metrics.filteredFPS)],['Dropped Frames',fmt(s.metrics.dropped,0)],['Decoder Drops',fmt(s.metrics.decoderDropped,0)],['A/V Drift (s)',fmt(s.metrics.avSync,3)],['AI Inference Latency','N/A'],['Transfer',s.video.gamma||'N/A']];
 const dl=document.getElementById('metrics');dl.replaceChildren();for(const [k,v]of rows){const dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=k;dd.textContent=v;dl.append(dt,dd);}
});
const openedAt=Date.now();
setInterval(()=>{
 const elapsed=Date.now()-(lastReceived||openedAt);
 if(elapsed>5500){if(!stale)unavailable();setText('heartbeat',lastReceived?`Last update ${Math.floor(elapsed/1000)}s ago`:'No player status received');}
},1000);
iina.postMessage('ready');

// Deterministic fake DOM/WebAudio/SSE, replaying the checked Python tour's real POST bodies.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function page(offset, start=1000, delay=0, mute=false) {
  let wall=start, ac=0, next=0, suspended=false;
  const timers=[], sources=[], reports=[], listeners={};
  const later=(fn, ms=0)=>{timers.push({id:++next,at:wall+ms/1000,fn});return next;};
  const el=()=>{
    const e={style:{setProperty(){}},children:[],className:'',offsetWidth:1208,offsetHeight:704,clientLeft:0,clientTop:0,
      append(...xs){for(const x of xs){this.children.push(x);x.parentNode=this;}},appendChild(x){this.append(x);},
      prepend(x){this.children.unshift(x);},replaceChildren(...xs){this.children=[];this.append(...xs);},
      setAttribute(k,v){if(k==='class')this.className=v;},remove(){},removeAttribute(){},load(){},pause(){},
      get firstChild(){return this.children[0];},get lastChild(){return this.children.at(-1);}};
    e.classList={add(k){if(!e.className.split(' ').includes(k)) e.className+=' '+k;},
      remove(k){e.className=e.className.split(' ').filter(x=>x!==k).join(' ');},
      toggle(k,on){on?this.add(k):this.remove(k);}};
    return e;
  };
  const host=el(), document={head:el(),body:el(),createElement:el,createElementNS:el,
    getElementById:id=>id==='cam-main'?host:id==='stage'?host:null};
  class Audio {
    constructor(){this.destination={};}
    get currentTime(){return ac;} get state(){return suspended?'suspended':'running';}
    resume(){return suspended ? new Promise(()=>{}) : Promise.resolve();}
    async decodeAudioData(){return {duration:fixture.clip.duration};}
    createGain(){return {connect(){},gain:{value:1,cancelScheduledValues(){},setValueAtTime(){},linearRampToValueAtTime(){}}};}
    createBufferSource(){const s={connect(){},start(when){this.when=when;sources.push(this);},stop(){this.ended=true;this.onended?.();}};return s;}
  }
  const ctx=vm.createContext({window:{AudioContext:Audio},document,URLSearchParams,location:{search:mute?'?mute':''},
    Date:{now:()=>(wall-offset)*1000},console,setTimeout:later,clearTimeout:id=>{const t=timers.find(x=>x.id===id);if(t)t.at=Infinity;},
    requestAnimationFrame:fn=>later(fn,16),EventSource:class {addEventListener(k,f){listeners[k]=f;}},
    fetch:async(u,o)=>{
      if(u==='/audio/played'){reports.push(JSON.parse(o.body));return {ok:true};}
      if(delay)await new Promise(resolve=>later(resolve,delay*1000));
      return {arrayBuffer:async()=>new ArrayBuffer(0)};
    }});
  for(const f of ['playback-clock.js','audio.js'])vm.runInContext(fs.readFileSync(path.join(here,'static',f),'utf8'),ctx);
  ctx.window.pogPlaybackClock.observe(wall);
  ctx.window.pogState={tour:[fixture.overlay]};
  vm.runInContext(fs.readFileSync(path.join(here,'static','tourlay.js'),'utf8'),ctx);
  const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
  async function advance(seconds){
    const end=wall+seconds;
    while(wall<end-1e-8){const dt=Math.min(.02,end-wall);wall+=dt;if(!suspended)ac+=dt;
      for(const s of sources)if(!s.ended && ac>=s.when+s.buffer.duration){s.ended=true;s.onended?.();}
      for(const t of [...timers].sort((a,b)=>a.at-b.at))if(t.at<=wall){timers.splice(timers.indexOf(t),1);t.fn();}
      await flush();
    }
  }
  return {ctx,reports,advance,sources,pause:on=>{suspended=on;},now:()=>wall,
    send(meta={}){listeners.audio({data:JSON.stringify({...fixture.clip,url:'/audio/test',t:900,server_time:wall,...meta})});},
    caption(){const box=host.children.find(x=>x.className.startsWith('tour-subs'));return box?.className.split(' ').includes('on')?box.firstChild.textContent:null;}};
}
for(const offset of [120,-120]){
  const p=page(offset);p.send();await p.advance(fixture.clip.at-1000+.5);
  assert.equal(p.caption(),fixture.overlay.subs[0].text,`service skew ${offset}`);
  p.pause(true);await p.advance(.7);assert.equal(p.caption(),fixture.overlay.subs[0].text,'pause freezes subtitle cursor');
  p.pause(false);await p.advance(3);assert.equal(p.caption(),fixture.overlay.subs[1].text);
  await p.advance(5);assert.equal(p.caption(),null);
  const start=p.reports.find(r=>r.state==='start'),end=p.reports.find(r=>r.state==='end');
  assert.ok(Math.abs(start.started_at-fixture.clip.at)<.03);assert.ok(end.played>=fixture.clip.duration);
}
// Network/decode arrives one second after the scheduled epoch; subtitle one waits for actual audio.
const late=page(180,1000,fixture.clip.at-1000+1);late.send();await late.advance(fixture.clip.at-1000+.5);
assert.equal(late.caption(),null);await late.advance(1);assert.equal(late.caption(),fixture.overlay.subs[0].text);
assert.ok(late.reports.find(r=>r.state==='start').started_at>=fixture.clip.at+1);
await late.advance(6);assert.equal(late.caption(),null);
// Reload halfway through a stop: the service does not replay started narration; never show orphan subtitles.
const old=page(-90);old.send();await old.advance(fixture.clip.at-1000+3.5);
assert.equal(old.caption(),fixture.overlay.subs[1].text);
const reload=page(-90,old.now());await reload.advance(.1);assert.equal(reload.caption(),null);
reload.send();await reload.advance(.1);assert.equal(reload.reports.filter(r=>r.state==='start').length,0);
assert.equal(reload.reports.find(r=>r.state==='skip').reason,'late');
// Pending narration replay uses fresh server time even though creation time is stale.
const pending=page(150,fixture.clip.at-.5);pending.send();await pending.advance(1);assert.equal(pending.caption(),fixture.overlay.subs[0].text);
// A muted preview still has corrected service time without instantiating WebAudio.
const muted=page(240,fixture.clip.at+.5,0,true);await muted.advance(.1);assert.equal(muted.caption(),fixture.overlay.subs[0].text);
const locked=page(-180);locked.pause(true);locked.send();await locked.advance(fixture.clip.at-1000+3);
assert.equal(locked.caption(),null);assert.equal(locked.reports.filter(r=>r.state==='start').length,0);
assert.equal(locked.reports.find(r=>r.state==='skip').reason,'late');
console.log('playback clock: full stop, service +/- skew, late start, pause/resume, mid-stop reload, pending replay, muted preview, locked audio timeout passed');

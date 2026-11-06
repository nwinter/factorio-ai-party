import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('./static/shift-recap.js', import.meta.url), 'utf8');
class Node {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.events = {}; this.style = {}; this.hidden = false;
    this.classList = {toggle:(name,on)=>{const set=new Set(this.className.split(' ').filter(Boolean));
      if(on)set.add(name);else set.delete(name);this.className=[...set].join(' ');},
      add:name=>this.classList.toggle(name,true), contains:name=>this.className.split(' ').includes(name)};
    this.className = ''; this.textContent = ''; this.clientHeight = 0;
  }
  get isConnected() {return !!this.parent || this.tagName === 'body';}
  append(...children) {for(const child of children){this.children.push(child);child.parent=this;}}
  appendChild(child) {this.append(child);}
  replaceChildren(...children) {for(const c of this.children)c.parent=null;this.children=[];this.append(...children);}
  setAttribute(k,v) {this.attrs ??= {}; this.attrs[k]=v;if(k==='class')this.className=v;}
  removeAttribute(k) {delete this[k];}
  addEventListener(k,fn) {this.events[k]=fn;}
  pause(){this.paused=true;}
  load(){this.released=true;}
  play(){this.played=true;return Promise.resolve();}
}
function page() {
  const created=[];
  const body=new Node('body'), stage=new Node('div'), cam=new Node('div'), side=new Node('aside');
  stage.id='stage';cam.id='cam-main';side.id='side';body.append(stage);stage.append(cam,side);
  const all=n=>[n,...n.children.flatMap(all)];
  const document={body,createElement:tag=>{const n=new Node(tag);created.push(n);return n;},createElementNS:(ns,tag)=>new Node(tag),getElementById:id=>all(body).find(n=>n.id===id)};
  const context={document,window:{},location:{search:''},URLSearchParams,setTimeout,clearTimeout,requestAnimationFrame:fn=>fn(),getComputedStyle:()=>({fontSize:'32px'})};
  vm.runInNewContext(source,context);
  return {created,body,stage,cam,side,all:()=>all(body),render:context.window.PogShiftRecap.render,
    panel:()=>document.getElementById('shift-recap')};
}
const beat={active:true,run:'shift1',phase:'recap',id:'a',speaker:'Vale',title:'Science packs',
 text:'Packs gathered on Nauvis.',time_label:'Record · 12:39 PDT',media:null};
const active=p=>{assert.equal(p.panel().parent,p.stage);assert.equal(p.panel().hidden,false);
 assert.equal(p.body.classList.contains('recap-active'),true);assert.deepEqual(p.cam.style,{});assert.deepEqual(p.side.style,{});};
const restored=p=>{assert.equal(p.panel().hidden,true);assert.equal(p.body.classList.contains('recap-active'),false);
 assert.deepEqual(p.cam.style,{});assert.deepEqual(p.side.style,{});};
const p=page();
p.render({shift_recap:beat});active(p); // no agents: earliest service state
assert.equal(p.panel().classList.contains('sr-playing'),false);
p.render({shift_recap:{...beat,phase:'transition'}});active(p);
assert.ok(p.all().some(n=>n.textContent.includes('SHIFT CHANGE')));
for(const state of [null,{active:false},{...beat,holding:true}]) {
 p.render({shift_recap:state});restored(p);p.render({shift_recap:beat});active(p);
}
p.render({});restored(p); // interrupted/missing recap
const image={kind:'image',url:'assets/still.webp',subject:'Nauvis',recorded_time:'13:18 PDT'};
p.render({shift_recap:{...beat,media:image}});active(p);
assert.equal(p.all().find(n=>n.tagName==='img'),undefined,'stills cannot cover live gameplay');
p.render({shift_recap:{...beat,media:image,elapsed:3}});
assert.equal(p.panel().classList.contains('sr-playing'),false);
const clip={...image,kind:'video',url:'assets/existing.webm',offset:2};
p.render({shift_recap:{...beat,media:clip,elapsed:3}});
const video=p.all().find(n=>n.tagName==='video');video.duration=20;video.events.loadedmetadata();
assert.equal(video.currentTime,5);assert.equal(video.muted,true);assert.equal(video.played,true);assert.equal(video.loop,true);
video.events.playing();assert.equal(p.panel().classList.contains('sr-playing'),true);
p.render({shift_recap:{...beat,media:clip,elapsed:8}});assert.equal(p.all().find(n=>n.tagName==='video'),video,'ticks preserve playback');
p.render({shift_recap:null});restored(p);assert.equal(video.paused,true);assert.equal(video.released,true);
const reload=page();reload.render({shift_recap:{...beat,media:image,id:'current'}});active(reload);
assert.equal(reload.all().filter(n=>n.tagName==='img').length,0);
const after=page();after.render({shift_recap:null});restored(after);
const broken=page();broken.render({shift_recap:{...beat,media:clip}});broken.all().find(n=>n.tagName==='video').events.error();assert.equal(broken.panel().classList.contains('sr-playing'),false);
console.log('Shift recap DOM states: early, transition, still rejection, live fallback, clip seek, hold, interruption, reload, restore passed');

const anchored=page(), detail={...image,detail:{crop:[800,0,480,400],point:[1152,104],radius:[64,64],px:[1280,720],name:'front-right turret',context_seconds:2,timing:'before record',delta_seconds:-10}};
anchored.render({shift_recap:{...beat,media:detail}});
const sourceImage=anchored.created.find(n=>n.tagName==='img');sourceImage.naturalWidth=1280;sourceImage.naturalHeight=720;sourceImage.events.load();
const crop=anchored.all().find(n=>n.className.includes('sr-target'));
assert.equal(crop.attrs.viewBox,'800 0 480 400');
assert.equal(crop.attrs.preserveAspectRatio,'xMidYMid meet');
anchored.render({shift_recap:{...beat,media:detail,elapsed:150}});
assert.equal(anchored.all().find(n=>n.className.includes('sr-target')),crop,'narration ticks retain the exact crop node');
assert.equal(anchored.all().find(n=>n.className==='sr-context').hidden,true);
anchored.render({shift_recap:{...beat,media:detail,holding:true}});restored(anchored);
console.log('Anchored detail crop, highlight, context timeout and narration hold passed');

const failedDetail=page();failedDetail.render({shift_recap:{...beat,media:detail}});
failedDetail.created.find(n=>n.tagName==='img').events.error();
failedDetail.render({shift_recap:{...beat,media:detail,elapsed:3}});
assert(failedDetail.all().some(n=>n.textContent.startsWith('OVERVIEW FALLBACK · recorded detail unavailable')));
failedDetail.render({shift_recap:null});

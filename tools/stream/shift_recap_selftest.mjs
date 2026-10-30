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
  setAttribute(k,v) {this[k]=v;}
  removeAttribute(k) {delete this[k];}
  addEventListener(k,fn) {this.events[k]=fn;}
  pause(){this.paused=true;}
  load(){this.released=true;}
  play(){this.played=true;return Promise.resolve();}
}
function page() {
  const body=new Node('body'), stage=new Node('div'), cam=new Node('div'), side=new Node('aside');
  stage.id='stage';cam.id='cam-main';side.id='side';body.append(stage);stage.append(cam,side);
  const all=n=>[n,...n.children.flatMap(all)];
  const document={body,createElement:tag=>new Node(tag),getElementById:id=>all(body).find(n=>n.id===id)};
  const context={document,window:{},requestAnimationFrame:fn=>fn(),getComputedStyle:()=>({fontSize:'32px'})};
  vm.runInNewContext(source,context);
  return {body,stage,cam,side,all:()=>all(body),render:context.window.PogShiftRecap.render,
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
assert.equal(p.panel().classList.contains('sr-neutral'),true);
p.render({shift_recap:{...beat,phase:'transition'}});active(p);
assert.ok(p.all().some(n=>n.textContent.includes('SHIFT CHANGE')));
for(const state of [null,{active:false},{...beat,holding:true}]) {
 p.render({shift_recap:state});restored(p);p.render({shift_recap:beat});active(p);
}
p.render({});restored(p); // interrupted/missing recap
const image={kind:'image',url:'assets/still.webp',subject:'Nauvis',recorded_time:'13:18 PDT'};
p.render({shift_recap:{...beat,media:image}});active(p);
const img=p.all().find(n=>n.tagName==='img');assert.equal(img.src,image.url);
p.render({shift_recap:{...beat,media:image,elapsed:3}});
assert.equal(p.all().find(n=>n.tagName==='img'),img,'tick does not reload the media');
img.events.error();assert.equal(p.panel().classList.contains('sr-neutral'),true);
const clip={...image,kind:'video',url:'assets/existing.webm',offset:2};
p.render({shift_recap:{...beat,media:clip,elapsed:3}});
const video=p.all().find(n=>n.tagName==='video');video.duration=20;video.events.loadedmetadata();
assert.equal(video.currentTime,5);assert.equal(video.muted,true);assert.equal(video.played,true);
p.render({shift_recap:null});restored(p);assert.equal(video.paused,true);assert.equal(video.released,true);
const reload=page();reload.render({shift_recap:{...beat,media:image,id:'current'}});active(reload);
assert.equal(reload.all().filter(n=>n.tagName==='img').length,1);
const after=page();after.render({shift_recap:null});restored(after);
console.log('Shift recap DOM states: early, transition, still, neutral, missing media, clip seek, hold, interruption, reload, restore passed');

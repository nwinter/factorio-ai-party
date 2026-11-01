// Real exported overlay + headless video decode, no OBS/game/service/audio calls.
// node recap_footage_browser.mjs REHEARSAL_DIR OUT PLAYWRIGHT_MODULE
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const [root,out,module='playwright']=process.argv.slice(2);
if(!root || !out) throw Error('REHEARSAL_DIR OUT PLAYWRIGHT_MODULE required');
const {chromium}=await import(module);
fs.mkdirSync(out,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.POG_TEST_CHROMIUM,
 args:['--autoplay-policy=no-user-gesture-required']});
const report=[];
try {
 for(const [kind,width,height] of [['landscape',1920,1080],['portrait',1080,1920]]) {
  const page=await browser.newPage({viewport:{width,height}}), errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const base=pathToFileURL(path.join(root,`onair-${kind}.html`)).href;
  await page.goto(base+'?case=transition');
  await page.waitForFunction(()=>window.PogRecapReplay?.ready);
  const info=()=>page.evaluate(()=>{
   const p=document.getElementById('shift-recap'),v=p.querySelector('video'),c=p.querySelector('.sr-caption');
   return {hidden:p.hidden,active:document.body.classList.contains('recap-active'),playing:p.classList.contains('sr-playing'),
    background:getComputedStyle(p).backgroundColor, text:p.querySelector('.sr-recorded')?.textContent,
    sidebar:getComputedStyle(document.getElementById('side')).opacity,
    overflow:c ? c.scrollHeight>c.clientHeight+1 : false,
    video:v ? {muted:v.muted,defaultMuted:v.defaultMuted,paused:v.paused,t:v.currentTime,
      frames:v.getVideoPlaybackQuality().totalVideoFrames,duration:v.duration} : null};
  });
  let state=await info();assert(state.active);assert(!state.playing);assert.equal(state.background,'rgba(0, 0, 0, 0)');
  await page.screenshot({path:path.join(out,kind+'-entry.png')});
  const indices=await page.evaluate(()=>({clip:PogRecapReplay.data.cases.clip,live:PogRecapReplay.data.cases.live,end:PogRecapReplay.data.sequence.length}));
  await page.evaluate(n=>PogRecapReplay.show(n),indices.clip);
  await page.waitForFunction(()=>document.querySelector('#shift-recap.sr-playing video'));
  const a=await info();await page.waitForTimeout(600);const b=await info();
  assert(a.video.muted && a.video.defaultMuted);assert(b.video.frames>a.video.frames,'clip decodes moving frames');
  assert(!b.overflow);await page.screenshot({path:path.join(out,kind+'-clip.png')});
  await page.evaluate(()=>{
   const p=new URLSearchParams(location.search);p.set('elapsed','5');history.replaceState(null,'','?'+p);
  });
  await page.reload();await page.waitForFunction(()=>document.querySelector('#shift-recap.sr-playing video'));
  const reload=await info();assert(reload.video.t>=5 && reload.video.t<7);assert(reload.video.muted);
  await page.screenshot({path:path.join(out,kind+'-reload.png')});
  // Once loaded, a decoder/network error must immediately expose the underlying feed.
  await page.evaluate(()=>document.querySelector('#shift-recap video').dispatchEvent(new Event('error')));
  const failure=await info();assert(!failure.playing && !failure.video);assert.equal(failure.background,'rgba(0, 0, 0, 0)');
  await page.evaluate(n=>PogRecapReplay.show(n),indices.live);
  const live=await info();assert(live.active && !live.video);assert(live.text.startsWith('LIVE GAMEPLAY'));
  await page.screenshot({path:path.join(out,kind+'-live.png')});
  // Every prepared caption fits, including the longer record extracts.
  const overflow=[];
  for(let n=0;n<indices.end;n++) {
   await page.evaluate(n=>PogRecapReplay.show(n),n);await page.waitForTimeout(40);
   if((await info()).overflow)overflow.push(n);
  }
  assert.deepEqual(overflow,[],'all prepared captions fit');
  await page.screenshot({path:path.join(out,kind+'-end.png')});
  await page.evaluate(n=>PogRecapReplay.show(n),indices.end);
  const end=await info();assert(end.hidden && !end.active && !end.video);assert.equal(end.sidebar,'1');
  await page.screenshot({path:path.join(out,kind+'-restore.png')});
  await page.reload();const endedReload=await info();assert(endedReload.hidden && !endedReload.active);
  await page.goto(base+'?case=holding');await page.waitForFunction(()=>window.PogRecapReplay?.ready);
  assert((await info()).hidden,'holding after narration restores the normal layout');
  assert.deepEqual(errors,[]);
  report.push({kind,indices,clipFrames:[a.video.frames,b.video.frames],reload,live,restored:end,errors,overflow});
  await page.close();
 }
 fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(report,null,2));
 console.log(JSON.stringify(report,null,2));
} finally {await browser.close();}

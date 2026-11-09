// Real exported pages, local image decoding and target visibility; never connects to the stream.
// node recap_detail_browser.mjs REHEARSAL_DIR OUT PLAYWRIGHT_MODULE
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const [root,out,module='playwright']=process.argv.slice(2);
const {chromium}=await import(module);
fs.mkdirSync(out,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.POG_TEST_CHROMIUM});
const report=[];
try {
 for(const [kind,width,height] of [['landscape',1920,1080],['portrait',1080,1920]]) {
  const page=await browser.newPage({viewport:{width,height}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.goto(pathToFileURL(path.join(root,`onair-${kind}.html`)).href+'?step=0');
  await page.waitForSelector('#shift-recap.sr-playing .sr-target');
  const inspect=()=>page.evaluate(()=>{
   const panel=document.getElementById('shift-recap'),svg=panel.querySelector('.sr-target'),mark=svg.querySelector('ellipse');
   const p=svg.createSVGPoint();p.x=mark.cx.baseVal.value;p.y=mark.cy.baseVal.value;
   const screen=p.matrixTransform(mark.getScreenCTM());
   const rect=n=>{const r=n.getBoundingClientRect();return {x:r.x,y:r.y,right:r.right,bottom:r.bottom,width:r.width,height:r.height};};
   return {point:{x:screen.x,y:screen.y},svg:rect(svg),caption:rect(panel.querySelector('.sr-caption')),header:rect(panel.querySelector('.sr-head')),
    context:rect(panel.querySelector('.sr-context')),contextHidden:panel.querySelector('.sr-context').hidden,
    crop:svg.getAttribute('viewBox'),label:panel.querySelector('.sr-recorded').textContent,
    overflow:panel.querySelector('.sr-caption').scrollHeight>panel.querySelector('.sr-caption').clientHeight+1};
  });
  const first=await inspect();
  assert(first.point.x>first.svg.x && first.point.x<first.svg.right);
  assert(first.point.y>first.svg.y && first.point.y<first.svg.bottom);
  assert(first.svg.y>=first.header.bottom && first.svg.bottom<=first.caption.y,'detail must not hide behind text');
  assert(first.point.x<first.context.x,'wider context must not cover target');
  assert(!first.overflow);assert(first.label.includes('before record (-10s)'));
  await page.screenshot({path:path.join(out,kind+'-detail-context.png')});
  await page.evaluate(()=>{window.savedDetail=document.querySelector('.sr-target');PogShiftRecap.render({shift_recap:{...PogRecapReplay.data.sequence[0],elapsed:150}});});
  assert(await page.evaluate(()=>savedDetail===document.querySelector('.sr-target')));
  const held=await inspect();assert(held.contextHidden);assert.equal(held.crop,first.crop);
  await page.screenshot({path:path.join(out,kind+'-detail-held.png')});
  await page.evaluate(()=>PogRecapReplay.show(1));
  await page.waitForFunction(()=>document.querySelector('.sr-recorded')?.textContent.startsWith('OVERVIEW FALLBACK'));
  assert.equal(await page.locator('.sr-target').count(),0);
  await page.screenshot({path:path.join(out,kind+'-fallback.png')});
  await page.evaluate(()=>PogShiftRecap.render({shift_recap:{...PogRecapReplay.data.sequence[0],holding:true}}));
  assert(await page.locator('#shift-recap').evaluate(n=>n.hidden));
  assert.deepEqual(errors,[]);report.push({kind,first,held,errors});await page.close();
 }
 fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
} finally {await browser.close();}

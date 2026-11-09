// Offline real overlay composition: node camera_polish_browser.mjs OUTPUT PLAYWRIGHT_MODULE
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const here = path.dirname(fileURLToPath(import.meta.url));
const [out, module = 'playwright'] = process.argv.slice(2);
if (!out) throw Error('OUTPUT PLAYWRIGHT_MODULE required');
fs.mkdirSync(out, {recursive:true});
const {chromium} = await import(module);
const child = spawn(process.env.POG_TEST_PYTHON || 'agent-python', [path.join(here,'overlay_recovery_fixture.py'),'--out',out], {stdio:['ignore','pipe','pipe']});
let errors = '';
child.stderr.on('data', b => errors += b);
const port = await new Promise((resolve,reject) => {
  let text = '';
  child.stdout.on('data', b => {text += b; if (text.includes('\n')) resolve(JSON.parse(text.split('\n')[0]).port);});
  child.once('exit', code => reject(Error('fixture exited '+code+errors)));
});
const url = 'http://127.0.0.1:'+port;
const command = async body => (await fetch(url+'/__fixture', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})).json();
const state = value => command({action:'state',value});
const browser = await chromium.launch({headless:true,executablePath:process.env.POG_TEST_CHROMIUM,
  args:['--autoplay-policy=no-user-gesture-required']}).catch(e => {child.kill('SIGTERM');throw e;});
const page = await browser.newPage({viewport:{width:1920,height:1080}});
const pageErrors = [];
page.on('pageerror', e => pageErrors.push(String(e)));
const check = async label => {
  const boxes = await page.evaluate(() => {
    const selectors = ['#platform-metrics','#cam-main .loadout','#cam-main .cam-label','#voice .cap.on','#alerts .alert','#cam-inset.on'];
    return selectors.flatMap(s => [...document.querySelectorAll(s)].filter(e => {
      const c=getComputedStyle(e),r=e.getBoundingClientRect();
      return !e.hidden && c.visibility !== 'hidden' && c.display !== 'none' && Number(c.opacity)>0 && r.width && r.height;
    }).map(e => {const r=e.getBoundingClientRect();return {s,left:r.left,right:r.right,top:r.top,bottom:r.bottom};}));
  });
  for (const card of boxes.filter(b => ['#platform-metrics','#cam-main .loadout'].includes(b.s)))
    for (const b of boxes.filter(b => b !== card))
      assert(!(card.left < b.right && b.left < card.right && card.top < b.bottom && b.top < card.bottom), `${label}: ${card.s} overlaps ${b.s}`);
  await page.screenshot({path:path.join(out,label+'.png')});
  return {label,boxes};
};
const sol = {name:'sol',display_name:'Sol',color:'#73b9f4',glyph:'S',alive:true,activity:'thinking',
  loadout:{mode:'combat',armor:{name:'power-armor'},guns:[{name:'submachine-gun',ammo:'uranium-rounds-magazine',count:100}]}};
const camera = name => ({agents:['sol'],owner:'sol',body_visible:false,client:'main',
  platform:{name,why:'remote',label:name+' · bow defense'},ship:{name,from:'Solar system edge',to:'Shattered planet',pct:20},
  work:'Sol checking '+name,frame:{surface:name,position:{x:0,y:-50},zoom:.5,frac:.8}});
const metrics = name => ({platform:name,featured:true,tick:100,age_s:0,speed_kms:120,
  leg:{from:'solar-system-edge',to:'shattered-planet',pct:20},kills_min:120,hits_min:2,damage_taken:80,
  turrets:{'rocket-turret':{count:10,targeting:5,empty:0}},ammo:[{name:'rocket',hub:400,turrets:100}],repair_packs:80});
const checks=[];
try {
  let scene={agents:[sol],cameras:{main:camera('Asterion')},platform_metrics:metrics('Asterion'),replay:{playing:false}};
  await state(scene);await page.goto(url);
  await page.waitForFunction(() => document.querySelector('#platform-metrics')?.textContent.includes('Asterion'));
  assert.equal(await page.locator('#cam-main .loadout:visible').count(),0);
  checks.push(await check('asterion-remote'));
  scene={...scene,cameras:{main:camera('Resolute')},platform_metrics:metrics('Asterion')};
  await state(scene);
  await page.waitForFunction(() => document.querySelector('#cam-main .cam-label')?.textContent.includes('Resolute'));
  assert.equal(await page.locator('#platform-metrics:visible').count(),0,'stale ship sample hidden during cut');
  checks.push(await check('resolute-before-sample'));
  scene.platform_metrics=metrics('Resolute');
  scene.cameras.inset={agents:['sol'],body_visible:true,client:'panel',frame:{follow:'sol',zoom:1}};
  scene.alerts=[{id:'hit',kind:'loss',text:'Courier lost a turret',t:Date.now()/1000}];
  await state(scene);
  await command({action:'speech',seconds:15,text:'Resolute is firing at approaching asteroids. The guns are supplied; Courier needs attention.'});
  await page.waitForSelector('#voice .cap.on');
  await page.waitForFunction(() => document.querySelector('#platform-metrics')?.textContent.includes('Resolute'));
  checks.push(await check('flight-with-caption-alert-inset'));
  await page.reload();
  await page.waitForFunction(() => document.querySelector('#platform-metrics')?.textContent.includes('Resolute'));
  checks.push(await check('reload-flight'));
  // Both legacy upper-left cards may be present in a mixed-version transition: equipment yields.
  scene={...scene,cameras:{main:{agents:['sol'],body_visible:true,ship:{name:'Resolute'},frame:{follow:'sol'}}}};
  await state(scene);
  await page.waitForSelector('#cam-main .loadout',{state:'attached'});
  await page.waitForFunction(() => document.querySelector('#cam-main .loadout')?.classList.contains('lo-yield'));
  checks.push(await check('equipment-yields-to-ship'));
  scene={agents:[sol],cameras:{main:{agents:['sol'],body_visible:true,frame:{follow:'sol'}}},platform_metrics:null};
  await state(scene);
  await page.waitForFunction(() => document.querySelector('#platform-metrics')?.hidden);
  checks.push(await check('back-to-character'));
  assert.deepEqual(pageErrors,[]);
  fs.writeFileSync(path.join(out,'composition.json'),JSON.stringify(checks,null,2));
  console.log('PASS composed overlay: subject changes, stale metrics, gear, captions, alert, inset, reload; '+checks.length+' screenshots');
} finally {
  await browser.close();child.kill('SIGTERM');
}

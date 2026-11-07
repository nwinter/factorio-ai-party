// Real Chrome over the service fixture, using public frames emitted by test_visible_identity.py.
// OUTPUT PLAYWRIGHT_MODULE; POG_TEST_CHROMIUM selects an installed Chrome.
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const here = path.dirname(fileURLToPath(import.meta.url));
const [out, module = 'playwright'] = process.argv.slice(2);
if (!out) throw Error('OUTPUT PLAYWRIGHT_MODULE required');
fs.mkdirSync(out, {recursive:true});
const python = process.env.POG_TEST_PYTHON || 'agent-python';
const statesPath = path.join(out, 'identity-states.json');
await new Promise((resolve, reject) => {
  const p = spawn(python, [path.join(here, 'test_visible_identity.py')], {
    env:{...process.env, POG_IDENTITY_STATES:statesPath}, stdio:['ignore','pipe','pipe']});
  let log=''; p.stdout.on('data', b=>log+=b); p.stderr.on('data', b=>log+=b);
  p.once('exit', code => {fs.writeFileSync(path.join(out,'regression.log'),log); code ? reject(Error(log)) : resolve();});
});
const states = JSON.parse(fs.readFileSync(statesPath));
const child = spawn(python, [path.join(here,'overlay_recovery_fixture.py'),'--out',out], {stdio:['ignore','pipe','pipe']});
let errors = '';
child.stderr.on('data', b => errors += b);
const port = await new Promise((resolve,reject) => {
  let text = '';
  child.stdout.on('data', b => {text += b; if (text.includes('\n')) resolve(JSON.parse(text.split('\n')[0]).port);});
  child.once('exit', code => reject(Error('fixture exited '+code+errors)));
});
const url = 'http://127.0.0.1:'+port;
const {chromium} = await import(module);
const browser = await chromium.launch({headless:true,executablePath:process.env.POG_TEST_CHROMIUM,
  args:['--autoplay-policy=no-user-gesture-required']}).catch(e => {child.kill('SIGTERM');throw e;});
const pageErrors = [], checks = [];
try {
  const pages = [];
  for (const [name, width, height, route] of [['landscape',1920,1080,'/'],['portrait',1080,1920,'/portrait']]) {
    const page = await browser.newPage({viewport:{width,height}});
    page.on('pageerror', e => pageErrors.push(String(e)));
    await page.goto(url+route); pages.push({name,page});
  }
  for (const [label, s] of states) {
    const ship = s.cameras.main?.ship?.name;
    // Intentionally keep stale telemetry through uncertainty, to test the final browser guard too.
    const value={...s, fixture_label:label, agents:[], replay:{playing:false}, platform_metrics:{
      platform:ship || 'Asterion', tick:100, age_s:0, speed_kms:120,
      leg:{from:'solar-system-edge',to:'shattered-planet',pct:20}}};
    const r=await fetch(url+'/__fixture',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({action:'state',value})}); assert(r.ok);
    for (const {name,page} of pages) {
      const check = async suffix => {
        await page.waitForFunction(({ship}) => {
          const card=document.querySelector('#platform-metrics'), label=document.querySelector('#cam-main .cam-label');
          return ship ? !card?.hidden && card?.textContent.includes(ship) && label?.classList.contains('on') && label.textContent.includes(ship)
            : card?.hidden && !label?.classList.contains('on') && !document.querySelector('#cam-main .ship-card');
        }, {ship});
        // Let at least one fixture update arrive even when two consecutive cases are both uncertain.
        await page.waitForTimeout(500);
        const geometry=await page.evaluate(() => {
          const box=document.querySelector('#platform-metrics'), label=document.querySelector('#cam-main .cam-label');
          const a=box.getBoundingClientRect(), b=label.getBoundingClientRect();
          return {cardHidden:box.hidden, labelVisible:label.classList.contains('on'),
            cardText:box.hidden?'':box.textContent, labelText:label.classList.contains('on')?label.textContent:'',
            collision:!box.hidden && label.classList.contains('on') && a.left<b.right && a.right>b.left && a.top<b.bottom && a.bottom>b.top};
        });
        assert(!geometry.collision);
        if (!ship) assert.equal(geometry.cardText+geometry.labelText,'');
        await page.screenshot({path:path.join(out,`${name}-${label}${suffix}.png`)});
        checks.push({name,label,suffix,ship:ship || null,...geometry});
      };
      await check('');
      // Reload both confirmed and uncertain states: no retained caption/card/localStorage identity.
      await page.reload(); await check('-reload');
    }
  }
  assert.deepEqual(pageErrors,[]);
  fs.writeFileSync(path.join(out,'composition.json'),JSON.stringify({chrome:browser.version(),checks,pageErrors},null,2));
  console.log(`PASS ${checks.length} Chrome compositions: partial reorder, external drift, same-source surface change, recovery and reload`);
} finally {await browser.close();child.kill('SIGTERM');}

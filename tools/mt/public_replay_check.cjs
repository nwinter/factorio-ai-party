// PLAYWRIGHT=/absolute/node_modules/playwright node tools/mt/public_replay_check.cjs ARTIFACTS
// Deterministic 1080p composite: actual mtt1 camera still underneath the production overlay.
const {chromium}=require(process.env.PLAYWRIGHT||'playwright');
const fs=require('node:fs'),path=require('node:path');
(async()=>{
 const dir=process.argv[2], frames=JSON.parse(fs.readFileSync(path.join(dir,'synthetic.json'))), recorded=JSON.parse(fs.readFileSync(path.join(dir,'mtt1-replay.json')));
 const browser=await chromium.launch({headless:true});const page=await browser.newPage({viewport:{width:1920,height:1080},deviceScaleFactor:1});
 const errors=[],requests=[];page.on('pageerror',e=>errors.push(e.message));page.on('response',r=>{if(r.status()>=400)errors.push(r.status()+' '+r.url());});page.on('request',r=>requests.push(r.url()));
 let selected=frames[4];
 await page.route('**/state.json',r=>r.fulfill({json:{...selected,now:Date.now()/1000,viewers:(selected.viewers||[]).map(v=>({...v,t:Date.now()/1000}))}}));
 await page.goto('http://127.0.0.1:8796/');
 const b64=fs.readFileSync(path.join(dir,'before-mtt1-16m.png')).toString('base64');
 await page.evaluate(b64=>{const frame=document.createElement('div');frame.style.cssText='position:absolute;left:24px;top:248px;width:1280px;height:720px;overflow:hidden;z-index:-1';const img=document.createElement('img');img.src='data:image/png;base64,'+b64;img.style.cssText='position:absolute;left:0;top:-64px;width:1706.667px;height:960px';frame.append(img);document.body.prepend(frame);},b64);
 const shots=[];
 async function shot(name,s){selected=s;await page.evaluate(s=>render({...s,now:Date.now()/1000,viewers:(s.viewers||[]).map(v=>({...v,t:Date.now()/1000}))}),s);await page.waitForTimeout(500);await page.screenshot({path:path.join(dir,name)});shots.push(name);}
 await shot('after-synthetic-opening.png',frames[4]);
 await shot('after-synthetic-lead-change.png',frames[19]);
 await shot('after-mtt1-final.png',recorded.at(-1));
 await shot('after-mtt1-start.png',recorded[12]);
 await shot('after-mtt1-foundations.png',recorded[5]);
 const four=structuredClone(frames[15]);const red=structuredClone(four.teams[0]);red.team='red';red.rank=4;red.leader=false;red.research.done_count=8;red.gap='11 techs back';red.agents=[0,1,2].map(i=>({...red.agents[0],name:'agent'+i,display_name:'Agent '+i}));four.teams.forEach(t=>t.agents=red.agents);four.teams.push(red);await shot('after-four-teams.png',four);
 const stale=structuredClone(frames[4]);stale.teams[0].stale=true;stale.teams[0].rank=null;stale.teams[0].leader=false;stale.teams[0].gap='Feed delayed';stale.teams[1].rank=1;stale.teams[1].leader=true;stale.teams[1].gap='Leading';stale.teams[2].rank=2;stale.teams[2].gap='4 techs back';await shot('after-stale-feed.png',stale);
 const timings=await page.evaluate(()=>{const times=[];for(let i=0;i<100;i++){const t=performance.now();draw();times.push(performance.now()-t);}return times.sort((a,b)=>a-b);});
 const serialized=await page.evaluate(()=>({scroll:[document.documentElement.scrollWidth,document.documentElement.scrollHeight],text:document.getElementById('summary').textContent,canvas:[canvas.width,canvas.height],camera_alpha:ctx.getImageData(640,600,1,1).data[3]}));
 if(serialized.camera_alpha!==0)errors.push('Camera window is not transparent');
 const out={shots,errors,requests:requests.length,paint_ms:{median:timings[50],p95:timings[95],max:timings[99]},...serialized};
 if(process.env.MT_SOAK){
   const started=Date.now(),seen=new Set(),timer=setInterval(()=>{selected=frames[Math.floor((Date.now()-started)/2000)%frames.length];},500);
   for(let i=0;i<15;i++){await page.waitForTimeout(5000);seen.add(await page.evaluate(()=>JSON.stringify(raceState().teams.map(t=>[t.research.progress,t.leader]))));}
   clearInterval(timer);out.soak={seconds:(Date.now()-started)/1000,distinct_states:seen.size};
   await page.screenshot({path:path.join(dir,'after-75s.png')});if(seen.size<8)errors.push('Moving replay stopped updating');
 }
 out.requests=requests.length;fs.writeFileSync(path.join(dir,'browser-check.json'),JSON.stringify(out,null,2));console.log(JSON.stringify(out,null,2));await browser.close();if(errors.length)process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1;});

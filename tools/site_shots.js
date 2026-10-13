#!/usr/bin/env node
// Screenshots and layout checks of the site's page types, at phone and desktop width, in both themes:
//   node tools/site_shots.js [BASE_URL] [OUT_DIR]        (default http://127.0.0.1:8765, site-shots/)
//   python3 -m http.server 8765 -d site/dist &            # the built site
// Needs Playwright (npm i -D playwright, or the copy npx keeps: PLAYWRIGHT=~/.npm/_npx/<id>/node_modules/playwright).
// Full-page shots at a normal window height (a very tall window inflates vh-capped elements). Prints, per page,
// what breaks on a phone: page-level horizontal scroll, visible text under 12.5 px, tap targets under 36 px, and
// elements wider than the page outside a scrolling box. Exits 1 when any page has one.
const fs = require('fs'), path = require('path'), os = require('os');

function playwright() {
  const tries = [process.env.PLAYWRIGHT, 'playwright'];
  try {
    const npx = path.join(os.homedir(), '.npm', '_npx');
    for (const d of fs.readdirSync(npx)) tries.push(path.join(npx, d, 'node_modules', 'playwright'));
  } catch (e) { /* no npx cache */ }
  for (const t of tries.filter(Boolean)) { try { return require(t); } catch (e) { /* next */ } }
  console.error('no Playwright: npm i -D playwright (or set PLAYWRIGHT to its folder)');
  process.exit(2);
}

const BASE = (process.argv[2] || 'http://127.0.0.1:8765').replace(/\/$/, '');
const OUT = process.argv[3] || 'site-shots';
const PAGES = [['home', '/'], ['live', '/live/'], ['run', '/runs/long/'], ['shift', '/runs/long/shift-2/'],
  ['agents', '/agents/'], ['timeline', '/timeline/'], ['chat', '/chat/'], ['search', '/search/?q=rocket'], ['about', '/about/']];
const SIZES = [['phone', 390, 844], ['desktop', 1300, 900]];

// in the page: what breaks the layout at this width
function audit() {
  const W = document.documentElement.clientWidth, out = { scroll: document.scrollingElement.scrollWidth - W, small: [], taps: [], wide: [] };
  const seen = new Set();
  const scrolls = (el) => { for (let p = el.parentElement; p; p = p.parentElement) { const o = getComputedStyle(p).overflowX; if (o === 'auto' || o === 'scroll' || o === 'hidden') return true; } return false; };
  const name = (el) => el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '');
  for (const el of document.querySelectorAll('body *')) {
    const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
    if (!r.width || !r.height || cs.visibility === 'hidden' || el.closest('svg, [hidden], details:not([open]) > :not(summary)')) continue;
    const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
    if (own && parseFloat(cs.fontSize) < 12.5 && !seen.has('s' + name(el))) { seen.add('s' + name(el)); out.small.push(`${name(el)} ${cs.fontSize} "${el.textContent.trim().slice(0, 30)}"`); }
    if (el.matches('a, button, input, select, summary, [role=tab]') && (r.height < 36 && r.width < 36 || r.height < 24) && !seen.has('t' + name(el))) {
      seen.add('t' + name(el)); out.taps.push(`${name(el)} ${Math.round(r.width)}x${Math.round(r.height)} "${(el.textContent || el.value || '').trim().slice(0, 20)}"`);
    }
    if (r.right > W + 1 && !scrolls(el) && !seen.has('w' + name(el))) { seen.add('w' + name(el)); out.wide.push(`${name(el)} right ${Math.round(r.right)}`); }
  }
  return out;
}

// The map viewer (static/mapview.js) on the live page's sample data and on the run page's time-lapse: the map, every
// layer on, zoomed and panned, an agent clicked (followed), full screen; prints the slowest frame (data-paint-ms) and
// flags one over 16 ms, a canvas wider than the page, or full screen that does not fill the window.
async function mapChecks(browser, size, w, h) {
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: size === 'phone' ? 3 : 1, hasTouch: size === 'phone' });
  let bad = 0;
  const shot = (name) => page.locator('.mapview').first().screenshot({ path: path.join(OUT, `map-${name}-${size}.png`) });
  try {
    await page.goto(`${BASE}/live/?demo=1`, { waitUntil: 'load', timeout: 20000 });
    await page.waitForSelector('.mapview canvas', { timeout: 10000 });
    await page.waitForTimeout(800);
    await shot('default');
    for (const b of await page.locator('.mapview-layer[aria-pressed="false"]').all()) await b.click();
    await page.waitForTimeout(200);
    await shot('layers');
    const box = await page.locator('.mapview canvas').boundingBox();
    const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
    let slow = 0;
    const ms = async () => { slow = Math.max(slow, +(await page.locator('.mapview').first().getAttribute('data-paint-ms')) || 0); };
    if (size === 'desktop') {
      for (let i = 0; i < 4; i++) { await page.mouse.move(cx, cy); await page.mouse.wheel(0, -240); await page.waitForTimeout(60); await ms(); }
      await page.mouse.move(cx, cy); await page.mouse.down();
      for (let i = 1; i <= 10; i++) { await page.mouse.move(cx + i * 12, cy + i * 6); await page.waitForTimeout(20); await ms(); }
      await page.mouse.up();
    } else {
      for (let i = 0; i < 3; i++) { await page.locator('[data-mv="in"]').click(); await page.waitForTimeout(60); await ms(); }
    }
    await shot('zoomed');
    // a click (a tap on a phone) on an agent's dot: the map follows it
    await page.locator('[data-mv="reset"]').click();
    await page.waitForTimeout(100);
    const dot = await page.evaluate(() => { const v = PogMap.viewers[0], h = v.sc && v.sc.hits.find((x) => x.agent); return h && { x: h.x, y: h.y, name: h.agent }; });
    const cb = await page.locator('.mapview canvas').boundingBox();
    if (dot) {
      if (size === 'phone') await page.touchscreen.tap(cb.x + dot.x, cb.y + dot.y); else await page.mouse.click(cb.x + dot.x, cb.y + dot.y);
      await page.waitForTimeout(150);
      const following = await page.locator('.mapview-follow:not([hidden])').textContent().catch(() => '');
      await shot('follow');
      if (!/Following/.test(following || '')) { bad = 1; console.log(`map ${size}: a click on ${dot.name} did not follow it`); }
    }
    await page.locator('[data-mv="full"]').click();
    await page.waitForTimeout(400);
    const full = await page.evaluate(() => { const r = document.querySelector('.mapview canvas').getBoundingClientRect(); return { w: r.width, h: r.height, W: innerWidth, H: innerHeight }; });
    await page.screenshot({ path: path.join(OUT, `map-full-${size}.png`) });
    const wide = box.x + box.width > w + 1;
    const filled = full.w >= full.W - 40 && full.h >= full.H * 0.6;
    if (slow > 16 || wide || !filled) bad = 1;
    console.log(`map ${size}: ${bad ? 'CHECK' : 'ok'} slowest frame ${slow} ms; canvas ${Math.round(box.width)}x${Math.round(box.height)}${wide ? ' WIDER THAN THE PAGE' : ''}; full screen ${Math.round(full.w)}x${Math.round(full.h)} of ${full.W}x${full.H}${filled ? '' : ' (does not fill)'}`);
    await page.keyboard.press('Escape');
    await page.goto(`${BASE}/runs/long/`, { waitUntil: 'load', timeout: 20000 });
    const tl = page.locator('#tlapse');
    if (await tl.count()) {
      await tl.scrollIntoViewIfNeeded();
      await page.waitForSelector('#tlapse .mapview canvas', { timeout: 10000 }).catch(() => null);
      await page.waitForTimeout(800);
      await tl.screenshot({ path: path.join(OUT, `map-timelapse-${size}.png`) });
      console.log(`map timelapse ${size}: shot`);
    }
  } catch (e) {
    console.log(`map ${size}: ${e.message.split('\n')[0]}`); bad = 1;
  } finally {
    await page.close();
  }
  return bad;
}

(async () => {
  const { chromium } = playwright();
  fs.mkdirSync(OUT, { recursive: true });
  // PW_CHANNEL=chrome uses the installed Google Chrome instead of Playwright's own download
  const browser = await chromium.launch({ args: ['--mute-audio'], ...(process.env.PW_CHANNEL ? { channel: process.env.PW_CHANNEL } : {}) });
  let bad = 0;
  try {
    for (const [size, w, h] of SIZES) {
      for (const theme of ['light', 'dark']) {
        const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });  // 2x passes Chrome's 16,384 px capture limit on long pages (the shot repeats)
        for (const [key, url] of PAGES) {
          const sep = url.includes('?') ? '&' : '?';
          try {
            await page.goto(`${BASE}${url}${sep}theme=${theme}`, { waitUntil: 'load', timeout: 20000 });  // the live page polls: never idle
          } catch (e) { console.log(`${key} ${size} ${theme}: ${e.message.split('\n')[0]}`); continue; }
          await page.waitForTimeout(800);
          const file = path.join(OUT, `${key}-${size}-${theme}.png`);
          await page.screenshot({ path: file, fullPage: true });
          if (theme === 'light') {  // the layout is the same in both themes
            const a = await page.evaluate(audit);
            const issues = (a.scroll > 1 ? 1 : 0) + (size === 'phone' ? a.small.length + a.taps.length : 0) + a.wide.length;
            bad += issues ? 1 : 0;
            console.log(`${key} ${size}: ${issues ? 'CHECK' : 'ok'}${a.scroll > 1 ? ` page scrolls ${a.scroll}px sideways;` : ''}`);
            if (size === 'phone') {
              if (a.small.length) console.log('  small text: ' + a.small.slice(0, 12).join(' | '));
              if (a.taps.length) console.log('  small taps: ' + a.taps.slice(0, 12).join(' | '));
            }
            if (a.wide.length) console.log('  too wide:   ' + a.wide.slice(0, 8).join(' | '));
          }
        }
        await page.close();
      }
      bad += await mapChecks(browser, size, w, h);
    }
  } finally {
    await browser.close();  // the browser never outlives the script
  }
  console.log(`${bad ? bad + ' page/size(s) to check' : 'all ok'}; shots in ${OUT}/`);
  process.exit(bad ? 1 : 0);
})();

#!/usr/bin/env node
// Screenshots and layout checks of the site's page types, at phone and desktop width, in both themes:
//   node tools/site_shots.js [BASE_URL] [OUT_DIR]        (default http://127.0.0.1:8765, site-shots/)
//   python3 -m http.server 8765 -d site/dist &            # the built site
// Needs Playwright (npm i -D playwright, or the copy npx keeps: PLAYWRIGHT=~/.npm/_npx/<id>/node_modules/playwright).
// Full-page shots at a normal window height (a very tall window inflates vh-capped elements). Prints, per page,
// what breaks on a phone: page-level horizontal scroll, visible text under 13 px, tap targets under 36 px, and
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
    if (own && parseFloat(cs.fontSize) < 13 && !seen.has('s' + name(el))) { seen.add('s' + name(el)); out.small.push(`${name(el)} ${cs.fontSize} "${el.textContent.trim().slice(0, 30)}"`); }
    if (el.matches('a, button, input, select, summary, [role=tab]') && (r.height < 36 && r.width < 36 || r.height < 24) && !seen.has('t' + name(el))) {
      seen.add('t' + name(el)); out.taps.push(`${name(el)} ${Math.round(r.width)}x${Math.round(r.height)} "${(el.textContent || el.value || '').trim().slice(0, 20)}"`);
    }
    if (r.right > W + 1 && !scrolls(el) && !seen.has('w' + name(el))) { seen.add('w' + name(el)); out.wide.push(`${name(el)} right ${Math.round(r.right)}`); }
  }
  return out;
}

(async () => {
  const { chromium } = playwright();
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ args: ['--mute-audio'] });
  let bad = 0;
  try {
    for (const [size, w, h] of SIZES) {
      for (const theme of ['light', 'dark']) {
        const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: size === 'phone' ? 2 : 1 });
        for (const [key, url] of PAGES) {
          const sep = url.includes('?') ? '&' : '?';
          try {
            await page.goto(`${BASE}${url}${sep}theme=${theme}`, { waitUntil: 'networkidle', timeout: 20000 });
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
    }
  } finally {
    await browser.close();  // the browser never outlives the script
  }
  console.log(`${bad ? bad + ' page/size(s) to check' : 'all ok'}; shots in ${OUT}/`);
  process.exit(bad ? 1 : 0);
})();

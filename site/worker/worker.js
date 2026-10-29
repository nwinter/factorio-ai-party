// Player of Games live API (Cloudflare Worker + one Durable Object). Contract: docs/LIVE-API.md.
//
//   GET  /v1/state            latest stream state pushed from the Mac (public)
//   POST /v1/state            replace it (Authorization: Bearer PUBLISH_TOKEN)
//   GET  /v1/board            every task, request, claim, project and reminder (public; the live page's full lists)
//   POST /v1/board            replace it (Authorization: Bearer PUBLISH_TOKEN; site/push_live.py, when it changed)
//   GET  /v1/chat?after=SEQ   viewer chat messages after SEQ (public); the ones that go to the game only, unless
//                             &channels=all (the live page): then the viewers-only ones too, each with its channel;
//                             &replies=1: the agents' and the Operator's replies to the lines returned (at any age), or
//                             with &replies_after=RV every one stored or changed since (batch309)
//   POST /v1/replies          {replies: [row]}: reply rows by game chat seq (Authorization: Bearer PUBLISH_TOKEN; push_live)
//   POST /v1/chat            post a message {name, text, cid?, channel?} (no accounts; rate limited per client; the
//                             same cid from the same client is stored once: a repeat returns the first message);
//                             channel "viewers": on the site only, never relayed to the agents (default "game")
//   POST /v1/mod              hide/unhide/ban/unban/open/close (Authorization: Bearer PUBLISH_TOKEN)
//   POST /v1/announce         {text, cid?}: one chat line as "Operator" on the viewers' channel (never relayed to the game),
//                             op: true in GET /v1/chat (Authorization: Bearer PUBLISH_TOKEN; tools/announce.py: shift changes
//                             and planned stops while the game is down; batch293, Nick d27 19:26)
//   POST /v1/here             {id}: an open live page, once a minute; GET /v1/state counts them as site_watching
//   POST /v1/blueprints       a viewer shares a blueprint {name, title, string, cid?} (closed unless mod bp_open): checked to decode to a blueprint
//                             or book, under chat's rules and limits (viewer LimeLight, d16 16:17)
//   GET  /v1/blueprints?after=ID, GET /v1/blueprints/ID   the shared ones, for the Mac (Authorization: PUBLISH_TOKEN)
//   GET  /v1/polls            open polls and the latest closed ones: counts, comments, time left (public)
//   POST /v1/polls/ID/vote    {option, name, comment?, cid?}: one vote per client per poll, a later one replaces it;
//                             with the publish token and {agent}: an agent's vote (./fh poll vote), voter agent:NAME
//   POST /v1/polls/suggest    a viewer's poll idea {name, question, options, hours?, cid?}: seen by the operator only
//   POST /v1/polls, POST /v1/polls/ID/close, GET /v1/polls/ID/voters, GET /v1/polls/suggestions?after=ID
//                             the operator's (Authorization: PUBLISH_TOKEN): create, close early, the voter log, ideas
//   GET  /v1/debug            the start's error and the store's sizes (Authorization: Bearer PUBLISH_TOKEN; batch333)
//
// Everything is unlisted: every response carries X-Robots-Tag noindex and /robots.txt disallows all.
// Client addresses are never stored: rate limits and bans key on a salted hash.

const SCHEMA = 1;
const MAX_STATE_BYTES = 256 * 1024;
// (d29 batch333) the state and board documents' rows: every value this object stores stays well under the size that
// failed with SQLITE_NOMEM (on the main object on d29, a 128 KB value failed and 16-64 KB passed)
const DOC = { chunk: 16 * 1024 };
const CHAT = {
  maxLen: 500,          // characters per message (d27 batch263 VR, Nick 06:30: 200 before, so long messages came in parts)
  minGapS: 4,           // per client: seconds between messages
  perMinute: 8,         // per client
  globalPerMinute: 60,  // all clients together
  keep: 2000,           // messages kept
  pageMax: 100,
};
// (d28 batch309, viewer Aurora 09:38: "Could viewer chat retain replies as long as their prompts remain, across shifts
// and reloads?") The agents' and the Operator's replies to viewers (push_live.py from the stream service's kept rows),
// one per game chat seq: GET /v1/chat?replies=1 returns the ones for the lines it returns, at any age.
const REPLIES = {
  postMax: 200,          // rows per POST /v1/replies
  rowBytes: 8 * 1024,    // one row's JSON
  keep: 5000,            // rows kept (the oldest dropped; a shift has 25-100)
  readMax: 500,          // rows in one GET (the newest)
  skewS: 60,             // a reply's time is the stream service's clock: lines this much older than a reply still count
};
// Site viewers: each open live page posts a random id (made per page load, never stored) once a minute. A page seen in
// the last `windowS` counts; at most `perClient` pages per client address, so one script can't inflate it. Kept in
// memory only: a restart of the object starts the count again within a minute.
const HERE = { windowS: 150, perClient: 4, maxIds: 20000 };
// Viewers' blueprint strings (LimeLight's are 2-200 KB). The Mac pulls them into the shift's team-tools; nothing goes
// into the game by itself. Each post counts against chat's limits too; these caps keep the storage small.
const BP = {
  maxString: 1024 * 1024,       // characters of the blueprint string
  maxJson: 16 * 1024 * 1024,    // bytes once inflated (a small string can inflate a lot)
  maxTitle: 80,
  perClientHour: 6,
  globalHour: 40,
  keep: 300,                    // blueprints kept
  keepBytes: 64 * 1024 * 1024,  // and at most this many string bytes
  pageMax: 20,
};
// Reserved names (Nick 17:11 on d16: "a host link so I can have verified comments and disallow similar nicks"). The
// same rule as tools/stream/names.py (the relay), with the same tables; tools/stream/test_names.py runs both on one set
// of names. normalizeName: zero-width characters out, Cyrillic/Greek look-alikes to Latin, compatibility forms and
// accents folded, lower case, leetspeak (0 o, 1 l | i, 3 e, 4 @ a, 5 $ s, 7 t), only a-z kept.
const ZERO_WIDTH = new Set([0xad,0x34f,0x61c,0x115f,0x1160,0x17b4,0x17b5,0x180e,0x200b,0x200c,0x200d,0x200e,0x200f,0x202a,0x202b,0x202c,0x202d,0x202e,0x2060,0x2061,0x2062,0x2063,0x2064,0x2066,0x2067,0x2068,0x2069,0x3164,0xfe0f,0xfeff,0xffa0]);
const HOMOGLYPHS = {"А": "a", "В": "b", "Е": "e", "Ё": "e", "К": "k", "М": "m", "Н": "h", "О": "o", "Р": "p", "С": "c", "Т": "t", "Х": "x", "У": "y", "І": "i", "Ї": "i", "Ј": "j", "Ѕ": "s", "Ԁ": "d", "Ԛ": "q", "Ԝ": "w", "Ү": "y", "Һ": "h", "а": "a", "в": "b", "е": "e", "ё": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c", "т": "t", "х": "x", "у": "y", "і": "i", "ї": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "ԛ": "q", "ԝ": "w", "ү": "y", "һ": "h", "ɡ": "g", "ո": "n", "ս": "u", "ⅰ": "i", "Α": "a", "Β": "b", "Ε": "e", "Ζ": "z", "Η": "h", "Ι": "i", "Κ": "k", "Μ": "m", "Ν": "n", "Ο": "o", "Ρ": "p", "Τ": "t", "Υ": "y", "Χ": "x", "α": "a", "β": "b", "ε": "e", "η": "n", "ι": "i", "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "χ": "x", "ω": "w", "ϲ": "c", "ϳ": "j"};
const LEET = {"0": "o", "1": "i", "l": "i", "|": "i", "3": "e", "4": "a", "@": "a", "5": "s", "$": "s", "7": "t"};
const RESERVED_CONTAINS = ["nickwinter", "nickw"];
const RESERVED_EXACT = ["nick", "winter", "astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse", "fable", "server", "operator", "mod", "moderator", "admin", "caster", "system", "playerofgames", "pog"];
const RESERVED_NEAR = ["nickwinter", "operator"];
// (d22 batch75 AK12, viewer Aurora site:4296: "The site defaults blank names to viewer, but the relay rejects viewer as
// impersonation:name. Please align the name rules") the relay's own reserved words (tools/stream/viewers.py RESERVED,
// matched there on the name folded, spaces out): refused here too, so a name the relay would drop is turned back when
// it is posted, never relayed to nobody. site/worker/test_api.py checks the two lists are the same.
export const RELAY_RESERVED = ["operator", "op", "mod", "moderator", "admin", "caster", "host", "hosts", "system", "server", "narrator",
  "announcer", "director", "harness", "board", "team", "viewer", "viewers", "agent", "agents", "nick"];
const RELAY_N = new Set(RELAY_RESERVED);
// A blank name's default: "Guest" and four hex digits of the poster's salted client hash (who), the same for a poster
// each time, different between posters, and a name the relay takes (it was "viewer", which the relay drops).
export function guestName(who) { return "Guest " + String(who || "0000").slice(0, 4); }
export function normalizeName(name) {
  let s = [...String(name == null ? "" : name)].filter((c) => !ZERO_WIDTH.has(c.codePointAt(0))).join("");
  s = [...s].map((c) => HOMOGLYPHS[c] || c).join("");
  s = s.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  s = [...s].map((c) => HOMOGLYPHS[c] || LEET[c] || c).join("");
  return s.replace(/[^a-z]/g, "");
}
// (AK12) a name as the relay folds it for its reserved words (viewers.py fold: NFKD, accents and case dropped, its
// leetspeak table undone), spaces out
const RELAY_LEET = {"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s"};
export function relayFold(name) {
  const s = String(name == null ? "" : name).normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  return [...s].map((c) => RELAY_LEET[c] || c).join("").replace(/\s+/g, "");
}
function distance(a, b, cap = 3) {
  if (Math.abs(a.length - b.length) >= cap) return cap;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)));
    if (Math.min(...cur) >= cap) return cap;
    prev = cur;
  }
  return Math.min(prev[b.length], cap);
}
const EXACT_N = new Map(RESERVED_EXACT.map((w) => [normalizeName(w), w]));
// Why a name is reserved ("contains nickwinter", "is sol", "near operator"), or null.
export function reservedName(name) {
  const n = normalizeName(name);
  if (!n) return null;
  for (const w of RESERVED_CONTAINS) if (n.includes(w)) return "contains " + w;
  if (EXACT_N.has(n)) return "is " + EXACT_N.get(n);
  for (const w of RESERVED_NEAR) if (distance(n, w) <= 2) return "near " + w;
  return null;
}
// The Operator's announcements (batch293): a cap against a runaway script; the same cid again is the first line.
const ANNOUNCE = { name: "Operator", perHour: 20 };
// The host link (Nick, 17:11): the page sends HOST_TOKEN (a Worker secret) as X-Host-Token with each chat post; a match
// posts as the host, a wrong one is refused.
const HOST = { name: "NickWinter", perMinute: 30 };
// Polls (Nick, d16 17:15): the operator opens them; viewers vote on the site, one vote per client (the same salted
// address hash as chat's limits and bans), and may leave a comment under chat's text rules.
const POLL = {
  maxQuestion: 200,
  maxOption: 100,
  maxIntro: 800,       // the poll's intro under the question (viewer LimeLight's idea)
  maxDetails: 600,     // each option's details: benefits and consequences
  minOptions: 2,
  maxOptions: 6,
  maxComment: 200,
  maxHours: 72,
  maxOpen: 4,          // open at once
  closedShown: 20,     // closed polls in GET /v1/polls
  commentsShown: 100,  // newest comments per poll
  suggestPerClientHour: 3,
  suggestKeep: 500,
};

const BASE_HEADERS = {
  "X-Robots-Tag": "noindex, nofollow",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...BASE_HEADERS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
  });
}

function originAllowed(origin, env) {
  if (!origin) return false;
  return (env.ALLOWED_ORIGINS || "").split(",").map((s) => s.trim()).filter(Boolean).some((rule) => {
    if (rule === origin) return true;
    const m = /^(https?:\/\/)\*\.(.+)$/.exec(rule);
    return !!m && origin.startsWith(m[1]) && origin.endsWith("." + m[2]) && !origin.slice(m[1].length).includes("/");
  });
}

function withCors(resp, req, env) {
  const origin = req.headers.get("Origin");
  if (!originAllowed(origin, env)) return resp;
  const r = new Response(resp.body, resp);
  r.headers.set("Access-Control-Allow-Origin", origin);
  r.headers.set("Vary", "Origin");
  return r;
}

// Per-isolate micro-cache for the two public GETs, so many viewers polling don't each wake the Durable Object.
// (The Cache API is not available on workers.dev.)
const micro = new Map();
const MICRO_TTL = { "/v1/state": 3000, "/v1/chat": 2000, "/v1/polls": 3000, "/v1/board": 10000 };
const PUBLIC_POST = /^\/v1\/(chat|here|blueprints|polls\/\d+\/vote|polls\/suggest)$/;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname;

    if (req.method === "OPTIONS") {
      const origin = req.headers.get("Origin");
      if (!originAllowed(origin, env)) return new Response(null, { status: 403, headers: BASE_HEADERS });
      return new Response(null, {
        status: 204,
        headers: {
          ...BASE_HEADERS,
          "Access-Control-Allow-Origin": origin,
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, X-Host-Token",
          "Access-Control-Max-Age": "86400",
          Vary: "Origin",
        },
      });
    }
    if (path === "/robots.txt") {
      return new Response("User-agent: *\nDisallow: /\n", { headers: { ...BASE_HEADERS, "Content-Type": "text/plain" } });
    }
    if (path === "/" || path === "/v1" || path === "/v1/") {
      return json({ name: "player-of-games live API", schema: SCHEMA, docs: "docs/LIVE-API.md in the repo" });
    }
    if (!path.startsWith("/v1/")) return json({ error: "not found" }, 404);

    // Browsers may only post chat from the site's own origins; scripts (no Origin header) are rate limited the same.
    const origin = req.headers.get("Origin");
    if (req.method === "POST" && PUBLIC_POST.test(path) && origin && !originAllowed(origin, env)) {
      await req.arrayBuffer();
      return json({ error: "origin not allowed" }, 403);
    }

    const ttl = req.method === "GET" ? MICRO_TTL[path] : 0;
    const key = path + url.search;
    if (ttl) {
      const hit = micro.get(key);
      if (hit && Date.now() - hit.at < ttl) return withCors(json(hit.body, 200), req, env);
    }

    const stub = env.LIVE.get(env.LIVE.idFromName("main"));
    const fwd = new Request(req);
    fwd.headers.set("x-client-ip", req.headers.get("CF-Connecting-IP") || "");
    const resp = await stub.fetch(fwd);
    if (ttl && resp.status === 200) {
      const body = await resp.json();
      if (micro.size > 500) micro.clear();
      micro.set(key, { at: Date.now(), body });
      return withCors(json(body, 200), req, env);
    }
    if (req.method === "POST" && (path === "/v1/chat" || path === "/v1/announce" || path === "/v1/replies")) for (const k of micro.keys()) if (k.startsWith("/v1/chat")) micro.delete(k);
    if (req.method === "POST" && path.startsWith("/v1/polls")) for (const k of micro.keys()) if (k.startsWith("/v1/polls")) micro.delete(k);
    return withCors(resp, req, env);
  },
};

// (d28 batch309) a reply row with the lines in `gone` (site seqs the site hides) left out of answers and also, and their
// viewers' names out of `to` (push_live.public_replies does the same when it sends them)
function hideAnswers(r, gone) {
  const hid = (a) => a && gone.has(+((/^site:(\d+)$/.exec(String(a.id || "")) || [])[1]));
  const names = [r.answers, ...(r.also || [])].filter(hid).map((a) => String(a.name || "").toLowerCase());
  if (!names.length) return r;
  const out = { ...r, to: (r.to || []).filter((n) => !names.includes(String(n).toLowerCase())) };
  if (hid(r.answers)) delete out.answers;
  if (Array.isArray(r.also)) out.also = r.also.filter((a) => !hid(a));
  return out;
}

function sameSecret(want, got) {
  want = String(want || "");
  got = String(got || "");
  if (want.length < 16 || got.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ got.charCodeAt(i);
  return diff === 0;
}

function tokenOk(req, env) {
  return sameSecret(env.PUBLISH_TOKEN, (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, ""));
}

// The host's chat posts: X-Host-Token against the HOST_TOKEN secret, in constant time like tokenOk.
function hostOk(req, env) {
  return sameSecret(env.HOST_TOKEN, req.headers.get("X-Host-Token"));
}

// Strip control, bidi-override and zero-width characters; collapse whitespace.
function tidy(s) {
  return String(s == null ? "" : s)
    .normalize("NFC")
    .replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁩﻿]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
// A blueprint string: "0" (the version byte) + base64 of zlib-deflated JSON. -> {ok, kind, label, blueprints,
// entities, version} or {error}. Inflates through a stream and stops past BP.maxJson.
async function decodeBlueprint(str) {
  const s = String(str || "").trim();
  if (!s) return { error: "blueprint string missing" };
  if (s.length > BP.maxString) return { error: `blueprint strings are at most ${BP.maxString} characters` };
  if (s[0] !== "0") return { error: "not a blueprint string (it starts with the version 0)" };
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(s.slice(1)) || (s.length - 1) % 4 !== 0) return { error: "not a blueprint string (bad base64)" };
  let bytes;
  try {
    const bin = atob(s.slice(1));
    bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  } catch (e) { return { error: "not a blueprint string (bad base64)" }; }
  let text;
  try {
    const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate")).getReader();
    const parts = [];
    let n = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      n += value.length;
      if (n > BP.maxJson) { await reader.cancel(); return { error: "blueprint too large once decoded" }; }
      parts.push(value);
    }
    const all = new Uint8Array(n);
    let o = 0;
    for (const p of parts) { all.set(p, o); o += p.length; }
    text = new TextDecoder("utf-8", { fatal: true }).decode(all);
  } catch (e) { return { error: "not a blueprint string (it does not inflate)" }; }
  let j;
  try { j = JSON.parse(text); } catch (e) { return { error: "not a blueprint string (no JSON inside)" }; }
  if (!j || typeof j !== "object" || Array.isArray(j)) return { error: "not a blueprint string (no JSON object inside)" };
  const count = (bp) => (bp && Array.isArray(bp.entities) ? bp.entities.length : 0);
  if (j.blueprint && typeof j.blueprint === "object") {
    return { ok: true, kind: "blueprint", label: tidy(j.blueprint.label).slice(0, 80), blueprints: 1, entities: count(j.blueprint),
      version: j.blueprint.version ?? null };
  }
  if (j.blueprint_book && typeof j.blueprint_book === "object") {
    let blueprints = 0, entities = 0, depth = 0;
    const walk = (book) => {
      if (++depth > 8) return;
      for (const e of Array.isArray(book.blueprints) ? book.blueprints : []) {
        if (e && e.blueprint) { blueprints++; entities += count(e.blueprint); }
        else if (e && e.blueprint_book) walk(e.blueprint_book);
      }
      depth--;
    };
    walk(j.blueprint_book);
    return { ok: true, kind: "blueprint_book", label: tidy(j.blueprint_book.label).slice(0, 80), blueprints, entities,
      version: j.blueprint_book.version ?? null };
  }
  return { error: "not a blueprint or blueprint book (an upgrade or deconstruction planner, or something else)" };
}

const LINK = /(https?:\/\/|www\.|\b[a-z0-9-]{2,}\.(com|net|org|io|gg|ly|xyz|ru|tv|me|co|app|dev|link|site)\b)/i;

export class Live {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.sql = ctx.storage.sql;
    this.recent = new Map(); // who -> [ms timestamps]
    this.global = [];
    this.lastText = new Map(); // who -> {text, at}
    this.here = new Map(); // page id -> {at, who}
    this.hostTimes = [];
    this.ideaTimes = new Map(); // who -> [ms] suggestions in the last hour
    this.bpTimes = new Map(); // who -> [ms] blueprint posts in the last hour
    // (d29 batch333) a failing start (SQLITE_NOMEM from 01:40) no longer throws out of the constructor, which reset the
    // object on every request: the error is kept, each request tries again, GET /v1/debug reports it
    this.ready = false;
    this.initError = null;
    ctx.blockConcurrencyWhile(async () => this.start());
  }
  start() {
    try {
      this.init();
      this.ready = true;
      this.initError = null;
    } catch (e) {
      this.initError = String((e && e.message) || e);
    }
    return this.ready;
  }
  init() {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS chat (seq INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL,
      name TEXT NOT NULL, text TEXT NOT NULL, who TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)`);
    // cid: the page's id for one message (joonazan, d15 08:05: messages sent twice); a table from before it gains it
    try { this.sql.exec(`ALTER TABLE chat ADD COLUMN cid TEXT`); } catch (e) { /* already there */ }
    this.sql.exec(`CREATE INDEX IF NOT EXISTS chat_cid ON chat (cid)`);
    // channel (viewer LimeLight555, d16 10:36): "viewers" lines stay on the site; GET /v1/chat leaves them out unless
    // asked (channels=all), so the Mac's relay to the game never reads them
    try { this.sql.exec(`ALTER TABLE chat ADD COLUMN channel TEXT NOT NULL DEFAULT 'game'`); } catch (e) { /* already there */ }
    // host: a line posted with the host link (Nick, d16 17:11)
    try { this.sql.exec(`ALTER TABLE chat ADD COLUMN host INTEGER NOT NULL DEFAULT 0`); } catch (e) { /* already there */ }
    // op: the Operator's announcement (POST /v1/announce, batch293)
    try { this.sql.exec(`ALTER TABLE chat ADD COLUMN op INTEGER NOT NULL DEFAULT 0`); } catch (e) { /* already there */ }
    // (d28 batch309) replies: seq = the game chat line's seq; prompt = the site line it answers (site:N), if any; rv =
    // the store's version when it last changed (GET /v1/chat?replies_after=rv)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS replies (seq INTEGER PRIMARY KEY, t REAL NOT NULL, prompt INTEGER,
      rv INTEGER NOT NULL, row TEXT NOT NULL)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS replies_rv ON replies (rv)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS replies_t ON replies (t)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS replies_prompt ON replies (prompt)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
    // (d29 batch333) the state and board documents, DOC.chunk characters a row (kv's one 230 KB "state" row failed every
    // read and write with SQLITE_NOMEM from d29 01:40; nothing reads kv's "state" and "board" rows now)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS docs (k TEXT NOT NULL, i INTEGER NOT NULL, v TEXT NOT NULL, PRIMARY KEY (k, i))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS bans (who TEXT PRIMARY KEY, t REAL NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS blueprints (id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL,
      name TEXT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, label TEXT NOT NULL, blueprints INTEGER NOT NULL,
      entities INTEGER NOT NULL, bytes INTEGER NOT NULL, string TEXT NOT NULL, who TEXT NOT NULL, cid TEXT,
      hidden INTEGER NOT NULL DEFAULT 0)`);
    // polls: status "open" until closes (or the operator closes it early: status "closed", closes = then)
    // options: a JSON list of labels; details: a JSON list of each option's details ("" for none)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS polls (id INTEGER PRIMARY KEY AUTOINCREMENT, question TEXT NOT NULL,
      options TEXT NOT NULL, opens REAL NOT NULL, closes REAL NOT NULL, created_by TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'open', intro TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '[]')`);
    // every vote is kept; current = 1 on each voter's latest one (the one that counts)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS votes (id INTEGER PRIMARY KEY AUTOINCREMENT, poll INTEGER NOT NULL,
      voter TEXT NOT NULL, name TEXT NOT NULL, option INTEGER NOT NULL, comment TEXT NOT NULL DEFAULT '', t REAL NOT NULL,
      cid TEXT, current INTEGER NOT NULL DEFAULT 1, hidden INTEGER NOT NULL DEFAULT 0, agent INTEGER NOT NULL DEFAULT 0)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS votes_poll ON votes (poll, current)`);
    try { this.sql.exec(`ALTER TABLE votes ADD COLUMN voided INTEGER NOT NULL DEFAULT 0`); } catch (e) { /* already there */ }
    // host: a vote cast with the host link (shown as the host's on the comments)
    try { this.sql.exec(`ALTER TABLE votes ADD COLUMN host INTEGER NOT NULL DEFAULT 0`); } catch (e) { /* already there */ }
    this.sql.exec(`CREATE TABLE IF NOT EXISTS poll_ideas (id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL,
      name TEXT NOT NULL, question TEXT NOT NULL, options TEXT NOT NULL, hours REAL, who TEXT NOT NULL, cid TEXT,
      intro TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '[]')`);
    this.state = this.getDoc("state");
    this.received = this.state ? Number(this.get("received") || 0) : 0;
    this.board = this.getDoc("board");
    this.boardReceived = this.board ? Number(this.get("board_received") || 0) : 0;
    this.salt = this.get("salt");
    if (!this.salt) {
      const b = crypto.getRandomValues(new Uint8Array(16));
      this.salt = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
      this.put("salt", this.salt);
    }
  }
  get(k) {
    const r = this.sql.exec("SELECT v FROM kv WHERE k = ?", k).toArray();
    return r.length ? r[0].v : null;
  }
  put(k, v) {
    this.sql.exec("INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, String(v));
  }
  getDoc(k) {
    const rows = this.sql.exec("SELECT v FROM docs WHERE k = ? ORDER BY i", k).toArray();
    return rows.length ? rows.map((r) => r.v).join("") : null;
  }
  // a document in rows of at most DOC.chunk characters (a cut never splits a surrogate pair), its old extra rows dropped
  putDoc(k, v) {
    let i = 0;
    for (let at = 0; at < v.length || i === 0; i++) {
      let end = Math.min(v.length, at + DOC.chunk);
      const c = v.charCodeAt(end - 1);
      if (end < v.length && c >= 0xd800 && c <= 0xdbff) end--;
      this.sql.exec("INSERT INTO docs (k, i, v) VALUES (?, ?, ?) ON CONFLICT(k, i) DO UPDATE SET v = excluded.v", k, i, v.slice(at, end));
      at = end;
    }
    this.sql.exec("DELETE FROM docs WHERE k = ? AND i >= ?", k, i);
  }
  async who(req) {
    const data = new TextEncoder().encode(this.salt + "|" + (req.headers.get("x-client-ip") || "unknown"));
    const h = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
    return [...h.slice(0, 8)].map((x) => x.toString(16).padStart(2, "0")).join("");
  }

  async fetch(req) {
    const url = new URL(req.url);
    const route = req.method + " " + url.pathname;
    try {
      // Read the body before any early return: answering first and leaving the body unread breaks the response.
      const text = req.method === "POST" ? await req.text() : "";
      if (route === "GET /v1/debug") return this.debug(req);
      if (!this.ready && !this.start()) return json({ error: "storage unavailable", detail: this.initError }, 503);
      switch (route) {
        case "GET /v1/state": return this.getState();
        case "POST /v1/state": return this.postState(req, text);
        case "GET /v1/board": return this.getBoard();
        case "POST /v1/board": return this.postBoard(req, text);
        case "POST /v1/replies": return this.postReplies(req, text);
        case "GET /v1/chat": return this.getChat(url);
        case "POST /v1/chat": return await this.postChat(req, text);
        case "POST /v1/announce": return this.announce(req, text);
        case "POST /v1/mod": return this.mod(req, text);
        case "POST /v1/here": return await this.postHere(req, text);
        case "POST /v1/blueprints": return await this.postBlueprint(req, text);
        case "GET /v1/blueprints": return this.listBlueprints(req, url);
        case "GET /v1/polls": return this.getPolls();
        case "POST /v1/polls": return this.createPoll(req, text);
        case "POST /v1/polls/suggest": return await this.suggestPoll(req, text);
        case "GET /v1/polls/suggestions": return this.listIdeas(req, url);
        default: {
          if (req.method === "GET" && /^\/v1\/blueprints\/\d+$/.test(url.pathname)) return this.getBlueprint(req, url);
          const m = /^\/v1\/polls\/(\d+)\/(vote|close|voters)$/.exec(url.pathname);
          if (m && req.method === "POST" && m[2] === "vote") return await this.vote(req, text, parseInt(m[1], 10));
          if (m && req.method === "POST" && m[2] === "close") return this.closePoll(req, parseInt(m[1], 10));
          if (m && req.method === "GET" && m[2] === "voters") return this.voters(req, parseInt(m[1], 10));
          return json({ error: "not found" }, 404);
        }
      }
    } catch (e) {
      // (d29 batch333) a storage error is the object's, not the request's: 503, and in wrangler tail
      const msg = String((e && e.message) || e);
      if (/SQLITE_|internal error/.test(msg)) {
        console.error(route, msg);
        return json({ error: "storage unavailable", detail: msg }, 503);
      }
      return json({ error: "bad request" }, 400);
    }
  }

  // (d29 batch333) GET /v1/debug (Authorization: Bearer PUBLISH_TOKEN): the start's error and the store's sizes, each
  // read on its own so one failing read leaves the others
  debug(req) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const out = { ready: this.ready, init_error: this.initError, reads: {} };
    const read = (k, f) => { try { out.reads[k] = f(); } catch (e) { out.reads[k] = { error: String((e && e.message) || e) }; } };
    const one = (q) => this.sql.exec(q).toArray();
    read("database_size", () => this.ctx.storage.sql.databaseSize);
    read("tables", () => one("SELECT name, type FROM sqlite_master ORDER BY name"));
    read("page_size", () => one("PRAGMA page_size"));
    read("kv", () => one("SELECT k FROM kv ORDER BY k"));
    read("docs", () => one("SELECT k, COUNT(*) AS rows, SUM(length(v)) AS chars, MAX(length(v)) AS longest FROM docs GROUP BY k ORDER BY k"));
    read("chat", () => one("SELECT COUNT(*) AS n, MIN(seq) AS lo, MAX(seq) AS hi, SUM(length(text)) AS bytes FROM chat"));
    read("replies", () => one("SELECT COUNT(*) AS n, MIN(rv) AS lo, MAX(rv) AS hi, SUM(length(row)) AS bytes FROM replies"));
    read("blueprints", () => one("SELECT COUNT(*) AS n, SUM(bytes) AS bytes, MAX(bytes) AS longest FROM blueprints"));
    read("votes", () => one("SELECT COUNT(*) AS n, SUM(length(comment)) AS bytes FROM votes"));
    read("polls", () => one("SELECT COUNT(*) AS n FROM polls"));
    read("poll_ideas", () => one("SELECT COUNT(*) AS n FROM poll_ideas"));
    read("bans", () => one("SELECT COUNT(*) AS n FROM bans"));
    read("here", () => this.here.size);
    return json(out);
  }

  getState() {
    const now = Date.now() / 1000;
    return json({
      schema: SCHEMA,
      received: this.received || null,
      age_s: this.received ? Math.round(now - this.received) : null,
      state: this.state ? JSON.parse(this.state) : null,
      site_watching: this.siteWatching(),
    });
  }

  // Live pages open on the site now (HERE).
  siteWatching() {
    const now = Date.now(), per = new Map();
    for (const [id, h] of this.here) {
      if (now - h.at > HERE.windowS * 1000) { this.here.delete(id); continue; }
      per.set(h.who, Math.min(HERE.perClient, (per.get(h.who) || 0) + 1));
    }
    let n = 0;
    for (const c of per.values()) n += c;
    return n;
  }

  async postHere(req, text) {
    if (text.length > 256) return json({ error: "too large" }, 413);
    const id = String(JSON.parse(text || "{}").id || "");
    if (!/^[0-9a-f]{16,32}$/.test(id)) return json({ error: "id must be 16-32 hex digits" }, 400);
    if (this.here.size >= HERE.maxIds && !this.here.has(id)) this.siteWatching();
    if (this.here.size >= HERE.maxIds && !this.here.has(id)) return json({ ok: false }, 503);
    this.here.set(id, { at: Date.now(), who: await this.who(req) });
    return json({ ok: true });
  }

  postState(req, text) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    if (text.length > MAX_STATE_BYTES) return json({ error: "state too large", max_bytes: MAX_STATE_BYTES }, 413);
    const body = JSON.parse(text);
    if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "state must be an object" }, 400);
    this.state = JSON.stringify(body);
    this.received = Date.now() / 1000;
    this.putDoc("state", this.state);
    this.put("received", this.received);
    return json({ ok: true, received: this.received });
  }

  // (d22 batch99 BI3, viewer Aurora site:4316) the full board document: every task, request, claim, project and
  // reminder, pushed apart from the state (which keeps its first view) and read by the page when a full list opens.
  getBoard() {
    const now = Date.now() / 1000;
    return json({
      schema: SCHEMA,
      received: this.boardReceived || null,
      age_s: this.boardReceived ? Math.round(now - this.boardReceived) : null,
      board: this.board ? JSON.parse(this.board) : null,
    });
  }

  postBoard(req, text) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    if (text.length > MAX_STATE_BYTES) return json({ error: "board too large", max_bytes: MAX_STATE_BYTES }, 413);
    const body = JSON.parse(text);
    if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "board must be an object" }, 400);
    this.board = JSON.stringify(body);
    this.boardReceived = Date.now() / 1000;
    this.putDoc("board", this.board);
    this.put("board_received", this.boardReceived);
    return json({ ok: true, received: this.boardReceived });
  }

  getChat(url) {
    const limit = Math.max(1, Math.min(CHAT.pageMax, parseInt(url.searchParams.get("limit") || "50", 10) || 50));
    const after = parseInt(url.searchParams.get("after") || "", 10);
    const all = url.searchParams.get("channels") === "all";
    const cols = all ? "seq, t, name, text, channel, host, op" : "seq, t, name, text, host, op";
    const only = all ? "" : " AND channel = 'game'";
    let rows;
    if (Number.isFinite(after)) {
      rows = this.sql.exec(`SELECT ${cols} FROM chat WHERE seq > ? AND hidden = 0${only} ORDER BY seq LIMIT ?`,
        after, limit).toArray();
    } else {
      rows = this.sql.exec(`SELECT ${cols} FROM chat WHERE hidden = 0${only} ORDER BY seq DESC LIMIT ?`, limit)
        .toArray().reverse();
    }
    // host: true on a line posted with the host link, op: true on the Operator's announcement; absent on the rest
    rows = rows.map(({ host, op, ...r }) => ({ ...r, ...(host ? { host: true } : {}), ...(op ? { op: true } : {}) }));
    const maxRow = this.sql.exec("SELECT COALESCE(MAX(seq), 0) AS m FROM chat").toArray()[0];
    const hidden = this.sql.exec("SELECT seq FROM chat WHERE hidden = 1 ORDER BY seq DESC LIMIT 200").toArray().map((r) => r.seq);
    const out = {
      schema: SCHEMA,
      open: this.get("chat_open") !== "0",
      messages: rows,
      last_seq: maxRow.m,
      hidden,
      limits: { max_len: CHAT.maxLen, min_gap_s: CHAT.minGapS, per_minute: CHAT.perMinute },
    };
    if (url.searchParams.get("replies") === "1") Object.assign(out, this.replies(url, rows));
    return json(out);
  }

  // (d28 batch309) GET /v1/chat?replies=1: with replies_after=RV, the replies stored or changed since (the page's polls),
  // the first readMax of them, replies_rv the version they reach (the next poll takes the rest); without, the replies to
  // the lines returned: each one that names one of them (site:N) or came after the oldest, the newest readMax, and
  // replies_rv the store's version. Oldest first.
  replies(url, lines) {
    const after = parseInt(url.searchParams.get("replies_after") || "", 10);
    let got = [], rv = this.sql.exec("SELECT COALESCE(MAX(rv), 0) AS m FROM replies").toArray()[0].m;
    if (Number.isFinite(after)) {
      got = this.sql.exec("SELECT rv, row FROM replies WHERE rv > ? ORDER BY rv LIMIT ?", after, REPLIES.readMax).toArray();
      if (got.length === REPLIES.readMax) rv = got[got.length - 1].rv;
    } else if (lines.length) {
      const lo = lines[0].seq, hi = lines[lines.length - 1].seq;
      const t0 = Math.min(...lines.map((m) => m.t)) - REPLIES.skewS;
      got = this.sql.exec("SELECT row FROM replies WHERE t >= ? OR prompt BETWEEN ? AND ? ORDER BY t DESC LIMIT ?",
        t0, lo, hi, REPLIES.readMax).toArray();
    }
    let rows = got.map((r) => JSON.parse(r.row)).sort((a, b) => a.t - b.t || a.seq - b.seq);
    // a line the site hides since: its words and its viewer's name left out of the replies to it (push_live does the same)
    const ids = rows.flatMap((r) => [r.answers, ...(r.also || [])]).map((a) => /^site:(\d+)$/.exec(String((a && a.id) || ""))).filter(Boolean).map((m) => +m[1]);
    if (ids.length) {
      const gone = new Set(this.sql.exec("SELECT seq FROM chat WHERE hidden = 1 AND seq BETWEEN ? AND ?", Math.min(...ids), Math.max(...ids))
        .toArray().map((r) => r.seq));
      if (gone.size) rows = rows.map((r) => hideAnswers(r, gone));
    }
    return { replies: rows, replies_rv: rv };
  }

  // (d28 batch309) POST /v1/replies {replies: [row]}: push_live's public reply rows (push_live.public_replies), each
  // stored by its game seq; a row sent again unchanged is left as it is (its rv too).
  postReplies(req, text) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    if (text.length > MAX_STATE_BYTES) return json({ error: "replies too large", max_bytes: MAX_STATE_BYTES }, 413);
    const body = JSON.parse(text);
    const list = body && Array.isArray(body.replies) ? body.replies : null;
    if (!list || list.length > REPLIES.postMax) return json({ error: `replies must be a list of at most ${REPLIES.postMax}` }, 400);
    let rv = this.sql.exec("SELECT COALESCE(MAX(rv), 0) AS m FROM replies").toArray()[0].m;
    let stored = 0, same = 0, refused = 0;
    for (const r of list) {
      const row = r && typeof r === "object" && !Array.isArray(r) ? JSON.stringify(r) : "";
      if (!row || row.length > REPLIES.rowBytes || !Number.isSafeInteger(r.seq) || r.seq < 0 || !Number.isFinite(r.t)
          || typeof r.by !== "string" || typeof r.text !== "string" || !r.text) { refused++; continue; }
      const old = this.sql.exec("SELECT row FROM replies WHERE seq = ?", r.seq).toArray();
      if (old.length && old[0].row === row) { same++; continue; }
      const m = /^site:(\d+)$/.exec(String((r.answers && r.answers.id) || ""));
      this.sql.exec(`INSERT INTO replies (seq, t, prompt, rv, row) VALUES (?, ?, ?, ?, ?) ON CONFLICT(seq) DO UPDATE SET
        t = excluded.t, prompt = excluded.prompt, rv = excluded.rv, row = excluded.row`, r.seq, r.t, m ? +m[1] : null, ++rv, row);
      stored++;
    }
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM replies").toArray()[0].n;
    if (n > REPLIES.keep) {
      this.sql.exec("DELETE FROM replies WHERE seq IN (SELECT seq FROM replies ORDER BY t ASC LIMIT ?)", n - REPLIES.keep);
    }
    return json({ ok: true, stored, same, refused, rv });
  }

  async postChat(req, text) {
    if (this.get("chat_open") === "0") return json({ error: "chat is closed" }, 403);
    if (text.length > 4096) return json({ error: "too large" }, 413);
    const body = JSON.parse(text || "{}");
    const who = await this.who(req);
    // The host link: a token that does not match is refused, never posted as a viewer's line
    const hostIs = this.hostOf(req);
    if (hostIs.error) return json(hostIs, 403);
    const host = hostIs.host;
    if (!host && this.sql.exec("SELECT 1 FROM bans WHERE who = ?", who).toArray().length) {
      return json({ error: "you can't post right now" }, 403);
    }
    // The same message again (a second press, a retry after a slow reply): the first one, before any limit.
    const cid = body.cid == null ? null : String(body.cid);
    if (cid !== null && !/^[0-9a-f]{16,32}$/.test(cid)) return json({ error: "cid must be 16-32 hex digits" }, 400);
    const channel = body.channel == null ? "game" : String(body.channel);
    if (channel !== "game" && channel !== "viewers") return json({ error: "channel must be game or viewers" }, 400);
    if (cid) {
      const had = this.sql.exec("SELECT seq, t, name, text, channel, host FROM chat WHERE cid = ? AND who = ?", cid, who).toArray();
      if (had.length) {
        const { host: h, ...m } = had[0];
        return json({ ok: true, repeat: true, message: h ? { ...m, host: true } : m });
      }
    }
    const msg = tidy(body.text);
    if (!msg) return json({ error: "empty message" }, 400);
    if ([...msg].length > CHAT.maxLen) return json({ error: `messages are at most ${CHAT.maxLen} characters` }, 400);
    if (LINK.test(msg)) return json({ error: "links are not allowed" }, 400);
    const now = Date.now();
    let name;
    if (host) {
      // the host's name whatever the box says; no per-client limits, a cap against a runaway page
      name = { name: HOST.name };
      const limited = this.hostLimit(now);
      if (limited) return limited;
    } else {
      name = this.viewerName(body.name, who);
      if (name.error) return json(name, 400);
      const limited = this.limit(who, now);
      if (limited) return limited;
      const last = this.lastText.get(who);
      if (last && last.text === msg.toLowerCase() && now - last.at < 120000) return json({ error: "duplicate message" }, 400);
      this.count(who, now);
      this.lastText.set(who, { text: msg.toLowerCase(), at: now });
      if (this.lastText.size > 5000) this.lastText.clear();
    }

    const t = now / 1000;
    const row = this.sql.exec("INSERT INTO chat (t, name, text, who, cid, channel, host) VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING seq",
      t, name.name, msg, who, cid, channel, host ? 1 : 0).toArray()[0];
    this.sql.exec("DELETE FROM chat WHERE seq <= ?", row.seq - CHAT.keep);
    const out = { seq: row.seq, t, name: name.name, text: msg, channel };
    if (host) out.host = true;
    return json(name.guest ? { ok: true, message: out, guest_name: name.name } : { ok: true, message: out });
  }

  // The Operator's line in the site chat (batch293): shift changes and planned stops, while the game (and so the
  // Operator's game-chat replies) is down. The viewers' channel, so the Mac's relay never takes it into the game.
  announce(req, text) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    if (text.length > 4096) return json({ error: "too large" }, 413);
    const body = JSON.parse(text || "{}");
    const cid = body.cid == null ? null : String(body.cid);
    if (cid !== null && !/^[0-9a-f]{16,32}$/.test(cid)) return json({ error: "cid must be 16-32 hex digits" }, 400);
    if (cid) {
      const had = this.sql.exec("SELECT seq, t, name, text, channel FROM chat WHERE cid = ? AND op = 1", cid).toArray();
      if (had.length) return json({ ok: true, repeat: true, message: { ...had[0], op: true } });
    }
    const msg = tidy(body.text);
    if (!msg) return json({ error: "empty message" }, 400);
    if ([...msg].length > CHAT.maxLen) return json({ error: `messages are at most ${CHAT.maxLen} characters` }, 400);
    if (LINK.test(msg)) return json({ error: "links are not allowed" }, 400);
    const t = Date.now() / 1000;
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM chat WHERE op = 1 AND t > ?", t - 3600).toArray()[0].n;
    if (n >= ANNOUNCE.perHour) return json({ error: `at most ${ANNOUNCE.perHour} announcements an hour` }, 429);
    const row = this.sql.exec("INSERT INTO chat (t, name, text, who, cid, channel, host, op) VALUES (?, ?, ?, ?, ?, 'viewers', 0, 1) RETURNING seq",
      t, ANNOUNCE.name, msg, "operator", cid).toArray()[0];
    this.sql.exec("DELETE FROM chat WHERE seq <= ?", row.seq - CHAT.keep);
    return json({ ok: true, message: { seq: row.seq, t, name: ANNOUNCE.name, text: msg, channel: "viewers", op: true } });
  }

  // The host link on a post (chat, a poll vote or idea): {host: true} for a matching X-Host-Token, {host: false} without
  // the header, {error} for one that does not match (refused, never taken as a viewer's).
  hostOf(req) {
    if (req.headers.get("X-Host-Token") == null) return { host: false };
    return hostOk(req, this.env) ? { host: true } : { error: "host link not valid" };
  }

  // The host's posts: no per-client limits, a cap of HOST.perMinute (chat, votes and ideas together).
  hostLimit(now) {
    this.hostTimes = this.hostTimes.filter((t) => now - t < 60000);
    if (this.hostTimes.length >= HOST.perMinute) return json({ error: "slow down", retry_after_s: 10 }, 429);
    this.hostTimes.push(now);
    return null;
  }

  // A viewer's name, as chat takes it: {name} or {error}; blank: guestName(who) (AK12).
  viewerName(raw, who) {
    const typed = tidy(raw).slice(0, 20);
    const name = typed || guestName(who);
    if (!/^[\p{L}\p{N} _.'-]{2,20}$/u.test(name)) return { error: "names are 2-20 letters, digits, spaces or _ . ' -" };
    if (reservedName(name)) return { error: "that name is reserved" };
    // the relay's words, as the relay folds a name (lowercase, spaces out; leetspeak undone)
    if (typed && RELAY_N.has(relayFold(name))) return { error: "that name is reserved" };
    return typed ? { name } : { name, guest: true };
  }

  // Chat's per-client and global limits (a blueprint post counts as a message): a 429 response, or null.
  limit(who, now) {
    const mine = (this.recent.get(who) || []).filter((t) => now - t < 60000);
    this.recent.set(who, mine);
    this.global = this.global.filter((t) => now - t < 60000);
    if (mine.length && now - mine[mine.length - 1] < CHAT.minGapS * 1000) {
      return json({ error: "slow down", retry_after_s: Math.ceil((CHAT.minGapS * 1000 - (now - mine[mine.length - 1])) / 1000) }, 429);
    }
    if (mine.length >= CHAT.perMinute || this.global.length >= CHAT.globalPerMinute) {
      return json({ error: "slow down", retry_after_s: 20 }, 429);
    }
    return null;
  }

  count(who, now) {
    this.recent.get(who).push(now);
    this.global.push(now);
    if (this.recent.size > 5000) this.recent.clear();
  }

  async postBlueprint(req, text) {
    if (this.get("chat_open") === "0") return json({ error: "chat is closed" }, 403);
    // Nick d17 08:30 after poll #1: designs come from the team; viewers' ideas go in chat, in words. Mod bp_open/bp_close.
    if (this.get("bp_open") !== "1") return json({ error: "blueprint sharing is closed: describe ideas in chat" }, 403);
    if (text.length > BP.maxString + 4096) return json({ error: `blueprint strings are at most ${BP.maxString} characters` }, 413);
    const body = JSON.parse(text || "{}");
    const who = await this.who(req);
    if (this.sql.exec("SELECT 1 FROM bans WHERE who = ?", who).toArray().length) {
      return json({ error: "you can't post right now" }, 403);
    }
    const cid = body.cid == null ? null : String(body.cid);
    if (cid !== null && !/^[0-9a-f]{16,32}$/.test(cid)) return json({ error: "cid must be 16-32 hex digits" }, 400);
    const cols = "id, t, name, title, kind, label, blueprints, entities, bytes";
    if (cid) {
      const had = this.sql.exec(`SELECT ${cols} FROM blueprints WHERE cid = ? AND who = ?`, cid, who).toArray();
      if (had.length) return json({ ok: true, repeat: true, blueprint: had[0] });
    }
    const name = this.viewerName(body.name, who);
    if (name.error) return json(name, 400);
    const title = tidy(body.title);
    if (!title) return json({ error: "a title, please" }, 400);
    if ([...title].length > BP.maxTitle) return json({ error: `titles are at most ${BP.maxTitle} characters` }, 400);
    if (LINK.test(title)) return json({ error: "links are not allowed" }, 400);
    const str = String(body.string || "").replace(/\s+/g, "");
    const now = Date.now();
    const limited = this.limit(who, now);
    if (limited) return limited;
    const hour = (this.bpTimes.get(who) || []).filter((t) => now - t < 3600000);
    const all = [...this.bpTimes.values()].reduce((n, l) => n + l.filter((t) => now - t < 3600000).length, 0);
    if (hour.length >= BP.perClientHour || all >= BP.globalHour) return json({ error: "slow down", retry_after_s: 600 }, 429);
    const d = await decodeBlueprint(str);
    if (d.error) return json({ error: d.error }, 400);
    if (this.sql.exec("SELECT 1 FROM blueprints WHERE string = ? AND hidden = 0", str).toArray().length) {
      return json({ error: "that blueprint was shared already" }, 400);
    }
    this.count(who, now);
    hour.push(now);
    this.bpTimes.set(who, hour);
    if (this.bpTimes.size > 5000) this.bpTimes.clear();
    const t = now / 1000;
    const row = this.sql.exec(`INSERT INTO blueprints (t, name, title, kind, label, blueprints, entities, bytes, string, who, cid)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`, t, name.name, title, d.kind, d.label, d.blueprints, d.entities,
      str.length, str, who, cid).toArray()[0];
    // the oldest go past BP.keep or BP.keepBytes
    this.sql.exec("DELETE FROM blueprints WHERE id <= ?", row.id - BP.keep);
    const sizes = this.sql.exec("SELECT id, bytes FROM blueprints ORDER BY id DESC").toArray();
    let total = 0;
    for (const r of sizes) {
      total += r.bytes;
      if (total > BP.keepBytes) { this.sql.exec("DELETE FROM blueprints WHERE id <= ?", r.id); break; }
    }
    return json({ ok: true, blueprint: { id: row.id, t, name: name.name, title, kind: d.kind, label: d.label,
      blueprints: d.blueprints, entities: d.entities, bytes: str.length } });
  }

  listBlueprints(req, url) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const after = parseInt(url.searchParams.get("after") || "0", 10) || 0;
    const rows = this.sql.exec(`SELECT id, t, name, title, kind, label, blueprints, entities, bytes FROM blueprints
      WHERE id > ? AND hidden = 0 ORDER BY id LIMIT ?`, after, BP.pageMax).toArray();
    const maxRow = this.sql.exec("SELECT COALESCE(MAX(id), 0) AS m FROM blueprints").toArray()[0];
    return json({ schema: SCHEMA, blueprints: rows, last_id: maxRow.m });
  }

  getBlueprint(req, url) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const id = parseInt(url.pathname.split("/").pop(), 10);
    const r = this.sql.exec(`SELECT id, t, name, title, kind, label, blueprints, entities, bytes, string FROM blueprints
      WHERE id = ? AND hidden = 0`, id).toArray();
    return r.length ? json({ schema: SCHEMA, blueprint: r[0] }) : json({ error: "no such blueprint" }, 404);
  }

  // ---- polls ----
  // A poll as everyone sees it: the vote counts (each voter's latest vote; a banned client's do not count), together
  // and apart (viewers, agents), the newest comments with name and choice (agent: an agent's), and the time left.
  // status: "open" until it closes, then "closed".
  pollView(p, now) {
    const options = JSON.parse(p.options);
    const viewers = options.map(() => 0), agents = options.map(() => 0);
    for (const r of this.sql.exec(`SELECT option, agent, COUNT(*) AS n FROM votes WHERE poll = ? AND current = 1
        AND voter NOT IN (SELECT who FROM bans) GROUP BY option, agent`, p.id).toArray()) {
      if (r.option >= 0 && r.option < options.length) (r.agent ? agents : viewers)[r.option] = r.n;
    }
    const counts = options.map((_, i) => viewers[i] + agents[i]);
    const sum = (l) => l.reduce((a, b) => a + b, 0);
    const open = p.status === "open" && p.closes > now;
    const comments = this.sql.exec(`SELECT id, t, name, option, comment, agent, host FROM votes WHERE poll = ? AND current = 1
      AND hidden = 0 AND comment != '' ORDER BY id DESC LIMIT ?`, p.id, POLL.commentsShown).toArray()
      .map(({ host, ...c }) => (host ? { ...c, agent: !!c.agent, host: true } : { ...c, agent: !!c.agent }));
    const details = JSON.parse(p.details || "[]");
    return { id: p.id, question: p.question, intro: p.intro || "", options, details: options.map((_, i) => details[i] || ""), counts, total: sum(counts), viewer_counts: viewers,
      viewer_total: sum(viewers), agent_counts: agents, agent_total: sum(agents),
      opens: p.opens, closes: p.closes, created_by: p.created_by, status: open ? "open" : "closed",
      left_s: open ? Math.round(p.closes - now) : 0, comments };
  }

  pollRow(id) {
    const r = this.sql.exec("SELECT * FROM polls WHERE id = ?", id).toArray();
    return r.length ? r[0] : null;
  }

  getPolls() {
    const now = Date.now() / 1000;
    const open = this.sql.exec("SELECT * FROM polls WHERE status = 'open' AND closes > ? ORDER BY closes", now).toArray();
    const closed = this.sql.exec(`SELECT * FROM polls WHERE status != 'open' OR closes <= ? ORDER BY closes DESC LIMIT ?`,
      now, POLL.closedShown).toArray();
    return json({ schema: SCHEMA, now, open: open.map((p) => this.pollView(p, now)),
      closed: closed.map((p) => this.pollView(p, now)),
      limits: { max_comment: POLL.maxComment } });
  }

  // A question, its intro and options (each a label, or {label, details}), as a poll or a viewer's idea takes them:
  // {question, intro, options, details} or {error}.
  pollText(body, viewer) {
    const question = tidy(body.question);
    if (!question) return { error: "a question, please" };
    if ([...question].length > POLL.maxQuestion) return { error: `questions are at most ${POLL.maxQuestion} characters` };
    const intro = tidy(body.intro);
    if ([...intro].length > POLL.maxIntro) return { error: `the intro is at most ${POLL.maxIntro} characters` };
    if (!Array.isArray(body.options)) return { error: "options must be a list" };
    const opts = body.options.map((o) => (o && typeof o === "object" ? { label: tidy(o.label), details: tidy(o.details) }
      : { label: tidy(o), details: "" })).filter((o) => o.label);
    if (opts.length < POLL.minOptions || opts.length > POLL.maxOptions) {
      return { error: `${POLL.minOptions} to ${POLL.maxOptions} options` };
    }
    const options = opts.map((o) => o.label), details = opts.map((o) => o.details);
    if (options.some((o) => [...o].length > POLL.maxOption)) return { error: `options are at most ${POLL.maxOption} characters` };
    if (details.some((d) => [...d].length > POLL.maxDetails)) return { error: `option details are at most ${POLL.maxDetails} characters` };
    if (new Set(options.map((o) => o.toLowerCase())).size !== options.length) return { error: "the options must differ" };
    if (viewer && [question, intro, ...options, ...details].some((x) => LINK.test(x))) return { error: "links are not allowed" };
    return { question, intro, options, details };
  }

  createPoll(req, text) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const body = JSON.parse(text || "{}");
    const q = this.pollText(body, false);
    if (q.error) return json(q, 400);
    const hours = body.hours == null ? 12 : Number(body.hours);
    if (!(hours > 0 && hours <= POLL.maxHours)) return json({ error: `hours must be above 0 and at most ${POLL.maxHours}` }, 400);
    const now = Date.now() / 1000;
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM polls WHERE status = 'open' AND closes > ?", now).toArray()[0].n;
    if (n >= POLL.maxOpen) return json({ error: `at most ${POLL.maxOpen} polls open at once` }, 409);
    const by = tidy(body.created_by).slice(0, 40) || "operator";
    const row = this.sql.exec(`INSERT INTO polls (question, options, opens, closes, created_by, intro, details)
      VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING *`, q.question, JSON.stringify(q.options), now, now + hours * 3600, by,
      q.intro, JSON.stringify(q.details)).toArray()[0];
    return json({ ok: true, poll: this.pollView(row, now) });
  }

  closePoll(req, id) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const p = this.pollRow(id);
    if (!p) return json({ error: "no such poll" }, 404);
    const now = Date.now() / 1000;
    if (p.status === "open") this.sql.exec("UPDATE polls SET status = 'closed', closes = ? WHERE id = ?", Math.min(p.closes, now), id);
    return json({ ok: true, poll: this.pollView(this.pollRow(id), now) });
  }

  async vote(req, text, id) {
    if (text.length > 4096) return json({ error: "too large" }, 413);
    const body = JSON.parse(text || "{}");
    if (body.agent != null) return this.agentVote(req, body, id);
    const who = await this.who(req);
    const host = this.hostOf(req);
    if (host.error) return json(host, 403);
    if (!host.host && this.sql.exec("SELECT 1 FROM bans WHERE who = ?", who).toArray().length) {
      return json({ error: "you can't post right now" }, 403);
    }
    const now = Date.now() / 1000;
    const p = this.pollRow(id);
    if (!p) return json({ error: "no such poll" }, 404);
    const cid = body.cid == null ? null : String(body.cid);
    if (cid !== null && !/^[0-9a-f]{16,32}$/.test(cid)) return json({ error: "cid must be 16-32 hex digits" }, 400);
    const cols = "id, t, name, option, comment";
    if (cid) {
      const had = this.sql.exec(`SELECT ${cols} FROM votes WHERE cid = ? AND voter = ? AND poll = ?`, cid, who, id).toArray();
      if (had.length) return json({ ok: true, repeat: true, vote: had[0], poll: this.pollView(p, now) });
    }
    if (!(p.status === "open" && p.closes > now)) return json({ error: "this poll is closed" }, 403);
    const option = Number(body.option);
    if (!Number.isInteger(option) || option < 0 || option >= JSON.parse(p.options).length) {
      return json({ error: "option must be one of the poll's (0, 1, ...)" }, 400);
    }
    const name = host.host ? { name: HOST.name } : this.viewerName(body.name, who);
    if (name.error) return json(name, 400);
    const comment = tidy(body.comment);
    if ([...comment].length > POLL.maxComment) return json({ error: `comments are at most ${POLL.maxComment} characters` }, 400);
    if (LINK.test(comment)) return json({ error: "links are not allowed" }, 400);
    // the same vote again: nothing new to keep
    const cur = this.sql.exec(`SELECT ${cols} FROM votes WHERE poll = ? AND voter = ? AND current = 1`, id, who).toArray();
    if (cur.length && cur[0].option === option && cur[0].comment === comment && cur[0].name === name.name) {
      return json({ ok: true, unchanged: true, vote: cur[0], poll: this.pollView(p, now) });
    }
    if (host.host) {
      const limited = this.hostLimit(now * 1000);
      if (limited) return limited;
    } else {
      const limited = this.limit(who, now * 1000);
      if (limited) return limited;
      this.count(who, now * 1000);
    }
    this.sql.exec("UPDATE votes SET current = 0 WHERE poll = ? AND voter = ? AND current = 1", id, who);
    const row = this.sql.exec(`INSERT INTO votes (poll, voter, name, option, comment, t, cid, host) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      RETURNING ${cols}`, id, who, name.name, option, comment, now, cid, host.host ? 1 : 0).toArray()[0];
    if (host.host) row.host = true;
    // the history: a client's 20 latest votes on a poll
    this.sql.exec(`DELETE FROM votes WHERE poll = ? AND voter = ? AND current = 0 AND id NOT IN
      (SELECT id FROM votes WHERE poll = ? AND voter = ? ORDER BY id DESC LIMIT 20)`, id, who, id, who);
    return json({ ok: true, vote: row, replaced: cur.length > 0, poll: this.pollView(p, now) });
  }

  // An agent's vote (./fh poll vote on the Mac, with the publish token): voter "agent:KEY", shown as the agent's name;
  // one per agent per poll, a later one replaces it. No viewer limits (the host CLI sends it once per call).
  agentVote(req, body, id) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const key = String(body.agent).toLowerCase();
    if (!/^[a-z0-9][a-z0-9_.-]{0,31}$/.test(key)) return json({ error: "agent must be the agent's name" }, 400);
    const p = this.pollRow(id);
    if (!p) return json({ error: "no such poll" }, 404);
    const now = Date.now() / 1000;
    if (!(p.status === "open" && p.closes > now)) return json({ error: "this poll is closed" }, 403);
    const option = Number(body.option);
    if (!Number.isInteger(option) || option < 0 || option >= JSON.parse(p.options).length) {
      return json({ error: "option must be one of the poll's (0, 1, ...)" }, 400);
    }
    const name = tidy(body.name).slice(0, 30) || key;
    const comment = tidy(body.comment);
    if ([...comment].length > POLL.maxComment) return json({ error: `comments are at most ${POLL.maxComment} characters` }, 400);
    if (LINK.test(comment)) return json({ error: "links are not allowed" }, 400);
    const voter = "agent:" + key, cols = "id, t, name, option, comment";
    const cur = this.sql.exec(`SELECT ${cols} FROM votes WHERE poll = ? AND voter = ? AND current = 1`, id, voter).toArray();
    if (cur.length && cur[0].option === option && cur[0].comment === comment && cur[0].name === name) {
      return json({ ok: true, unchanged: true, vote: cur[0], poll: this.pollView(p, now) });
    }
    this.sql.exec("UPDATE votes SET current = 0 WHERE poll = ? AND voter = ? AND current = 1", id, voter);
    const row = this.sql.exec(`INSERT INTO votes (poll, voter, name, option, comment, t, agent) VALUES (?, ?, ?, ?, ?, ?, 1)
      RETURNING ${cols}`, id, voter, name, option, comment, now).toArray()[0];
    this.sql.exec(`DELETE FROM votes WHERE poll = ? AND voter = ? AND current = 0 AND id NOT IN
      (SELECT id FROM votes WHERE poll = ? AND voter = ? ORDER BY id DESC LIMIT 20)`, id, voter, id, voter);
    return json({ ok: true, vote: row, replaced: cur.length > 0, poll: this.pollView(p, now) });
  }

  // The voter log for the operator: every vote kept (current = 1: the one that counts), with the client's hash.
  voters(req, id) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const p = this.pollRow(id);
    if (!p) return json({ error: "no such poll" }, 404);
    const options = JSON.parse(p.options);
    const votes = this.sql.exec(`SELECT id, t, voter, name, option, comment, current, hidden, agent, voided FROM votes WHERE poll = ?
      ORDER BY id`, id).toArray().map((v) => ({ ...v, agent: !!v.agent, choice: options[v.option] ?? null,
        // operator only (token): the chat names this connection's hash posted under, to spot one person voting as many
        chat_names: v.agent ? [] : this.sql.exec(`SELECT name, COUNT(*) AS n, MIN(t) AS first, MAX(t) AS last FROM chat
          WHERE who = ? GROUP BY name ORDER BY n DESC`, v.voter).toArray() }));
    return json({ schema: SCHEMA, poll: this.pollView(p, Date.now() / 1000), votes });
  }

  async suggestPoll(req, text) {
    if (text.length > 4096) return json({ error: "too large" }, 413);
    const body = JSON.parse(text || "{}");
    const who = await this.who(req);
    const host = this.hostOf(req);
    if (host.error) return json(host, 403);
    if (!host.host && this.sql.exec("SELECT 1 FROM bans WHERE who = ?", who).toArray().length) {
      return json({ error: "you can't post right now" }, 403);
    }
    const cid = body.cid == null ? null : String(body.cid);
    if (cid !== null && !/^[0-9a-f]{16,32}$/.test(cid)) return json({ error: "cid must be 16-32 hex digits" }, 400);
    if (cid && this.sql.exec("SELECT 1 FROM poll_ideas WHERE cid = ? AND who = ?", cid, who).toArray().length) {
      return json({ ok: true, repeat: true });
    }
    const name = host.host ? { name: HOST.name } : this.viewerName(body.name, who);
    if (name.error) return json(name, 400);
    const q = this.pollText(body, true);
    if (q.error) return json(q, 400);
    const hours = body.hours == null || body.hours === "" ? null : Number(body.hours);
    if (hours !== null && !(hours > 0 && hours <= POLL.maxHours)) return json({ error: `hours: 1 to ${POLL.maxHours}` }, 400);
    const now = Date.now();
    const limited = this.limit(who, now);
    if (limited) return limited;
    const hour = (this.ideaTimes.get(who) || []).filter((t) => now - t < 3600000);
    if (hour.length >= POLL.suggestPerClientHour) return json({ error: "slow down", retry_after_s: 600 }, 429);
    this.count(who, now);
    hour.push(now);
    this.ideaTimes.set(who, hour);
    if (this.ideaTimes.size > 5000) this.ideaTimes.clear();
    const row = this.sql.exec(`INSERT INTO poll_ideas (t, name, question, options, hours, who, cid, intro, details)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`, now / 1000, name.name, q.question, JSON.stringify(q.options), hours,
      who, cid, q.intro, JSON.stringify(q.details)).toArray()[0];
    this.sql.exec("DELETE FROM poll_ideas WHERE id <= ?", row.id - POLL.suggestKeep);
    return json({ ok: true });
  }

  // Viewers' poll ideas, for the Mac (it files each into the operator inbox once).
  listIdeas(req, url) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const after = parseInt(url.searchParams.get("after") || "0", 10) || 0;
    const ideas = this.sql.exec(`SELECT id, t, name, question, intro, options, details, hours FROM poll_ideas WHERE id > ?
      AND who NOT IN (SELECT who FROM bans) ORDER BY id LIMIT 50`, after).toArray()
      .map((r) => ({ ...r, options: JSON.parse(r.options), details: JSON.parse(r.details) }));
    const maxRow = this.sql.exec("SELECT COALESCE(MAX(id), 0) AS m FROM poll_ideas").toArray()[0];
    return json({ schema: SCHEMA, ideas, last_id: maxRow.m });
  }

  mod(req, text) {
    if (!tokenOk(req, this.env)) return json({ error: "unauthorized" }, 401);
    const body = JSON.parse(text || "{}");
    const seq = parseInt(body.seq, 10);
    const rowWho = () => {
      const r = this.sql.exec("SELECT who FROM chat WHERE seq = ?", seq).toArray();
      return r.length ? r[0].who : null;
    };
    switch (body.action) {
      case "hide": this.sql.exec("UPDATE chat SET hidden = 1 WHERE seq = ?", seq); break;
      case "unhide": this.sql.exec("UPDATE chat SET hidden = 0 WHERE seq = ?", seq); break;
      case "ban": {
        const w = rowWho();
        if (!w) return json({ error: "no such message" }, 404);
        this.sql.exec("INSERT OR REPLACE INTO bans (who, t) VALUES (?, ?)", w, Date.now() / 1000);
        this.sql.exec("UPDATE chat SET hidden = 1 WHERE who = ?", w);
        this.sql.exec("UPDATE blueprints SET hidden = 1 WHERE who = ?", w);
        this.sql.exec("UPDATE votes SET hidden = 1 WHERE voter = ?", w);
        break;
      }
      case "unban": {
        const w = rowWho();
        if (w) this.sql.exec("DELETE FROM bans WHERE who = ?", w);
        break;
      }
      // a shared blueprint: hide it (the Mac does not pull it), or ban whoever shared it (and hide all they posted)
      case "hide_blueprint": this.sql.exec("UPDATE blueprints SET hidden = 1 WHERE id = ?", parseInt(body.id, 10)); break;
      case "unhide_blueprint": this.sql.exec("UPDATE blueprints SET hidden = 0 WHERE id = ?", parseInt(body.id, 10)); break;
      case "ban_blueprint": {
        const r = this.sql.exec("SELECT who FROM blueprints WHERE id = ?", parseInt(body.id, 10)).toArray();
        if (!r.length) return json({ error: "no such blueprint" }, 404);
        this.sql.exec("INSERT OR REPLACE INTO bans (who, t) VALUES (?, ?)", r[0].who, Date.now() / 1000);
        this.sql.exec("UPDATE chat SET hidden = 1 WHERE who = ?", r[0].who);
        this.sql.exec("UPDATE blueprints SET hidden = 1 WHERE who = ?", r[0].who);
        this.sql.exec("UPDATE votes SET hidden = 1 WHERE voter = ?", r[0].who);
        break;
      }
      // a poll comment (votes.id): hide it (the vote still counts), or ban whoever wrote it (their votes stop counting)
      case "hide_comment": this.sql.exec("UPDATE votes SET hidden = 1 WHERE id = ?", parseInt(body.id, 10)); break;
      case "unhide_comment": this.sql.exec("UPDATE votes SET hidden = 0 WHERE id = ?", parseInt(body.id, 10)); break;
      // void_vote (Nick d17 07:40): a vote stops counting (current = 0, voided = 1), nothing else changes: no ban, chat kept
      case "void_vote": {
        const r = this.sql.exec("SELECT id, agent FROM votes WHERE id = ?", parseInt(body.id, 10)).toArray();
        if (!r.length) return json({ error: "no such vote" }, 404);
        this.sql.exec("UPDATE votes SET current = 0, voided = 1 WHERE id = ?", r[0].id);
        break;
      }
      case "ban_voter": {
        const r = this.sql.exec("SELECT voter, agent FROM votes WHERE id = ?", parseInt(body.id, 10)).toArray();
        if (!r.length) return json({ error: "no such vote" }, 404);
        if (r[0].agent) return json({ error: "an agent's vote: hide_comment hides its comment" }, 400);
        this.sql.exec("INSERT OR REPLACE INTO bans (who, t) VALUES (?, ?)", r[0].voter, Date.now() / 1000);
        this.sql.exec("UPDATE chat SET hidden = 1 WHERE who = ?", r[0].voter);
        this.sql.exec("UPDATE blueprints SET hidden = 1 WHERE who = ?", r[0].voter);
        this.sql.exec("UPDATE votes SET hidden = 1 WHERE voter = ?", r[0].voter);
        break;
      }
      case "close": this.put("chat_open", "0"); break;
      case "open": this.put("chat_open", "1"); break;
      case "bp_close": this.put("bp_open", "0"); break;
      case "bp_open": this.put("bp_open", "1"); break;
      // a fresh start (the public run): hide every message so far; seq keeps counting, so pollers lose nothing new
      case "clear": this.sql.exec("UPDATE chat SET hidden = 1"); break;
      default: return json({ error: "action must be hide, unhide, ban, unban, open, close, bp_open, bp_close, clear, hide_blueprint, " +
        "unhide_blueprint, ban_blueprint, hide_comment, unhide_comment or ban_voter" }, 400);
    }
    return json({ ok: true });
  }
}

// Player of Games live API (Cloudflare Worker + one Durable Object). Contract: docs/LIVE-API.md.
//
//   GET  /v1/state            latest stream state pushed from the Mac (public)
//   POST /v1/state            replace it (Authorization: Bearer PUBLISH_TOKEN)
//   GET  /v1/chat?after=SEQ   viewer chat messages after SEQ (public); the ones that go to the game only, unless
//                             &channels=all (the live page): then the viewers-only ones too, each with its channel
//   POST /v1/chat             post a message {name, text, cid?, channel?} (no accounts; rate limited per client; the
//                             same cid from the same client is stored once: a repeat returns the first message);
//                             channel "viewers": on the site only, never relayed to the agents (default "game")
//   POST /v1/mod              hide/unhide/ban/unban/open/close (Authorization: Bearer PUBLISH_TOKEN)
//   POST /v1/here             {id}: an open live page, once a minute; GET /v1/state counts them as site_watching
//   POST /v1/blueprints       a viewer shares a blueprint {name, title, string, cid?}: checked to decode to a blueprint
//                             or book, under chat's rules and limits (viewer LimeLight, d16 16:17)
//   GET  /v1/blueprints?after=ID, GET /v1/blueprints/ID   the shared ones, for the Mac (Authorization: PUBLISH_TOKEN)
//   GET  /v1/polls            open polls and the latest closed ones: counts, comments, time left (public)
//   POST /v1/polls/ID/vote    {option, name, comment?, cid?}: one vote per client per poll, a later one replaces it;
//                             with the publish token and {agent}: an agent's vote (./fh poll vote), voter agent:NAME
//   POST /v1/polls/suggest    a viewer's poll idea {name, question, options, hours?, cid?}: seen by the operator only
//   POST /v1/polls, POST /v1/polls/ID/close, GET /v1/polls/ID/voters, GET /v1/polls/suggestions?after=ID
//                             the operator's (Authorization: PUBLISH_TOKEN): create, close early, the voter log, ideas
//
// Everything is unlisted: every response carries X-Robots-Tag noindex and /robots.txt disallows all.
// Client addresses are never stored: rate limits and bans key on a salted hash.

const SCHEMA = 1;
const MAX_STATE_BYTES = 256 * 1024;
const CHAT = {
  maxLen: 200,          // characters per message
  minGapS: 4,           // per client: seconds between messages
  perMinute: 8,         // per client
  globalPerMinute: 60,  // all clients together
  keep: 2000,           // messages kept
  pageMax: 100,
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
const RESERVED = ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse", "fable", "operator",
  "mod", "moderator", "admin", "caster", "system", "server", "player of games", "pog"];

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
const MICRO_TTL = { "/v1/state": 3000, "/v1/chat": 2000, "/v1/polls": 3000 };
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
          "Access-Control-Allow-Headers": "Content-Type",
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
    if (req.method === "POST" && path === "/v1/chat") for (const k of micro.keys()) if (k.startsWith("/v1/chat")) micro.delete(k);
    if (req.method === "POST" && path.startsWith("/v1/polls")) for (const k of micro.keys()) if (k.startsWith("/v1/polls")) micro.delete(k);
    return withCors(resp, req, env);
  },
};

function tokenOk(req, env) {
  const want = env.PUBLISH_TOKEN || "";
  const got = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (want.length < 16 || got.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ got.charCodeAt(i);
  return diff === 0;
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
    ctx.blockConcurrencyWhile(async () => {
      this.sql.exec(`CREATE TABLE IF NOT EXISTS chat (seq INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL,
        name TEXT NOT NULL, text TEXT NOT NULL, who TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)`);
      // cid: the page's id for one message (joonazan, d15 08:05: messages sent twice); a table from before it gains it
      try { this.sql.exec(`ALTER TABLE chat ADD COLUMN cid TEXT`); } catch (e) { /* already there */ }
      this.sql.exec(`CREATE INDEX IF NOT EXISTS chat_cid ON chat (cid)`);
      // channel (viewer LimeLight555, d16 10:36): "viewers" lines stay on the site; GET /v1/chat leaves them out unless
      // asked (channels=all), so the Mac's relay to the game never reads them
      try { this.sql.exec(`ALTER TABLE chat ADD COLUMN channel TEXT NOT NULL DEFAULT 'game'`); } catch (e) { /* already there */ }
      this.sql.exec(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
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
      this.sql.exec(`CREATE TABLE IF NOT EXISTS poll_ideas (id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL,
        name TEXT NOT NULL, question TEXT NOT NULL, options TEXT NOT NULL, hours REAL, who TEXT NOT NULL, cid TEXT,
        intro TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '[]')`);
      this.ideaTimes = new Map(); // who -> [ms] suggestions in the last hour
      this.bpTimes = new Map(); // who -> [ms] blueprint posts in the last hour
      this.state = this.get("state");
      this.received = Number(this.get("received") || 0);
      this.salt = this.get("salt");
      if (!this.salt) {
        const b = crypto.getRandomValues(new Uint8Array(16));
        this.salt = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
        this.put("salt", this.salt);
      }
    });
  }
  get(k) {
    const r = this.sql.exec("SELECT v FROM kv WHERE k = ?", k).toArray();
    return r.length ? r[0].v : null;
  }
  put(k, v) {
    this.sql.exec("INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, String(v));
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
      switch (route) {
        case "GET /v1/state": return this.getState();
        case "POST /v1/state": return this.postState(req, text);
        case "GET /v1/chat": return this.getChat(url);
        case "POST /v1/chat": return await this.postChat(req, text);
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
      return json({ error: "bad request" }, 400);
    }
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
    this.put("state", this.state);
    this.put("received", this.received);
    return json({ ok: true, received: this.received });
  }

  getChat(url) {
    const limit = Math.max(1, Math.min(CHAT.pageMax, parseInt(url.searchParams.get("limit") || "50", 10) || 50));
    const after = parseInt(url.searchParams.get("after") || "", 10);
    const all = url.searchParams.get("channels") === "all";
    const cols = all ? "seq, t, name, text, channel" : "seq, t, name, text";
    const only = all ? "" : " AND channel = 'game'";
    let rows;
    if (Number.isFinite(after)) {
      rows = this.sql.exec(`SELECT ${cols} FROM chat WHERE seq > ? AND hidden = 0${only} ORDER BY seq LIMIT ?`,
        after, limit).toArray();
    } else {
      rows = this.sql.exec(`SELECT ${cols} FROM chat WHERE hidden = 0${only} ORDER BY seq DESC LIMIT ?`, limit)
        .toArray().reverse();
    }
    const maxRow = this.sql.exec("SELECT COALESCE(MAX(seq), 0) AS m FROM chat").toArray()[0];
    const hidden = this.sql.exec("SELECT seq FROM chat WHERE hidden = 1 ORDER BY seq DESC LIMIT 200").toArray().map((r) => r.seq);
    return json({
      schema: SCHEMA,
      open: this.get("chat_open") !== "0",
      messages: rows,
      last_seq: maxRow.m,
      hidden,
      limits: { max_len: CHAT.maxLen, min_gap_s: CHAT.minGapS, per_minute: CHAT.perMinute },
    });
  }

  async postChat(req, text) {
    if (this.get("chat_open") === "0") return json({ error: "chat is closed" }, 403);
    if (text.length > 4096) return json({ error: "too large" }, 413);
    const body = JSON.parse(text || "{}");
    const who = await this.who(req);
    if (this.sql.exec("SELECT 1 FROM bans WHERE who = ?", who).toArray().length) {
      return json({ error: "you can't post right now" }, 403);
    }
    // The same message again (a second press, a retry after a slow reply): the first one, before any limit.
    const cid = body.cid == null ? null : String(body.cid);
    if (cid !== null && !/^[0-9a-f]{16,32}$/.test(cid)) return json({ error: "cid must be 16-32 hex digits" }, 400);
    const channel = body.channel == null ? "game" : String(body.channel);
    if (channel !== "game" && channel !== "viewers") return json({ error: "channel must be game or viewers" }, 400);
    if (cid) {
      const had = this.sql.exec("SELECT seq, t, name, text, channel FROM chat WHERE cid = ? AND who = ?", cid, who).toArray();
      if (had.length) return json({ ok: true, repeat: true, message: had[0] });
    }
    const msg = tidy(body.text);
    if (!msg) return json({ error: "empty message" }, 400);
    if ([...msg].length > CHAT.maxLen) return json({ error: `messages are at most ${CHAT.maxLen} characters` }, 400);
    if (LINK.test(msg)) return json({ error: "links are not allowed" }, 400);
    const name = this.viewerName(body.name);
    if (name.error) return json(name, 400);
    const now = Date.now();
    const limited = this.limit(who, now);
    if (limited) return limited;
    const last = this.lastText.get(who);
    if (last && last.text === msg.toLowerCase() && now - last.at < 120000) return json({ error: "duplicate message" }, 400);
    this.count(who, now);
    this.lastText.set(who, { text: msg.toLowerCase(), at: now });
    if (this.lastText.size > 5000) this.lastText.clear();

    const t = now / 1000;
    const row = this.sql.exec("INSERT INTO chat (t, name, text, who, cid, channel) VALUES (?, ?, ?, ?, ?, ?) RETURNING seq",
      t, name.name, msg, who, cid, channel).toArray()[0];
    this.sql.exec("DELETE FROM chat WHERE seq <= ?", row.seq - CHAT.keep);
    return json({ ok: true, message: { seq: row.seq, t, name: name.name, text: msg, channel } });
  }

  // A viewer's name, as chat takes it: {name} or {error}.
  viewerName(raw) {
    const name = tidy(raw).slice(0, 20) || "viewer";
    if (!/^[\p{L}\p{N} _.'-]{2,20}$/u.test(name)) return { error: "names are 2-20 letters, digits, spaces or _ . ' -" };
    if (RESERVED.includes(name.toLowerCase())) return { error: "that name is reserved" };
    return { name };
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
    const name = this.viewerName(body.name);
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
    const comments = this.sql.exec(`SELECT id, t, name, option, comment, agent FROM votes WHERE poll = ? AND current = 1
      AND hidden = 0 AND comment != '' ORDER BY id DESC LIMIT ?`, p.id, POLL.commentsShown).toArray()
      .map((c) => ({ ...c, agent: !!c.agent }));
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
    if (this.sql.exec("SELECT 1 FROM bans WHERE who = ?", who).toArray().length) {
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
    const name = this.viewerName(body.name);
    if (name.error) return json(name, 400);
    const comment = tidy(body.comment);
    if ([...comment].length > POLL.maxComment) return json({ error: `comments are at most ${POLL.maxComment} characters` }, 400);
    if (LINK.test(comment)) return json({ error: "links are not allowed" }, 400);
    // the same vote again: nothing new to keep
    const cur = this.sql.exec(`SELECT ${cols} FROM votes WHERE poll = ? AND voter = ? AND current = 1`, id, who).toArray();
    if (cur.length && cur[0].option === option && cur[0].comment === comment && cur[0].name === name.name) {
      return json({ ok: true, unchanged: true, vote: cur[0], poll: this.pollView(p, now) });
    }
    const limited = this.limit(who, now * 1000);
    if (limited) return limited;
    this.count(who, now * 1000);
    this.sql.exec("UPDATE votes SET current = 0 WHERE poll = ? AND voter = ? AND current = 1", id, who);
    const row = this.sql.exec(`INSERT INTO votes (poll, voter, name, option, comment, t, cid) VALUES (?, ?, ?, ?, ?, ?, ?)
      RETURNING ${cols}`, id, who, name.name, option, comment, now, cid).toArray()[0];
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
    const votes = this.sql.exec(`SELECT id, t, voter, name, option, comment, current, hidden, agent FROM votes WHERE poll = ?
      ORDER BY id`, id).toArray().map((v) => ({ ...v, agent: !!v.agent, choice: options[v.option] ?? null }));
    return json({ schema: SCHEMA, poll: this.pollView(p, Date.now() / 1000), votes });
  }

  async suggestPoll(req, text) {
    if (text.length > 4096) return json({ error: "too large" }, 413);
    const body = JSON.parse(text || "{}");
    const who = await this.who(req);
    if (this.sql.exec("SELECT 1 FROM bans WHERE who = ?", who).toArray().length) {
      return json({ error: "you can't post right now" }, 403);
    }
    const cid = body.cid == null ? null : String(body.cid);
    if (cid !== null && !/^[0-9a-f]{16,32}$/.test(cid)) return json({ error: "cid must be 16-32 hex digits" }, 400);
    if (cid && this.sql.exec("SELECT 1 FROM poll_ideas WHERE cid = ? AND who = ?", cid, who).toArray().length) {
      return json({ ok: true, repeat: true });
    }
    const name = this.viewerName(body.name);
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
      // a fresh start (the public run): hide every message so far; seq keeps counting, so pollers lose nothing new
      case "clear": this.sql.exec("UPDATE chat SET hidden = 1"); break;
      default: return json({ error: "action must be hide, unhide, ban, unban, open, close, clear, hide_blueprint, " +
        "unhide_blueprint, ban_blueprint, hide_comment, unhide_comment or ban_voter" }, 400);
    }
    return json({ ok: true });
  }
}

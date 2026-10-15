// Player of Games live API (Cloudflare Worker + one Durable Object). Contract: docs/LIVE-API.md.
//
//   GET  /v1/state            latest stream state pushed from the Mac (public)
//   POST /v1/state            replace it (Authorization: Bearer PUBLISH_TOKEN)
//   GET  /v1/chat?after=SEQ   viewer chat messages after SEQ (public)
//   POST /v1/chat             post a message {name, text, cid?} (no accounts; rate limited per client; the same cid
//                             from the same client is stored once: a repeat returns the first message)
//   POST /v1/mod              hide/unhide/ban/unban/open/close (Authorization: Bearer PUBLISH_TOKEN)
//   POST /v1/here             {id}: an open live page, once a minute; GET /v1/state counts them as site_watching
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
const MICRO_TTL = { "/v1/state": 3000, "/v1/chat": 2000 };

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
    if (req.method === "POST" && (path === "/v1/chat" || path === "/v1/here") && origin && !originAllowed(origin, env)) {
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
      this.sql.exec(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
      this.sql.exec(`CREATE TABLE IF NOT EXISTS bans (who TEXT PRIMARY KEY, t REAL NOT NULL)`);
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
        default: return json({ error: "not found" }, 404);
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
    let rows;
    if (Number.isFinite(after)) {
      rows = this.sql.exec("SELECT seq, t, name, text FROM chat WHERE seq > ? AND hidden = 0 ORDER BY seq LIMIT ?",
        after, limit).toArray();
    } else {
      rows = this.sql.exec("SELECT seq, t, name, text FROM chat WHERE hidden = 0 ORDER BY seq DESC LIMIT ?", limit)
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
    if (cid) {
      const had = this.sql.exec("SELECT seq, t, name, text FROM chat WHERE cid = ? AND who = ?", cid, who).toArray();
      if (had.length) return json({ ok: true, repeat: true, message: had[0] });
    }
    const msg = tidy(body.text);
    let name = tidy(body.name).slice(0, 20);
    if (!msg) return json({ error: "empty message" }, 400);
    if ([...msg].length > CHAT.maxLen) return json({ error: `messages are at most ${CHAT.maxLen} characters` }, 400);
    if (LINK.test(msg)) return json({ error: "links are not allowed" }, 400);
    if (!name) name = "viewer";
    if (!/^[\p{L}\p{N} _.'-]{2,20}$/u.test(name)) return json({ error: "names are 2-20 letters, digits, spaces or _ . ' -" }, 400);
    if (RESERVED.includes(name.toLowerCase())) return json({ error: "that name is reserved" }, 400);

    const now = Date.now();
    const mine = (this.recent.get(who) || []).filter((t) => now - t < 60000);
    this.global = this.global.filter((t) => now - t < 60000);
    if (mine.length && now - mine[mine.length - 1] < CHAT.minGapS * 1000) {
      return json({ error: "slow down", retry_after_s: Math.ceil((CHAT.minGapS * 1000 - (now - mine[mine.length - 1])) / 1000) }, 429);
    }
    if (mine.length >= CHAT.perMinute || this.global.length >= CHAT.globalPerMinute) {
      return json({ error: "slow down", retry_after_s: 20 }, 429);
    }
    const last = this.lastText.get(who);
    if (last && last.text === msg.toLowerCase() && now - last.at < 120000) return json({ error: "duplicate message" }, 400);
    mine.push(now);
    this.recent.set(who, mine);
    this.global.push(now);
    this.lastText.set(who, { text: msg.toLowerCase(), at: now });
    if (this.recent.size > 5000) this.recent.clear();
    if (this.lastText.size > 5000) this.lastText.clear();

    const t = now / 1000;
    const row = this.sql.exec("INSERT INTO chat (t, name, text, who, cid) VALUES (?, ?, ?, ?, ?) RETURNING seq", t, name, msg, who, cid)
      .toArray()[0];
    this.sql.exec("DELETE FROM chat WHERE seq <= ?", row.seq - CHAT.keep);
    return json({ ok: true, message: { seq: row.seq, t, name, text: msg } });
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
        break;
      }
      case "unban": {
        const w = rowWho();
        if (w) this.sql.exec("DELETE FROM bans WHERE who = ?", w);
        break;
      }
      case "close": this.put("chat_open", "0"); break;
      case "open": this.put("chat_open", "1"); break;
      // a fresh start (the public run): hide every message so far; seq keeps counting, so pollers lose nothing new
      case "clear": this.sql.exec("UPDATE chat SET hidden = 1"); break;
      default: return json({ error: "action must be hide, unhide, ban, unban, open, close or clear" }, 400);
    }
    return json({ ok: true });
  }
}

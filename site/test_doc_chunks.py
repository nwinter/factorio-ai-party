#!/usr/bin/env python3
"""(d29 batch333) site/worker/worker.js keeps the state and board documents in rows of DOC.chunk characters.

From d29 01:40 the live object's one 230 KB kv "state" row failed every read and write with SQLITE_NOMEM, the
constructor's read of it threw, and every endpoint answered 500. Checks, under node:sqlite on a file (a restart reads
the same store):
- a 230 KB state and an 85 KB board, with surrogate pairs on the cuts, come back the same after a restart;
- no stored value is longer than DOC.chunk characters, and a shorter document drops its extra rows;
- nothing reads or writes kv's old "state" and "board" rows (a store that has them starts with no documents);
- a start that fails (SQLITE_NOMEM) answers 503 with the error, and the next request starts the object and serves;
- a storage error in a request answers 503 (it was 400 bad request), a body that is not JSON still 400;
- GET /v1/debug needs the publish token and reports the documents' rows.
"""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

WORKER = pathlib.Path(__file__).resolve().parent / "worker" / "worker.js"
TOKEN = "t" * 32

NODE = r"""
const { DatabaseSync } = require('node:sqlite');
const [, , workerUrl, token, dbPath] = process.argv;
const db = new DatabaseSync(dbPath);
const seen = [];
let failNext = 0;
const sql = { exec(q, ...params) {
  if (failNext > 0) { failNext--; throw new Error('out of memory: SQLITE_NOMEM'); }
  seen.push([q, params]);
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
const make = async (mod) => {
  const live = new mod.Live({ storage: { sql }, blockConcurrencyWhile: async (f) => f() }, { PUBLISH_TOKEN: token });
  await new Promise((r) => setTimeout(r, 5));
  return live;
};
const call = async (live, method, path, body, auth) => {
  const headers = { 'x-client-ip': '1.2.3.4' };
  if (auth) headers.Authorization = 'Bearer ' + auth;
  const r = await live.fetch(new Request('https://api.test' + path, { method, ...(body ? { body: typeof body === 'string' ? body : JSON.stringify(body) } : {}), headers }));
  return { status: r.status, body: await r.json() };
};
// a document of n characters (once JSON) whose first cut of 16384 falls inside a surrogate pair, more pairs further on
const doc = (n, tag) => {
  const head = 16383 - JSON.stringify({ tag, text: '' }).length + 2;
  return { tag, text: 'x'.repeat(head) + '\u{1F680}' + 'y\u{1F9EA}'.repeat(Math.floor((n - head - 40) / 3)) };
};
import(workerUrl).then(async (mod) => {
  const out = {};
  // a store from before: kv's old state and board rows
  db.exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)");
  db.prepare("INSERT INTO kv (k, v) VALUES ('state', ?), ('board', ?), ('received', '123'), ('board_received', '124')").run('{"old":1}', '{"old":2}');
  let live = await make(mod);
  out.fresh = (await call(live, 'GET', '/v1/state')).body;
  out.freshBoard = (await call(live, 'GET', '/v1/board')).body;
  const state = doc(230000, 'state'), board = doc(85000, 'board');
  out.postState = (await call(live, 'POST', '/v1/state', state, token)).status;
  out.postBoard = (await call(live, 'POST', '/v1/board', board, token)).status;
  out.rows = db.prepare("SELECT k, COUNT(*) AS n, MAX(length(v)) AS longest FROM docs GROUP BY k ORDER BY k").all();
  out.firstRow = db.prepare("SELECT length(v) AS n, substr(v, -1) AS last FROM docs WHERE k = 'state' AND i = 0").get();
  live = await make(mod);  // a restart: the documents come from their rows
  out.sameState = JSON.stringify((await call(live, 'GET', '/v1/state')).body.state) === JSON.stringify(state);
  out.sameBoard = JSON.stringify((await call(live, 'GET', '/v1/board')).body.board) === JSON.stringify(board);
  const small = { tag: 'small' };
  out.postSmall = (await call(live, 'POST', '/v1/state', small, token)).status;
  out.smallRows = db.prepare("SELECT COUNT(*) AS n FROM docs WHERE k = 'state'").get().n;
  live = await make(mod);
  out.sameSmall = JSON.stringify((await call(live, 'GET', '/v1/state')).body.state) === JSON.stringify(small);
  out.oldKv = db.prepare("SELECT k, v FROM kv WHERE k IN ('state', 'board') ORDER BY k").all();
  out.kvBig = seen.filter(([q, p]) => /\bkv\b/.test(q) && (p.includes('state') || p.includes('board'))).map(([q, p]) => q + ' ' + JSON.stringify(p));
  // a start that fails (the constructor's and the first request's): 503 with the error, then the next request starts it
  failNext = 2;
  live = await make(mod);
  out.failed = await call(live, 'GET', '/v1/state');
  out.after = await call(live, 'GET', '/v1/state');
  failNext = 1;  // a storage error in a request
  out.storageError = await call(live, 'GET', '/v1/chat');
  out.badJson = (await call(live, 'POST', '/v1/state', '{not json', token)).status;
  out.debugNoToken = (await call(live, 'GET', '/v1/debug')).status;
  out.debug = (await call(live, 'GET', '/v1/debug', null, token)).body;
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
}).catch((e) => { console.error(e && e.stack || e); process.exit(1); });
"""


def main():
    node = shutil.which("node")
    if not node or subprocess.run([node, "-e", "require('node:sqlite')"], capture_output=True).returncode:
        print("doc chunks: skipped (no node with node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        script = os.path.join(d, "run.cjs")
        open(script, "w").write(NODE)
        p = subprocess.run([node, "--no-warnings", script, WORKER.as_uri(), TOKEN, os.path.join(d, "live.db")],
                           capture_output=True, text=True, timeout=120)
        assert p.returncode == 0, p.stderr
        o = json.loads(p.stdout)
    assert o["fresh"]["state"] is None and o["fresh"]["received"] is None, o["fresh"]
    assert o["freshBoard"]["board"] is None and o["freshBoard"]["received"] is None, o["freshBoard"]
    assert o["postState"] == 200 and o["postBoard"] == 200, o
    rows = {r["k"]: r for r in o["rows"]}
    assert rows["state"]["n"] == 15 and rows["board"]["n"] == 6, rows
    assert max(r["longest"] for r in rows.values()) <= 16384, rows
    assert o["firstRow"]["n"] == 16383, o["firstRow"]  # the cut moved back off the pair's high half
    assert o["sameState"] and o["sameBoard"], o
    assert o["postSmall"] == 200 and o["smallRows"] == 1 and o["sameSmall"], o
    assert o["oldKv"] == [{"k": "board", "v": '{"old":2}'}, {"k": "state", "v": '{"old":1}'}], o["oldKv"]
    assert o["kvBig"] == [], o["kvBig"]
    assert o["failed"]["status"] == 503 and "SQLITE_NOMEM" in o["failed"]["body"]["detail"], o["failed"]
    assert o["after"]["status"] == 200 and o["after"]["body"]["state"] == {"tag": "small"}, o["after"]
    assert o["storageError"]["status"] == 503 and "SQLITE_NOMEM" in o["storageError"]["body"]["detail"], o["storageError"]
    assert o["badJson"] == 400, o
    assert o["debugNoToken"] == 401, o
    dbg = o["debug"]
    assert dbg["ready"] is True and dbg["init_error"] is None, dbg
    docs = {r["k"]: r for r in dbg["reads"]["docs"]}
    assert docs["board"]["rows"] == 6 and docs["state"]["rows"] == 1 and docs["state"]["chars"] == 15, docs
    assert max(r["longest"] for r in docs.values()) <= 16384, docs
    print("doc chunks: ok (a 230 KB state and an 85 KB board in 15 and 6 rows of at most 16384 characters, the same "
          "after a restart with pairs on the cuts; a shorter one drops its rows; kv's old rows never read; a failed "
          "start answers 503 and the next request serves, a storage error 503, bad JSON 400; /v1/debug behind the token)")


if __name__ == "__main__":
    main()

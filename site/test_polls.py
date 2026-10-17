#!/usr/bin/env python3
"""Polls on the site (Nick, d16 17:15): python3 site/test_polls.py

- worker.js's polls under node's SQLite (needs node 22): the operator creates (token only), viewers vote once per
  client and a later vote replaces the earlier one (the history kept for the voter log), the name and comment go
  through chat's rules (reserved names, links, length, bans, the per-client gap), a closed poll takes no votes, a
  hidden comment drops out while its vote counts, a banned voter's vote stops counting, the voter log and the ideas
  need the token, a viewer's idea is checked and never public;
- static/polls.js in a stub DOM (needs node): the live page's card votes, keeps the choice per browser, shows the
  results after voting, and says so when the API is down; with no poll open it shows one line linking the past polls
  (Nick d17 08:30), or nothing after a day; the /polls/ page lists open polls, then past polls collapsed to their
  question, close time and winner, with results and comments inside, and sends an idea.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
FIRST_POLL = os.path.join(os.path.dirname(SITE), "tools", "polls", "first-poll.json")  # the first poll, as the operator opens it
TOKEN = "x" * 20

WORKER_JS = r"""
// worker.js's polls under node:sqlite (argv[2]: worker.js). Prints the results.
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
const sql = { exec(q, ...params) {
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
let clock = 1792200000000;
Date.now = () => clock;
(async () => {
  const { Live } = await import(process.argv[2]);
  const ctx = { storage: { sql }, blockConcurrencyWhile: async (f) => f() };
  const live = new Live(ctx, { PUBLISH_TOKEN: '@TOK@' });
  await new Promise((r) => setTimeout(r, 10));
  const call = async (method, path, body, opts = {}) => {
    const headers = { 'x-client-ip': opts.ip || '1.2.3.4' };
    if (opts.token) headers.Authorization = 'Bearer ' + opts.token;
    const r = await live.fetch(new Request('https://api.test' + path, { method, headers, body: body == null ? undefined : JSON.stringify(body) }));
    return { status: r.status, body: await r.json() };
  };
  const tok = { token: '@TOK@' };
  const out = {};
  const Q = 'Should the AI team use blueprints made by people (viewers or the web)?';
  const OPTS = ['No: the team designs everything itself', 'Ideas only: people describe designs in words, no blueprint strings',
    'Study, then rebuild', 'Small pieces', 'Yes: any blueprint, credited on stream'];
  out.create_no_token = await call('POST', '/v1/polls', { question: Q, options: OPTS, hours: 12 });
  out.create_one_option = await call('POST', '/v1/polls', { question: Q, options: ['only'] }, tok);
  out.create_seven = await call('POST', '/v1/polls', { question: Q, options: ['a', 'b', 'c', 'd', 'e', 'f', 'g'] }, tok);
  out.create_same = await call('POST', '/v1/polls', { question: Q, options: ['a', 'A'] }, tok);
  out.create_hours = await call('POST', '/v1/polls', { question: Q, options: ['a', 'b'], hours: 100 }, tok);
  out.create_long_details = await call('POST', '/v1/polls', { question: Q, options: [{ label: 'a', details: 'x'.repeat(601) }, 'b'] }, tok);
  out.create_long_intro = await call('POST', '/v1/polls', { question: Q, intro: 'x'.repeat(801), options: ['a', 'b'] }, tok);
  const FIRST = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
  out.create = await call('POST', '/v1/polls', FIRST, tok);
  const id = out.create.body.poll.id;
  const V = (b, ip) => call('POST', `/v1/polls/${id}/vote`, b, { ip });
  out.v1 = await V({ option: 2, name: 'fan', comment: 'they should learn', cid: 'a'.repeat(24) }, '192.0.2.1');
  out.v1_again = await V({ option: 2, name: 'fan', comment: 'they should learn', cid: 'a'.repeat(24) }, '192.0.2.1');
  out.v2 = await V({ option: 0, name: 'other', comment: '' }, '192.0.2.2');
  out.v3_link = await V({ option: 1, name: 'spam', comment: 'see www.example.com' }, '192.0.2.3');
  out.v3_reserved = await V({ option: 1, name: 'Operator', comment: '' }, '192.0.2.3');
  out.v3_long = await V({ option: 1, name: 'long', comment: 'x'.repeat(201) }, '192.0.2.3');
  out.v3_bad_option = await V({ option: 5, name: 'bad' }, '192.0.2.3');
  out.v3 = await V({ option: 4, name: 'yes fan', comment: 'credit them' }, '192.0.2.3');
  out.gap = await V({ option: 3, name: 'fan', comment: 'changed my mind' }, '192.0.2.1');  // inside chat's 4 s gap
  clock += 5000;
  out.change = await V({ option: 3, name: 'fan', comment: 'changed my mind' }, '192.0.2.1');
  out.same = await V({ option: 3, name: 'fan', comment: 'changed my mind' }, '192.0.2.1');
  out.no_poll = await call('POST', '/v1/polls/99/vote', { option: 0, name: 'fan' }, { ip: '192.0.2.9' });
  // agents (./fh poll vote): the token, voter agent:NAME, one per agent, a later one replaces it, no viewer gap
  out.a_no_token = await V({ agent: 'grok', name: 'Grok', option: 0 }, '192.0.2.1');
  out.a_bad = await call('POST', `/v1/polls/${id}/vote`, { agent: 'no spaces!', option: 0 }, tok);
  out.a1 = await call('POST', `/v1/polls/${id}/vote`, { agent: 'grok', name: 'Grok', option: 0, comment: 'we build our own' }, tok);
  out.a2 = await call('POST', `/v1/polls/${id}/vote`, { agent: 'grok', name: 'Grok', option: 2, comment: 'study first' }, tok);
  out.a3 = await call('POST', `/v1/polls/${id}/vote`, { agent: 'haiku', name: 'Haiku', option: 2 }, tok);
  out.get = await call('GET', '/v1/polls');
  out.voters_no_token = await call('GET', `/v1/polls/${id}/voters`);
  out.voters = await call('GET', `/v1/polls/${id}/voters`, null, tok);
  // moderation: a hidden comment leaves the list, its vote still counts; a banned voter's vote stops counting
  const c3 = out.v3.body.vote.id;
  out.hide = await call('POST', '/v1/mod', { action: 'hide_comment', id: c3 }, tok);
  out.after_hide = await call('GET', '/v1/polls');
  out.ban = await call('POST', '/v1/mod', { action: 'ban_voter', id: c3 }, tok);
  out.after_ban = await call('GET', '/v1/polls');
  out.banned_vote = await V({ option: 1, name: 'yes fan' }, '192.0.2.3');
  out.banned_chat = await call('POST', '/v1/chat', { name: 'yes fan', text: 'hi' }, { ip: '192.0.2.3' });
  // void_vote (Nick d17 07:40): Haiku's vote stops counting, in the open poll and once it is closed
  out.void = await call('POST', '/v1/mod', { action: 'void_vote', id: out.a3.body.vote.id }, tok);
  out.after_void = await call('GET', '/v1/polls');
  // ideas: checked, rate limited, never public, the operator reads them with the token
  const S = (b, ip) => call('POST', '/v1/polls/suggest', b, { ip });
  out.idea_link = await S({ name: 'idea fan', question: 'Visit www.example.com?', options: ['a', 'b'] }, '192.0.2.17');
  out.idea_one = await S({ name: 'idea fan', question: 'Trains or belts?', options: ['trains'] }, '192.0.2.18');
  out.idea = await S({ name: 'idea fan', question: 'Trains or belts?', options: ['trains', 'belts'], hours: 6, cid: 'c'.repeat(24) }, '192.0.2.19');
  out.idea_again = await S({ name: 'idea fan', question: 'Trains or belts?', options: ['trains', 'belts'], hours: 6, cid: 'c'.repeat(24) }, '192.0.2.19');
  out.ideas_no_token = await call('GET', '/v1/polls/suggestions?after=0');
  out.ideas = await call('GET', '/v1/polls/suggestions?after=0', null, tok);
  out.get_after_idea = await call('GET', '/v1/polls');
  // closing: early by the operator, and by the clock
  out.close_no_token = await call('POST', `/v1/polls/${id}/close`, {});
  out.close = await call('POST', `/v1/polls/${id}/close`, {}, tok);
  out.vote_closed = await V({ option: 0, name: 'late' }, '192.0.2.7');
  const p2 = await call('POST', '/v1/polls', { question: 'Two?', options: ['a', 'b'], hours: 1 }, tok);
  clock += 3601 * 1000;
  out.timed_out = await call('POST', `/v1/polls/${p2.body.poll.id}/vote`, { option: 0, name: 'late' }, { ip: '192.0.2.8' });
  out.final = await call('GET', '/v1/polls');
  for (let i = 0; i < 4; i++) await call('POST', '/v1/polls', { question: 'Q' + i, options: ['a', 'b'] }, tok);
  out.fifth_open = await call('POST', '/v1/polls', { question: 'Q5', options: ['a', 'b'] }, tok);
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
""".replace("@TOK@", TOKEN)


def worker_tests():
    if not shutil.which("node"):
        print("polls: worker part skipped (no node)")
        return
    if subprocess.run(["node", "-e", "require('node:sqlite')"], capture_output=True).returncode != 0:
        print("polls: worker part skipped (node without node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "worker_polls.cjs")
        open(js, "w").write(WORKER_JS)
        r = subprocess.run(["node", "--no-warnings", js, "file://" + os.path.join(SITE, "worker", "worker.js"), FIRST_POLL],
                           capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    st = lambda k: o[k]["status"]
    err = lambda k: o[k]["body"].get("error", "")
    # creating: the token, 2-6 distinct options, at most 72 hours, at most 4 open
    assert st("create_no_token") == 401
    assert st("create_one_option") == 400 and st("create_seven") == 400 and "differ" in err("create_same"), o["create_seven"]
    assert st("create_hours") == 400
    assert "600" in err("create_long_details") and "800" in err("create_long_intro"), (o["create_long_details"], o["create_long_intro"])
    first = json.load(open(FIRST_POLL))
    poll = o["create"]["body"]["poll"]
    assert st("create") == 200 and poll["status"] == "open" and poll["left_s"] == 12 * 3600 and poll["counts"] == [0] * 5, poll
    assert poll["intro"] == first["intro"] and poll["options"] == [x["label"] for x in first["options"]], poll
    assert poll["details"] == [x["details"] for x in first["options"]]
    assert st("fifth_open") == 409, o["fifth_open"]
    # voting: one per client, a repeat of the same press is the same vote, chat's rules on the name and comment
    assert st("v1") == 200 and o["v1"]["body"]["vote"]["option"] == 2
    assert o["v1_again"]["body"].get("repeat") is True and o["v1_again"]["body"]["vote"]["id"] == o["v1"]["body"]["vote"]["id"]
    assert st("v2") == 200
    assert "links" in err("v3_link") and "reserved" in err("v3_reserved") and "200" in err("v3_long"), (o["v3_link"], o["v3_reserved"])
    assert st("v3_bad_option") == 400 and st("v3") == 200
    assert st("gap") == 429, o["gap"]
    assert st("change") == 200 and o["change"]["body"]["replaced"] is True and o["change"]["body"]["poll"]["counts"] == [1, 0, 0, 1, 1]
    assert o["same"]["body"].get("unchanged") is True
    assert st("a_no_token") == 401 and st("a_bad") == 400, (o["a_no_token"], o["a_bad"])
    assert st("a1") == 200 and o["a2"]["body"]["replaced"] is True and st("a3") == 200
    ap = o["a3"]["body"]["poll"]
    assert ap["viewer_counts"] == [1, 0, 0, 1, 1] and ap["agent_counts"] == [0, 0, 2, 0, 0] and ap["counts"] == [1, 0, 2, 1, 1], ap
    assert ap["viewer_total"] == 3 and ap["agent_total"] == 2 and ap["total"] == 5
    assert st("no_poll") == 404
    g = o["get"]["body"]
    assert len(g["open"]) == 1 and g["closed"] == [] and g["open"][0]["total"] == 5, g
    cm = g["open"][0]["comments"]
    assert [(c["name"], c["option"], c["comment"], c["agent"]) for c in cm] == [
        ("Grok", 2, "study first", True), ("fan", 3, "changed my mind", False), ("yes fan", 4, "credit them", False)], cm
    assert all("voter" not in c for c in cm) and "voter" not in json.dumps(g)  # no client hashes in public
    # the voter log: the token; every vote kept, the replaced one with current 0
    assert st("voters_no_token") == 401
    vs = o["voters"]["body"]["votes"]
    assert [(v["name"], v["option"], v["current"]) for v in vs] == [("fan", 2, 0), ("other", 0, 1), ("yes fan", 4, 1), ("fan", 3, 1),
                                                                      ("Grok", 0, 0), ("Grok", 2, 1), ("Haiku", 2, 1)], vs
    assert vs[5]["voter"] == "agent:grok" and vs[5]["agent"] is True and vs[0]["agent"] is False
    assert vs[0]["choice"] == first["options"][2]["label"] and vs[0]["voter"] == vs[3]["voter"] != vs[1]["voter"], vs
    # moderation
    p = o["after_hide"]["body"]["open"][0]
    assert [c["comment"] for c in p["comments"]] == ["study first", "changed my mind"] and p["counts"] == [1, 0, 2, 1, 1], p
    p = o["after_ban"]["body"]["open"][0]
    assert p["counts"] == [1, 0, 2, 1, 0] and p["viewer_total"] == 2 and p["agent_total"] == 2, p
    assert st("banned_vote") == 403 and st("banned_chat") == 403
    p = o["after_void"]["body"]["open"][0]
    assert st("void") == 200 and p["counts"] == [1, 0, 1, 1, 0] and p["agent_counts"] == [0, 0, 1, 0, 0] and p["total"] == 3, p
    # ideas
    assert "links" in err("idea_link") and st("idea_one") == 400
    assert st("idea") == 200 and o["idea_again"]["body"].get("repeat") is True
    assert st("ideas_no_token") == 401
    ideas = o["ideas"]["body"]["ideas"]
    assert [(i["name"], i["question"], i["options"], i["hours"]) for i in ideas] == [("idea fan", "Trains or belts?", ["trains", "belts"], 6)], ideas
    assert "Trains" not in json.dumps(o["get_after_idea"]["body"])
    # closing
    assert st("close_no_token") == 401 and st("close") == 200 and o["close"]["body"]["poll"]["status"] == "closed"
    assert st("vote_closed") == 403 and "closed" in err("vote_closed")
    assert st("timed_out") == 403
    f = o["final"]["body"]
    assert f["open"] == [] and [p["question"] for p in f["closed"]] == ["Two?", poll["question"]], f
    assert f["closed"][1]["counts"] == [1, 0, 1, 1, 0] and f["closed"][1]["total"] == 3 and f["closed"][1]["left_s"] == 0  # voided stays out


POLLS_JS = r"""
// static/polls.js in a stub DOM: argv[2] polls.js, argv[3] "card" | "card-closed" | "card-old" | "page" | "page-hash" |
// "down". Prints what happened.
const mode = process.argv[3];
global.location = { hash: mode === 'page-hash' ? '#poll-0' : '' };
const stored = {};
global.localStorage = { getItem: (k) => (k in stored ? stored[k] : null), setItem: (k, v) => { stored[k] = String(v); } };
function el(attrs) {
  const e = { _html: '', hidden: !!attrs.hidden, value: attrs.value || '', dataset: attrs.dataset || {}, on: {}, parentNode: attrs.parent || null,
    attrs: attrs.attrs || {}, kids: attrs.kids || {},
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    addEventListener(t, f) { (this.on[t] = this.on[t] || []).push(f); },
    querySelector(s) { return this.kids[s] || null; }, contains: () => true };
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = String(v); } });
  return e;
}
const list = el({});
const root = el({ hidden: true, dataset: { mode: mode.startsWith('card') ? 'card' : 'page', api: 'https://api.test' }, kids: { '.polls-list': list } });
const chatName = el({ value: 'fan_1' });
const ideaFields = {};
for (const n of ['name', 'question', 'option1', 'option2', 'option3', 'option4', 'option5', 'option6', 'hours']) ideaFields['[name=' + n + ']'] = el({});
ideaFields['.poll-idea-note'] = el({});
const idea = el({ kids: ideaFields });
global.document = { hidden: false, activeElement: null,
  getElementById: (id) => (id === 'polls' ? root : id === 'poll-idea' && !mode.startsWith('card') ? idea : null),
  querySelector: (s) => (s === '#vchat-form [name=name]' && mode.startsWith('card') ? chatName : null) };
global.window = global;
let realSetInterval = setInterval;
global.setInterval = () => 0;
const now = 1792200000;
const P1 = { id: 1, question: 'Should the AI team use blueprints made by people?', options: ['No', 'Ideas only', 'Study, then rebuild'],
  intro: 'Until today the agents designed their own builds.', details: ['Benefits: their own work.', '', 'Benefits: they learn & rebuild.'],
  counts: [3, 1, 0], total: 4, viewer_counts: [2, 1, 0], agent_counts: [1, 0, 0], viewer_total: 3, agent_total: 1, opens: now - 3600, closes: now + 11 * 3600, created_by: 'operator', status: 'open', left_s: 11 * 3600,
  comments: [{ id: 7, t: now - 60, name: 'joonazan', option: 0, comment: 'let them <b>learn</b>', agent: false },
    { id: 8, t: now - 30, name: 'Grok', option: 0, comment: 'we design our own', agent: true }] };
const P0 = { id: 0, question: 'Trains or belts?', options: ['Trains', 'Belts'], counts: [5, 2], total: 7, opens: now - 90000,
  closes: now - 3600, created_by: 'operator', status: 'closed', left_s: 0, comments: [{ id: 3, t: now - 7200, name: 'Foobator', option: 1, comment: 'belts forever' }] };
const PT = { id: 2, question: 'Nauvis or Vulcanus first?', options: ['Nauvis', 'Vulcanus'], counts: [2, 2], total: 4, opens: now - 200000,
  closes: now - 172800, created_by: 'operator', status: 'closed', left_s: 0, comments: [] };
const PN = { id: 3, question: 'Name the train?', options: ['Choo', 'Tchoo'], counts: [0, 0], total: 0, opens: now - 300000,
  closes: now - 259200, created_by: 'operator', status: 'closed', left_s: 0, comments: [] };
const OLD = Object.assign({}, P0, { closes: now - 2 * 86400 });
const posts = [];
let refuse = 1;
global.fetch = (url, opts) => {
  const ok = (body, good = true) => Promise.resolve({ ok: good, json: () => Promise.resolve(body) });
  if (mode === 'down') return Promise.reject(new Error('offline'));
  if (opts && opts.method === 'POST') {
    const body = JSON.parse(opts.body);
    posts.push({ url, body });
    if (url.endsWith('/vote')) {
      if (refuse-- > 0) return ok({ error: 'slow down', retry_after_s: 3 }, false);
      const p = Object.assign({}, P1, { counts: [3, 1, 1], total: 5, viewer_counts: [2, 1, 1], viewer_total: 4 });
      return ok({ ok: true, vote: { id: 9, option: body.option, name: body.name, comment: body.comment }, poll: p });
    }
    return ok({ ok: true });
  }
  if (mode === 'card-closed') return ok({ schema: 1, now, open: [], closed: [P0, PT] });
  if (mode === 'card-old') return ok({ schema: 1, now, open: [], closed: [OLD] });
  return ok({ schema: 1, now, open: [P1], closed: [P0, PT, PN] });
};
require(process.argv[2]);
const out = { posts };
const tick = (ms) => new Promise((r) => setTimeout(r, ms));
const art = el({ attrs: { 'data-poll': '1' }, parent: root, kids: { '[name=poll-comment]': el({ value: 'study first' }) } });
const click = (attrs) => (root.on.click || []).forEach((f) => f({ target: el({ attrs, parent: art }) }));
(async () => {
  await tick(20);
  out.first = list.innerHTML; out.hidden_first = root.hidden;
  if (mode === 'card') {
    click({ 'data-det': '2' }); out.toggled = list.innerHTML; await tick(1);
    (root.on.focusout || []).forEach((f) => f({})); await tick(5); out.toggled = list.innerHTML;  // a re-render keeps it open
    click({ 'data-vote': '2' });  // refused: slow down
    await tick(20);
    out.refused = list.innerHTML;
    click({ 'data-vote': '2' });  // again: the same message id
    await tick(20);
    out.voted = list.innerHTML; out.stored = stored;
    click({ 'data-change': '1' });
    out.changing = list.innerHTML;
  } else if (mode === 'page') {
    ideaFields['[name=name]'].value = 'idea fan'; ideaFields['[name=question]'].value = 'Trains or belts?';
    ideaFields['[name=option1]'].value = 'Trains'; ideaFields['[name=option2]'].value = 'Belts'; ideaFields['[name=hours]'].value = '6';
    (idea.on.submit || []).forEach((f) => f({ preventDefault() {} }));
    await tick(20);
    out.idea_note = ideaFields['.poll-idea-note'].textContent; out.idea_cleared = ideaFields['[name=question]'].value;
    click({ 'data-past': '0' }); (root.on.focusout || []).forEach((f) => f({})); await tick(5);
    out.past_clicked = list.innerHTML;  // opened by a click, kept open by the next render
  }
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
})();
"""


def page_tests():
    if not shutil.which("node"):
        print("polls: polls.js part skipped (no node)")
        return
    outs = {}
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "polls_page.cjs")
        open(js, "w").write(POLLS_JS)
        for mode in ("card", "card-closed", "card-old", "page", "page-hash", "down"):
            r = subprocess.run(["node", js, os.path.join(SITE, "static", "polls.js"), mode], capture_output=True, text=True, timeout=30)
            assert r.returncode == 0, r.stderr
            outs[mode] = json.loads(r.stdout)
    c = outs["card"]
    # the card: the open poll with its buttons and the time left, not the closed one; a link to the past polls
    assert c["hidden_first"] is False and "Should the AI team" in c["first"] and "Trains or belts" not in c["first"], c["first"]
    assert c["first"].count("data-vote=") == 3 and "11 h left" in c["first"] and 'href="/polls/"' in c["first"], c["first"]
    assert "poll-results" not in c["first"]  # no results before voting
    # the intro under the question; a details toggle per option that has details
    assert '<p class="poll-intro">Until today the agents designed their own builds.</p>' in c["first"], c["first"]
    assert c["first"].count('<details class="poll-det">') == 2 and "they learn &amp; rebuild" in c["first"]
    assert c["toggled"].count('<details class="poll-det" open>') == 1, c["toggled"]
    # a refused vote says why; the retry reuses the message id; the name is the chat box's
    assert "Slow down (try again in 3 s)." in c["refused"], c["refused"]
    v = [p["body"] for p in c["posts"]]
    assert [p["url"] for p in c["posts"]] == ["https://api.test/v1/polls/1/vote"] * 2
    assert v[0] == dict(v[1]) and v[0]["option"] == 2 and v[0]["name"] == "fan_1" and v[0]["comment"] == "study first", v
    assert len(v[0]["cid"]) == 24
    # voted: the results with the choice marked, kept per browser, and a way to change it
    assert "poll-results" in c["voted"] and "your vote" in c["voted"] and "data-vote=" not in c["voted"], c["voted"]
    assert "1 · 20%" in c["voted"] and "viewers 2 · agents 1" in c["voted"] and "4 from viewers, 1 from agents" in c["voted"]
    assert "Change my vote" in c["voted"] and json.loads(c["stored"]["pollVotes"]) == {"1": 2}
    assert c["stored"].get("chatName") == "fan_1"
    assert c["changing"].count("data-vote=") == 3 and "is-mine" in c["changing"]
    # the card with no poll open (Nick d17 08:30): one line, the last poll closed in the past day with its winner and a
    # link to the past polls; never the closed poll's results or buttons. Older than a day: nothing.
    cc = outs["card-closed"]["first"]
    assert outs["card-closed"]["hidden_first"] is False and cc.count("<p") == 1, cc
    assert cc == ('<p class="polls-past-line small"><a href="/polls/#past">Past polls</a> <span class="muted">· last: '
                  'Trains or belts? (won: Trains, 5 of 7 votes)</span></p>'), cc
    assert "poll-results" not in cc and "data-vote" not in cc and "Nauvis" not in cc
    assert outs["card-old"]["hidden_first"] is True and outs["card-old"]["first"] == "", outs["card-old"]
    # the page: open polls in full first, then "Past polls", each closed one a collapsed <details> whose summary has the
    # question, when it closed and the winner (a tie names both; none: no votes); results and comments inside, escaped
    pg = outs["page"]
    f = pg["first"]
    i_past = f.index('<h2 id="past">Past polls</h2>')
    assert "<h2>Open</h2>" in f[:i_past] and "Should the AI team" in f[:i_past] and "data-vote=" in f[:i_past], f
    assert "Trains or belts" not in f[:i_past] and "<h2>Closed</h2>" not in f
    assert '<li class="is-agent"><b>Grok</b> <span class="poll-ai">AI</span>' in f, f
    assert '<p class="poll-det-text small">Benefits: their own work.</p>' in f[:i_past] and "<details" not in f[:i_past]
    assert "let them &lt;b&gt;learn&lt;/b&gt;" in f and "<b>learn" not in f
    past = f[i_past:]
    assert past.count('<details class="poll-past"') == 3 and " open>" not in past, past
    assert ('<details class="poll-past" id="poll-0"><summary data-past="0"><span class="poll-past-q">Trains or belts?</span> '
            '<span class="poll-past-meta small muted">closed ') in past, past
    assert "· won: Trains, 5 of 7 votes</span></summary>" in past and "· tie: Nauvis / Vulcanus, 2 of 4 votes</span></summary>" in past
    assert "· no votes</span></summary>" in past
    d0 = past[past.index('id="poll-0"'):past.index("</details>")]
    assert "poll-results" in d0 and "5 · 71%" in d0 and "belts forever" in d0 and "POLL CLOSED" in d0, d0
    assert '<details class="poll-past" id="poll-0" open>' in pg["past_clicked"] and pg["past_clicked"].count(" open>") == 1
    # a link to /polls/#poll-0 opens that one
    ph = outs["page-hash"]["first"]
    assert '<details class="poll-past" id="poll-0" open>' in ph and '<details class="poll-past" id="poll-2">' in ph, ph
    assert pg["posts"] == [{"url": "https://api.test/v1/polls/suggest", "body": {
        "name": "idea fan", "question": "Trains or belts?", "options": ["Trains", "Belts"], "hours": 6, "cid": pg["posts"][0]["body"]["cid"]}}], pg["posts"]
    assert pg["idea_note"] == "Sent to the operator. Thanks." and pg["idea_cleared"] == ""
    # the API down: the page says so
    assert "Polls are unavailable right now." in outs["down"]["first"], outs["down"]


def main():
    worker_tests()
    page_tests()
    print("polls: ok (worker: create with the token, one vote per client replacing the last, chat's rules, hide and ban, "
          "a voided vote out of the counts, the voter log and ideas for the operator only, closing early and by the clock; the card "
          "shows open polls only (else one line to the past polls), /polls/ collapses past polls; vote, keep the choice, show "
          "results, send an idea, and say when the API is down)")


if __name__ == "__main__":
    main()

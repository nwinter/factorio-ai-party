import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Harness } from '../host/harness.js';
import { RconOutcomeUnknown, RconUnavailable } from '../host/rcon.js';

// Deterministic retry sequences: no sockets, wall-clock deadlines or real retry sleeps.
const unavailable = () => new RconUnavailable('connection failed');
const unknown = () => new RconOutcomeUnknown('answer lost');
const id = 'retry-state-action';
const success = JSON.stringify({id, ok:true, result:{built:1}});
const refusal = JSON.stringify({id, ok:false, error:{code:'refused', message:'no items'}});
const cases = [
  {name:'only unsent attempts remain unavailable', steps:[unavailable(), unavailable(), unavailable(), unavailable()], error:RconUnavailable},
  {name:'uncertainty survives every subsequent reconnect failure', steps:[unknown(), unavailable(), unavailable(), unavailable()], error:RconOutcomeUnknown},
  {name:'uncertainty can begin after an unsent attempt', steps:[unavailable(), unknown(), unavailable(), unavailable()], error:RconOutcomeUnknown},
  {name:'unverified replies cannot resolve uncertainty', steps:['{"id":"wrong","ok":true}', unavailable(), 'not JSON', unavailable()], error:RconOutcomeUnknown},
  {name:'a non-retryable failure cannot resolve uncertainty', steps:[unknown(), unavailable(), new Error('local failure')], error:RconOutcomeUnknown},
  {name:'a verified success resolves uncertainty', steps:[unknown(), unavailable(), unavailable(), success], reply:JSON.parse(success)},
  {name:'a verified refusal resolves uncertainty', steps:[unknown(), unavailable(), unavailable(), refusal], reply:JSON.parse(refusal)},
];
for (const scenario of cases) {
  test(scenario.name, async t => {
    const oldBudget = process.env.FH_RETRY_MS;
    process.env.FH_RETRY_MS = '4';
    t.after(() => { if (oldBudget === undefined) delete process.env.FH_RETRY_MS; else process.env.FH_RETRY_MS = oldBudget; });
    let now = 0;
    t.mock.method(Date, 'now', () => now);
    t.mock.method(globalThis, 'setTimeout', (done: () => void) => { queueMicrotask(done); });
    const sent: string[] = [];
    const harness = new Harness({async command(command) {
      sent.push(command);
      now++;
      const step = scenario.steps[sent.length - 1];
      assert.notEqual(step, undefined, 'no extra attempt');
      if (step instanceof Error) throw step;
      return step!;
    }});
    if (scenario.error) {
      await assert.rejects(harness.requestRetrying('build', {name:'stone-furnace'}, id), error => {
        assert.ok(error instanceof scenario.error!);
        if (error instanceof RconOutcomeUnknown) assert.match(error.message, /retry-state-action.*outcome unknown/);
        return true;
      });
    } else {
      const reply = await harness.requestRetrying('build', {name:'stone-furnace'}, id);
      const {retried, ...primary} = reply;
      assert.deepEqual(primary, scenario.reply);
      assert.equal(retried?.attempts, scenario.steps.length);
    }
    assert.equal(sent.length, scenario.steps.length);
    assert.equal(new Set(sent).size, 1, 'every retry keeps the same action, args, ID and wall stamp');
  });
}

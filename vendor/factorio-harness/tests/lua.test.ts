import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
for (const path of ['tests/scheduler.lua','tests/blueprints.lua','mod/tests/runtime_test.lua','mod/tests/control_test.lua','tests/threat.lua','tests/survey.lua','tests/conditions.lua','tests/route.lua','tests/pipes.lua','tests/rates.lua','tests/stock.lua','tests/space.lua','tests/travel.lua','tests/clock.lua','tests/chat.lua','tests/bots.lua','tests/crafting.lua','tests/board.lua','tests/construction.lua','tests/waits.lua','tests/labs.lua','tests/audience.lua','tests/tells.lua','tests/capsules.lua','tests/sleep.lua','tests/nametags.lua','tests/locals.lua']) {
  test(`Lua contract: ${path}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua',[path],{stdio:'pipe'});
  });
}

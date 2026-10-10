/** Opt-in real-engine tests. Every fixture mutation happens in a disposable save. */
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { access, cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import net from 'node:net';
import dgram from 'node:dgram';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { RconClient } from '../host/rcon.js';
import { Harness, luaString, type Reply } from '../host/harness.js';
import { bundleRuntime } from '../host/bundle.js';
import { renderMap } from '../host/view.js';
import { deflateSync, inflateSync } from 'node:zlib';

const root = process.cwd();
const binary = path.resolve(process.env.FACTORIO_BIN ?? '.cache/factorio/bin/x64/factorio');
await access(binary).catch(() => { throw new Error('Set FACTORIO_BIN to Factorio 2.0, or install official headless in .cache/factorio.'); });
await mkdir(path.join(root, '.cache/integration'), { recursive: true });
const directory = await mkdtemp(path.join(root, '.cache/integration/run-'));
const config = path.join(directory, 'config.ini');
const mods = path.join(directory, 'mods');
const save = path.join(directory, 'world.zip');
const settings = path.join(directory, 'server-settings.json');
const spaceAge = process.env.FACTORIO_TEST_SPACE_AGE === '1';
await mkdir(path.join(directory, 'write/saves'), { recursive: true });
await mkdir(mods);
await cp(path.join(root, 'mod/agent-harness_0.1.0'), path.join(mods, 'agent-harness_0.1.0'), { recursive: true });
await writeFile(path.join(mods, 'mod-list.json'), JSON.stringify({ mods: [
  { name: 'base', enabled: true }, { name: 'agent-harness', enabled: true },
  { name: 'space-age', enabled: spaceAge }, { name: 'quality', enabled: spaceAge }, { name: 'elevated-rails', enabled: spaceAge },
] }));
await writeFile(config, `[path]\nread-data=__PATH__executable__/../../data\nwrite-data=${directory}/write\n`);
const defaults = JSON.parse(await readFile(path.resolve(binary, '../../../data/server-settings.example.json'), 'utf8'));
await writeFile(settings, JSON.stringify({ ...defaults, name: 'agent-harness integration', visibility: { public: false, lan: false },
  require_user_verification: false, auto_pause: false, autosave_interval: 0, allow_commands: 'true' }));
const common = ['--config', config, '--mod-directory', mods];
let server: ChildProcess | undefined;
let creating: ChildProcess | undefined;
let graphical: ChildProcess | undefined;
let client: RconClient | undefined;
let log = '';
let gamePort = 0;
const appendLog = (chunk: Buffer) => { log += chunk.toString(); };

async function unusedPort(): Promise<number> {
  const listener = net.createServer();
  listener.listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const address = listener.address();
  assert(address && typeof address !== 'string');
  const port = address.port;
  await new Promise<void>((resolve, reject) => listener.close(error => error ? reject(error) : resolve()));
  return port;
}
async function unusedUdpPort(): Promise<number> {
  const socket = dgram.createSocket('udp4');
  socket.bind(0, '127.0.0.1');
  await once(socket, 'listening');
  const port = socket.address().port;
  await new Promise<void>(resolve => socket.close(() => resolve()));
  return port;
}
async function stop(child?: ChildProcess) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  child.kill('SIGTERM');
  const timer = setTimeout(() => child.kill('SIGKILL'), 5_000);
  await exited;
  clearTimeout(timer);
}
async function stopServer() {
  client?.close();
  client = undefined;
  await stop(graphical);
  graphical = undefined;
  await stop(server);
  await stop(creating);
}
const interrupt = () => { void stopServer().finally(() => process.exit(130)); };
process.once('SIGINT', interrupt);
process.once('SIGTERM', interrupt);
async function startServer(filename: string): Promise<Harness> {
  const port = await unusedPort();
  gamePort = await unusedUdpPort();
  const password = randomBytes(24).toString('hex');
  server = spawn(binary, [...common, '--start-server', filename, '--server-settings', settings,
    '--bind', `127.0.0.1:${gamePort}`, '--rcon-bind', `127.0.0.1:${port}`, '--rcon-password', password],
  { stdio: ['pipe', 'pipe', 'pipe'] });
  server.stdout!.on('data', appendLog);
  server.stderr!.on('data', appendLog);
  await once(server, 'spawn');
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    assert.equal(server.exitCode, null, 'Factorio exited before RCON became ready');
    client = new RconClient({ host: '127.0.0.1', port, password, timeoutMs: 10_000 });
    try {
      if ((await client.command('/silent-command rcon.print("ready")')).trim() === 'ready') return new Harness(client);
    } catch { client.close(); }
    await delay(100);
  }
  throw new Error('Factorio did not start RCON within 30 seconds');
}
async function fixture(source: string): Promise<string> {
  assert(client);
  return (await client.command(`/silent-command ${source}`)).trim();
}
function success(reply: Reply): any {
  assert.equal(reply.ok, true, JSON.stringify(reply));
  return reply.result;
}
async function idle(harness: Harness): Promise<any> {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const result = success(await harness.request('status'));
    if (!result.active && !result.combat) return result;
    await delay(100);
  }
  throw new Error('bounded action failed to finish');
}
async function itemCount(name: string): Promise<number> {
  return Number(await fixture(`rcon.print(game.get_player(1).get_item_count(${luaString(name)}))`));
}
async function gameplay(harness: Harness, clientBinary: string) {
  const clientWrite = path.join(directory, 'client');
  await mkdir(clientWrite);
  const clientConfig = path.join(directory, 'client-config.ini');
  await writeFile(clientConfig, `[path]\nread-data=__PATH__executable__/../../data\nwrite-data=${clientWrite}\n[general]\nmultiplayer-username=integration-agent\n`);
  graphical = spawn(path.resolve(clientBinary), ['--config', clientConfig, '--mod-directory', mods,
    '--port', String(await unusedUdpPort()), '--mp-connect', `127.0.0.1:${gamePort}`], { stdio: ['ignore', 'pipe', 'pipe'] });
  graphical.stdout!.on('data', appendLog);
  graphical.stderr!.on('data', appendLog);
  await once(graphical, 'spawn');
  console.log('Waiting for graphical client to join isolated integration server...');
  const deadline = Date.now() + 60_000;
  while ((await fixture('rcon.print(#game.connected_players)')) === '0') {
    assert.equal(graphical.exitCode, null, 'graphical client exited before connecting');
    assert(Date.now() < deadline, 'graphical client did not connect within 60 seconds');
    await delay(500);
  }
  assert.equal(await fixture(`local p=game.get_player(1); p.exit_cutscene(); if not p.character then p.create_character() end; p.cheat_mode=false; p.force.reset(); local s=game.create_surface("integration",{width=128,height=128}); s.request_to_generate_chunks({0,0},2); s.force_generate_chunk_requests(); for _,e in pairs(s.find_entities_filtered{area={{-12,-12},{12,12}}}) do e.destroy() end; local tiles={}; for x=-12,12 do for y=-12,12 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end; s.set_tiles(tiles); p.teleport({0,0},s); p.get_main_inventory().clear(); p.insert{name="iron-plate",count=20}; p.insert{name="copper-plate",count=10}; p.insert{name="wood",count=10}; p.insert{name="wooden-chest",count=2}; s.create_entity{name="iron-ore",position={0.5,2.5},amount=100}; rcon.print(p.index)`), '1');
  success(await harness.request('attach'));
  await delay(300); // Let the new surface become visible to the connected client.
  let observed: any;
  for (let attempt=0; attempt<30; attempt++) {
    observed = success(await harness.request('observe', { radius: 8, tiles: true }));
    if (Array.isArray(observed.entities) && observed.entities.some((entity: any) => entity.name === 'iron-ore')) break;
    await delay(100);
  }
  assert(Array.isArray(observed.entities) && observed.entities.some((entity: any) => entity.name === 'iron-ore'), 'local ore must become visible');
  assert.equal((await harness.request('walk', { direction: 'east', ticks: 601 })).ok, false);
  const ironBefore = await itemCount('iron-plate');
  const craft = await harness.request('craft', { recipe: 'iron-gear-wheel', count: 2 }, 'dedup-craft');
  assert.equal(success(craft).started, 2);
  assert.deepEqual(await harness.request('craft', { recipe: 'iron-gear-wheel', count: 2 }, 'dedup-craft'), craft);
  await delay(1_500);
  assert.equal(await itemCount('iron-gear-wheel'), 2, 'retry must not duplicate craft');
  assert.equal(await itemCount('iron-plate'), ironBefore - 4, 'craft must consume ingredients');
  const target = { position: { x: 2.5, y: 0.5 }, name: 'wooden-chest' };
  assert.equal(success(await harness.request('build', { item: 'wooden-chest', position: target.position })).consumed, 1);
  assert.equal(await itemCount('wooden-chest'), 1, 'build must consume one item');
  const deposit = { ...target, inventory: 'chest', item: 'iron-plate', count: 3, direction: 'to_entity' };
  assert.equal(success(await harness.request('transfer', deposit)).transferred, 3);
  assert.equal(await itemCount('iron-plate'), ironBefore - 7, 'partial deposit must move requested count');
  assert.equal(success(await harness.request('transfer', { ...deposit, count: 2, direction: 'to_player' })).transferred, 2);
  success(await harness.request('inspect', target));
  assert.equal((await harness.request('build', { item: 'wooden-chest', position: target.position })).ok, false);
  assert.equal(await itemCount('wooden-chest'), 1, 'blocked build must retain item');
  assert.equal(await fixture('local p=game.get_player(1); p.get_main_inventory().insert{name="repair-pack",count=1}; local e=p.surface.find_entity("wooden-chest",{2.5,0.5}); e.health=e.max_health-50; rcon.print("ready")'), 'ready');
  const damagedHealth = success(await harness.request('inspect', target)).health;
  success(await harness.request('repair', { ...target, ticks: 180 }));
  await idle(harness);
  assert(success(await harness.request('inspect', target)).health > damagedHealth, 'normal repair must restore health');
  assert.equal(await fixture('rcon.print(game.get_player(1).cursor_stack.valid_for_read)'), 'false', 'repair must restore borrowed cursor');
  const area = { left_top: { x: 2, y: 0 }, right_bottom: { x: 3, y: 1 } };
  assert.equal(success(await harness.request('copy', { area, slot: 'test' })).entities, 1);
  const exported = success(await harness.request('blueprint_export', { slot: 'test' })).blueprint;
  success(await harness.request('blueprint_import', { blueprint: exported, slot: 'imported' }));
  const ghosts = success(await harness.request('paste', { slot: 'imported', position: { x: 4.5, y: 0.5 } }));
  assert.equal(ghosts.count, 1);
  assert.equal(await itemCount('wooden-chest'), 1, 'blueprint metadata must not consume physical items');
  success(await harness.request('revive_ghost', { position: ghosts.ghosts[0].position }));
  assert.equal(await itemCount('wooden-chest'), 0, 'ghost construction must consume one chest');
  assert.equal(success(await harness.request('cut', { area })).marked, 1);
  assert.equal(success(await harness.request('cancel_deconstruction', { area })).changed, 1);
  const blueprint = JSON.parse(inflateSync(Buffer.from(exported.slice(1), 'base64')).toString());
  const book = (entry: any) => ({ blueprint_book: { item: 'blueprint-book', active_index: 0,
    version: blueprint.blueprint.version, blueprints: [{ index: 0, ...entry }] } });
  const bookString = '0' + deflateSync(Buffer.from(JSON.stringify(book(book(blueprint))))).toString('base64');
  assert.equal(success(await harness.request('blueprint_import', { blueprint: bookString, slot: 'book' })).kind, 'book');
  assert.equal(success(await harness.request('paste', { slot: 'book', book_path: [1, 1], position: { x: 4.5, y: 2.5 } })).count, 1);
  success(await harness.request('mine', { position: { x: 0.5, y: 2.5 }, name: 'iron-ore', ticks: 120 }));
  await idle(harness);
  assert((await itemCount('iron-ore')) > 0);
  const beforeWalk = success(await harness.request('status')).position;
  success(await harness.request('walk', { direction: 'west', ticks: 30 }));
  assert((await idle(harness)).position.x < beforeWalk.x - 1);
  await fixture('game.get_player(1).cheat_mode=true');
  assert.equal((await harness.request('observe')).ok, false, 'cheat mode requires explicit opt-in');
  success(await harness.request('attach', { allow_cheat_mode: true }));
  success(await harness.request('observe'));
  await fixture('game.get_player(1).cheat_mode=false');
  success(await harness.request('attach'));
  if (spaceAge) {
    assert.equal(await fixture('local p=game.get_player(1); p.get_main_inventory().insert{name="mech-armor",count=1}; p.insert{name="solar-panel-equipment",count=1}; rcon.print("ready")'), 'ready');
    assert.equal(success(await harness.request('equip', { slot: 'armor', item: 'mech-armor' })).equipped, 'mech-armor');
    const equipment = success(await harness.request('equipment', { operation: 'insert', item: 'solar-panel-equipment' }));
    assert.equal(equipment.inserted, 'solar-panel-equipment');
    assert.equal(await itemCount('solar-panel-equipment'), 0);
    success(await harness.request('observe'));
    success(await harness.request('equipment', { operation: 'remove', position: equipment.position }));
    assert.equal(await itemCount('solar-panel-equipment'), 1, 'equipment removal must return the item');
    console.log('PASS: Space Age mech armor, equipment insertion/removal, and explicit cheat-test mode boundary');
  }
  assert.equal(await fixture('local p=game.get_player(1); p.get_main_inventory().insert{name="firearm-magazine",count=20}; local e=p.surface.create_entity{name="small-biter",position={-8,0},force="enemy"}; e.active=false; rcon.print("ready")'), 'ready');
  success(await harness.request('equip', { slot: 'ammo', item: 'firearm-magazine' }));
  const queue = success(await harness.request('queue_submit', { steps: [
    { action: 'shoot', args: { auto: true, ticks: 120 }, wait: false },
    { action: 'walk', args: { direction: 'east', ticks: 30 } },
    { action: 'wait_ticks', args: { ticks: 120 } },
  ] }));
  assert.equal((await harness.request('queue_edit', { expected_revision: queue.revision - 1, index: 1, remove: 0, steps: [] })).ok, false);
  const queueDeadline = Date.now() + 10_000;
  let completed: any;
  do {
    await delay(100);
    completed = success(await harness.request('queue_status'));
    assert(Date.now() < queueDeadline, 'queue did not complete');
  } while (completed.active || Object.keys(completed.pending).length);
  assert.equal(completed.history.length, 3);
  assert(completed.history.every((entry: any) => entry.ok), JSON.stringify(completed));
  assert.equal(await fixture('rcon.print(game.get_player(1).surface.count_entities_filtered{name="small-biter",position={-8,0},radius=2})'), '0', 'queued shooting must kill the target normally');
  const finalObservation = success(await harness.request('observe', { radius: 12, tiles: true }));
  await writeFile(path.join(directory, 'observation.json'), JSON.stringify(finalObservation, null, 2));
  await writeFile(path.join(directory, 'observation.png'), renderMap(finalObservation, 12));
  success(await harness.request('screenshot', { path: 'integration.png', width: 640, height: 480 }));
  const screenshot = path.join(clientWrite, 'script-output/integration.png');
  let png = Buffer.alloc(0);
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      png = await readFile(screenshot);
      if (png.subarray(1, 4).toString() === 'PNG' && png.subarray(-8, -4).toString() === 'IEND') break;
    } catch { /* The renderer creates the file asynchronously. */ }
    await delay(100);
  }
  assert.equal(png.subarray(1, 4).toString(), 'PNG');
  assert.equal(png.subarray(-8, -4).toString(), 'IEND', 'screenshot must finish writing');
  await writeFile(path.join(directory, 'screenshot.png'), png);
  success(await harness.request('walk', { direction: 'east', ticks: 300 }));
  success(await harness.deploy(await bundleRuntime(path.join(root, 'mod/agent-harness_0.1.0/runtime.lua'))));
  assert.equal(success(await harness.request('status')).active, false);
  success(await harness.request('queue_submit', { steps: [
    { action: 'shoot', args: { auto: true, ticks: 600 }, wait: false },
    { action: 'walk', args: { direction: 'east', ticks: 600 } },
    { action: 'craft', args: { recipe: 'iron-gear-wheel', count: 1 } },
  ] }));
  await delay(100);
  assert.equal(await fixture('game.get_player(1).character.die(); rcon.print("dead")'), 'dead');
  await delay(200);
  const deadStatus = success(await harness.request('status'));
  assert.equal(deadStatus.alive, false);
  assert.equal(deadStatus.supported_control, false);
  assert.equal(deadStatus.active, false);
  assert.equal(deadStatus.combat, false);
  assert.equal(deadStatus.runtime_fault, false);
  const deadQueue = success(await harness.request('queue_status'));
  assert.equal(deadQueue.paused, true);
  assert.equal(deadQueue.active, false);
  assert.equal((await harness.request('walk', { direction: 'north', ticks: 30 })).ok, false);
  console.log('PASS: observation, craft/build costs, transfers, mining, repair, walking, blueprint books, ghost costs, combat, queues, screenshot, reload, death safety');
}

try {
  const creation = spawn(binary, [...common, '--create', save, '--map-gen-seed', '12345'], { stdio: ['ignore', 'pipe', 'pipe'] });
  creating = creation;
  creation.stdout.on('data', appendLog);
  creation.stderr.on('data', appendLog);
  const [code] = await once(creation, 'exit');
  creating = undefined;
  assert.equal(code, 0, 'disposable map creation failed');
  const harness = await startServer(save);
  const description = success(await harness.request('describe'));
  assert.equal(description.protocol, 1);
  const rejected = await harness.request('walk', { direction: 'east' }, 'cached-rejection');
  assert.equal(rejected.ok, false, 'missing player must fail safely');
  assert.deepEqual(await harness.request('walk', { direction: 'east' }, 'cached-rejection'), rejected);
  const collision = await harness.request('walk', { direction: 'west' }, 'cached-rejection');
  assert.equal(collision.ok, false, 'ID collision must be rejected');
  assert.equal(collision.error?.code, 'invalid_request');
  assert.match(collision.error.message, /id reused/);
  const source = await bundleRuntime(path.join(root, 'mod/agent-harness_0.1.0/runtime.lua'));
  success(await harness.deploy(source));
  assert.equal((await harness.deploy('this is not Lua')).ok, false);
  assert.deepEqual(success(await harness.request('describe')), description, 'failed deploy must preserve runtime');
  assert.deepEqual(await harness.request('walk', { direction: 'east' }, 'cached-rejection'), rejected, 'reload must retain deduplication');
  if (process.env.FACTORIO_CLIENT_BIN) await gameplay(harness, process.env.FACTORIO_CLIENT_BIN);
  else console.log('SKIP gameplay: set FACTORIO_CLIENT_BIN to a licensed graphical Factorio 2.0 client. Headless cannot attach a LuaPlayer character.');
  assert.equal(await fixture('game.server_save("persisted"); rcon.print("queued")'), 'queued');
  const persisted = path.join(directory, 'write/saves/persisted.zip');
  for (let attempt = 0; attempt < 100; attempt++) {
    try { await access(persisted); break; } catch { await delay(100); }
  }
  await access(persisted);
  await stopServer();
  const restored = await startServer(persisted);
  assert.deepEqual(success(await restored.request('describe')), description, 'deployed source must survive save/load');
  assert.deepEqual(await restored.request('walk', { direction: 'east' }, 'cached-rejection'), rejected, 'save/load must retain deduplication');
  console.log('PASS: real Factorio startup, RCON, protocol, unavailable-player rejection, cached retries, ID collision rejection, bundled hot reload, rollback, save/load');
} catch (error) {
  console.error(log.slice(-8_000));
  throw error;
} finally {
  process.removeListener('SIGINT', interrupt);
  process.removeListener('SIGTERM', interrupt);
  await stopServer();
  await writeFile(path.join(directory, 'factorio.log'), log);
  console.log(`Factorio integration evidence: ${directory}`);
}

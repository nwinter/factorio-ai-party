import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { dirname, basename, join } from 'node:path';
import { luaString, MAX_RUNTIME_BYTES } from './harness.js';
import { compactLua } from './compact.js';

/** Bundle sibling Lua modules into one atomic, save-persistent reload payload.
 * Standard require remains available for Factorio's libraries. */
// limit: false skips the deployment limit (d26 batch249: only compact.test.ts's size comparison builds the uncompacted
// text, which main had within 6 KB of the 8 MiB limit while the deployed, compacted bundle was 6.2 MB).
export async function bundleRuntime(path: string, options: {compact?: boolean, limit?: boolean} = {}): Promise<string> {
  // Comments and indentation are dropped (line breaks kept) unless compact is false.
  const shrink = options.compact === false ? (text: string) => text : compactLua;
  const folder = dirname(path);
  // control.lua is the transport; data-stage and settings files never run in the runtime.
  const skip = /^(control|data|data-updates|data-final-fixes|settings|settings-updates|settings-final-fixes)\.lua$/;
  const files = (await readdir(folder)).filter(file => file.endsWith('.lua') && !skip.test(file) && file !== basename(path)).sort();
  const preamble = `local original_require = require
local factories, loaded = {}, {}
local require
require = function(name)
  if loaded[name] ~= nil then return loaded[name] end
  local factory = factories[name]
  if not factory then return original_require(name) end
  loaded[name] = true
  local result = factory()
  if result ~= nil then loaded[name] = result end
  return loaded[name]
end
`;
  const modules = await Promise.all(files.map(async file =>
    `factories[ ${luaString(file.slice(0,-4))} ] = function()\n${shrink(await readFile(join(folder,file),'utf8'))}\nend\n`));
  // The runtime body gets its own function: Lua allows 200 locals per function, and the preamble's would count
  // against runtime.lua's (197 of 200 after the Space Age merge).
  const body = preamble + modules.join('') + `return (function()\n${shrink(await readFile(path,'utf8'))}\nend)()\n`;
  // The bundle's id (its content's hash), visible to every module and the runtime body as BUNDLE_ID: describe names
  // it, and fh help keeps one describe per id instead of pulling 280 KB from the game on each call. On the first line,
  // so line numbers in errors stay the bundle's own.
  const source = `local BUNDLE_ID = '${bundleId(body)}'; ` + body;
  if (options.limit !== false && Buffer.byteLength(source) > MAX_RUNTIME_BYTES) throw new Error(`Bundled runtime exceeds the ${MAX_RUNTIME_BYTES} byte deployment limit`);
  return source;
}
/** The first 16 hex digits of the bundle text's SHA-256. */
export function bundleId(source: string): string {
  return createHash('sha256').update(source).digest('hex').slice(0, 16);
}

import { readdir, readFile } from 'node:fs/promises';
import { dirname, basename, join } from 'node:path';
import { luaString } from './harness.js';
import { compactLua } from './compact.js';

/** What one runtime may be at most: control.lua's install cap (8 MiB, sent in
 * chunks). Worlds whose control.lua predates chunked installs take 512 KiB. */
export const MAX_RUNTIME_BYTES = 8 * 1024 * 1024;
export const LEGACY_INSTALL_BYTES = 524288;

/** Bundle sibling Lua modules into one atomic, save-persistent reload payload.
 * Standard require remains available for Factorio's libraries. */
export async function bundleRuntime(path: string, options: {compact?: boolean} = {}): Promise<string> {
  // Comments and indentation are dropped (line breaks kept) unless compact is false.
  const shrink = options.compact === false ? (text: string) => text : compactLua;
  const folder = dirname(path);
  const files = (await readdir(folder)).filter(file => file.endsWith('.lua') && file !== 'control.lua' && file !== basename(path)).sort();
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
  const source = preamble + modules.join('') + shrink(await readFile(path,'utf8'));
  if (Buffer.byteLength(source) > MAX_RUNTIME_BYTES) throw new Error(`Bundled runtime exceeds the ${MAX_RUNTIME_BYTES} byte deployment limit`);
  return source;
}

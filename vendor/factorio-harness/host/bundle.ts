import { readdir, readFile } from 'node:fs/promises';
import { dirname, basename, join } from 'node:path';
import { luaString } from './harness.js';

/** Bundle sibling Lua modules into one atomic, save-persistent reload payload.
 * Standard require remains available for Factorio's libraries. */
export async function bundleRuntime(path: string): Promise<string> {
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
    `factories[ ${luaString(file.slice(0,-4))} ] = function()\n${await readFile(join(folder,file),'utf8')}\nend\n`));
  const source = preamble + modules.join('') + await readFile(path,'utf8');
  if (Buffer.byteLength(source) > 524288) throw new Error('Bundled runtime exceeds 512 KiB deployment limit');
  return source;
}

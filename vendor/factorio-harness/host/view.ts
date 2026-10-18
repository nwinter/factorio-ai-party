import { deflateSync } from 'node:zlib';

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(name: string, data: Buffer): Buffer {
  const tag = Buffer.from(name);
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([tag, data])));
  return Buffer.concat([length, tag, data, crc]);
}
const colors: Record<string, number[]> = {
  'iron-ore': [103,158,199], 'copper-ore': [218,128,63], coal: [32,35,40],
  stone: [187,174,139], 'uranium-ore': [91,205,65], 'crude-oil': [172,67,188],
};
const platformColors: Record<string, number[]> = {
  'transport-belt':[194,162,62], 'underground-belt':[194,162,62], splitter:[194,162,62], inserter:[225,214,126],
  'assembling-machine':[77,154,160], 'solar-panel':[63,94,151], accumulator:[132,106,180],
  'electric-pole':[183,136,89], 'ammo-turret':[189,85,82], 'electric-turret':[189,85,82],
  pipe:[137,159,173], 'pipe-to-ground':[137,159,173], pump:[137,159,173], 'storage-tank':[108,128,142],
  thruster:[179,93,178], 'space-platform-hub':[209,202,177], 'asteroid-collector':[86,158,100],
};
/** Schematic of observed data only: no hidden world queries or game assets. */
export function renderMap(observation: any, radius = 24): Buffer {
  if (!Number.isInteger(radius) || radius < 1 || radius > 32) throw new Error('Map radius must be 1..32');
  const position = observation.position ?? observation.player?.position;
  if (!position || !Number.isFinite(position.x) || !Number.isFinite(position.y)) throw new Error('Observation has no player position');
  const scale = 8, size = (radius * 2 + 1) * scale;
  const rows = Buffer.alloc((size * 3 + 1) * size);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const i = y * (size * 3 + 1) + 1 + x * 3;
    rows[i] = 19; rows[i+1] = 25; rows[i+2] = 31;
  }
  const left = Math.floor(position.x) - radius, top = Math.floor(position.y) - radius;
  function square(x: number, y: number, color: number[], inset = 0) {
    const sx = Math.floor((x-left)*scale), sy = Math.floor((y-top)*scale);
    for (let dy = inset; dy < scale-inset; dy++) for (let dx = inset; dx < scale-inset; dx++) {
      const px = sx+dx, py = sy+dy;
      if (px < 0 || py < 0 || px >= size || py >= size) continue;
      const i = py*(size*3+1)+1+px*3;
      rows[i] = color[0]!; rows[i+1] = color[1]!; rows[i+2] = color[2]!;
    }
  }
  for (const tile of Object.values(observation.tiles ?? {}) as any[]) {
    square(tile.position.x, tile.position.y, tile.name === 'empty-space' ? [19,25,31] : tile.name === 'space-platform-foundation' ? [79,88,100] : /water|ocean/.test(tile.name) ? [30,75,115] : [59,72,48]);
  }
  for (const run of observation.tile_runs ?? []) {
    for (let x=run.x; x<run.x+run.count; x++) square(x,run.y,[79,88,100]);
  }
  for (const entity of Object.values(observation.entities ?? {}) as any[]) {
    // Out of sight (the harness's fog view): our buildings as last seen are drawn dim.
    if (entity.remembered) { square(entity.position.x, entity.position.y, [120,110,80], 1); continue; }
    const color = (observation.platform && entity.ghost ? [97,168,211] : undefined) ??
      (observation.platform ? platformColors[entity.type] : undefined) ?? colors[entity.name] ?? (entity.ghost ? [97,168,211] :
      entity.type === 'tree' ? [37,119,55] : entity.type === 'unit' || entity.type === 'unit-spawner' ? [224,65,62] : [203,185,114]);
    const box = observation.platform && entity.box;
    if (box?.left_top && box?.right_bottom) {
      const x0=Math.floor((box.left_top.x-left)*scale), y0=Math.floor((box.left_top.y-top)*scale);
      const x1=Math.ceil((box.right_bottom.x-left)*scale), y1=Math.ceil((box.right_bottom.y-top)*scale);
      for (let y=Math.max(0,y0); y<Math.min(size,y1); y++) for (let x=Math.max(0,x0); x<Math.min(size,x1); x++) {
        const border=x===x0 || x===x1-1 || y===y0 || y===y1-1;
        const i=y*(size*3+1)+1+x*3;
        for (let c=0;c<3;c++) rows[i+c]=border ? 24 : color[c]!;
      }
    } else square(entity.position.x, entity.position.y, color, 1);
  }
  // Ours lost out of sight: a red outline where each stood.
  for (const lost of observation.fog?.lost ?? []) {
    const sx = Math.floor((lost.position.x-left)*scale), sy = Math.floor((lost.position.y-top)*scale);
    for (let d = 0; d < scale; d++) for (const [px, py] of [[sx+d,sy],[sx+d,sy+scale-1],[sx,sy+d],[sx+scale-1,sy+d]]) {
      if (px! < 0 || py! < 0 || px! >= size || py! >= size) continue;
      const i = py!*(size*3+1)+1+px!*3;
      rows[i] = 224; rows[i+1] = 65; rows[i+2] = 62;
    }
  }
  if (!observation.platform) square(Math.floor(position.x), Math.floor(position.y), [250,250,255]);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size,0); header.writeUInt32BE(size,4); header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR',header), chunk('IDAT',deflateSync(rows)), chunk('IEND',Buffer.alloc(0))]);
}

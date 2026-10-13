// Terrain layer for the site's map viewers (site/terrain.py publishes /terrain/index.json): georeferenced frames of
// the game's own map view, drawn under the buildings. A viewer that maps tiles to its SVG units with a translate and a
// scale draws them with one call:
//
//   PogTerrain.load().then(function (index) { ... });             // fetched once, then cached (null: no terrain)
//   PogTerrain.svg(index, { x: tx, y: ty, k: k, tick: t })        // '<g class="terrain">...</g>', '' when none
//
// where (tx(x), ty(y)) are the SVG coordinates of tile (x, y), k SVG units per tile, and tick (optional) the moment
// shown: the newest frame per area at or before it (the time-lapse); without it, the newest of each area.
(function () {
  var cache = null;
  function load(url) {
    if (!cache) {
      cache = fetch(url || '/terrain/index.json').then(function (r) { return r.ok ? r.json() : null; })
        .then(function (d) { return d && Array.isArray(d.frames) && d.frames.length ? d : null; })
        .catch(function () { return null; });
    }
    return cache;
  }
  function pick(index, tick, surface) {
    if (!index || !Array.isArray(index.frames)) return [];
    var byArea = {}, order = [];
    index.frames.forEach(function (f) {
      if ((f.surface || 'nauvis') !== (surface || 'nauvis')) return;
      if (tick != null && f.tick != null && f.tick > tick) return;
      var key = Math.floor((f.x + f.w / 2) / 256) + ',' + Math.floor((f.y + f.h / 2) / 256);
      if (!(key in byArea)) order.push(key);
      if (!byArea[key] || (f.tick || 0) >= (byArea[key].tick || 0)) byArea[key] = f;
    });
    return order.map(function (k) { return byArea[k]; }).sort(function (a, b) { return (a.tick || 0) - (b.tick || 0); });
  }
  function num(v) { return (+v).toFixed(2); }
  function attr(s) { return String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;'); }
  function svg(index, view) {
    var list = pick(index, view && view.tick, view && view.surface);
    if (!list.length) return '';
    var k = view.k;
    return '<g class="terrain" aria-hidden="true">' + list.map(function (f) {
      return '<image href="' + attr(f.src) + '" x="' + num(view.x(f.x)) + '" y="' + num(view.y(f.y)) + '" width="' + num(f.w * k) +
        '" height="' + num(f.h * k) + '" preserveAspectRatio="none" decoding="async"/>';
    }).join('') + '</g>';
  }
  window.PogTerrain = { load: load, pick: pick, svg: svg };
})();

/* Caster portraits for the stream's hosts, drawn by avatar.js like the agents' own avatars.
 *
 * Keys are caster.py's caster keys ("pbp", "color"). Every part, the colour and the accent are set explicitly, and
 * no backdrop here depends on the name, so renaming a caster is a one-word edit that leaves the portrait as it is.
 * A new host is one more entry; any avatar.js part works (the headset is the hosts' signature).
 *
 * Browser: <script src="avatar.js"></script><script src="casters.js"></script>
 *          PogCasters.svg("pbp", 48)          PogCasters.row("pbp") -> a profiles-style row for PogAvatar
 * Node:    require("./casters.js")            Python: tools/stream/avatar.py --casters (reads this file)
 */
(function (root) {
  "use strict";

  // Strict JSON between the markers (read by tools/stream/avatar.py).
  /*@casters*/
  var CASTERS = {
    "pbp": {"name": "Rook", "role": "play-by-play", "color": "#ff6b35",
            "avatar": {"base": "engineer", "helmet": "none", "visor": "none", "emblem": "bolt",
                       "accessory": "headset", "backdrop": "hazard", "accent": "#ffd23f"}},
    "color": {"name": "Vale", "role": "colour", "color": "#2fb7a8",
              "avatar": {"base": "engineer", "helmet": "none", "visor": "mono", "emblem": "leaf",
                         "accessory": "headset", "backdrop": "glow", "accent": "#ff9e8a"}}
  };
  /*@end*/

  function row(key) {
    var c = CASTERS[key];
    if (!c) return null;
    return { name: c.name, display_name: c.name, color: c.color, avatar: c.avatar, role: c.role, kind: "caster" };
  }
  function svg(key, size, opts) {
    var A = root.PogAvatar || (typeof require === "function" ? require("./avatar.js") : null);
    var r = row(key);
    return r && A ? A.svg(r, size, opts) : "";
  }
  // Look a caster up by its display name too ("Rook"), for captions that only carry the speaker's name.
  function byName(name) {
    var n = String(name || "").toLowerCase();
    for (var k in CASTERS) if (CASTERS[k].name.toLowerCase() === n) return k;
    return null;
  }

  var api = { CASTERS: CASTERS, keys: Object.keys(CASTERS), row: row, svg: svg, byName: byName };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.PogCasters = api;
})(typeof globalThis !== "undefined" ? globalThis : this);

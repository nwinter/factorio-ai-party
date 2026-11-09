/* Shared by the overlay and live site. The server parses target.json's timezone;
   browsers count wall time, independently of game ticks, pauses and shift clocks. */
(function (root) {
  'use strict';
  var STALE_SECONDS = 90;
  function valid(t) {
    return !!t && typeof t.goal === 'string' && !!t.goal.trim() &&
      typeof t.at_epoch === 'number' && Number.isFinite(t.at_epoch);
  }
  function duration(seconds) {
    var minutes = Math.floor(Math.max(0, seconds) / 60);
    return minutes >= 60 ? Math.floor(minutes / 60) + ' h ' + minutes % 60 + ' min' : minutes + ' min';
  }
  function label(t, now) {
    if (!valid(t)) return '';
    var left = t.at_epoch - now;
    return left > 0 ? 'Final push in ' + (left < 60 ? '< 1 min' : duration(left)) :
      'Final push under way · ' + duration(-left) + ' elapsed';
  }
  function create(node) {
    var target = null, received = 0;
    function render() {
      if (!node) return;
      var text = label(target, Date.now() / 1000);
      node.hidden = !text || Date.now() - received > STALE_SECONDS * 1000;
      if (node.hidden) {
        node.textContent = '';
        node.removeAttribute('title');
        return;
      }
      // Separate clock and goal lines keep the clock visible even for long goals.
      if (!node.firstChild) {
        var clock = document.createElement('strong'), goal = document.createElement('span');
        clock.className = 'target-clock'; goal.className = 'target-goal';
        node.appendChild(clock); node.appendChild(goal);
      }
      node.firstChild.textContent = text;
      node.lastChild.textContent = target.goal.trim();
      node.title = text + ' · ' + target.goal.trim() + (typeof target.at === 'string' ? ' · ' + target.at : '');
    }
    var timer = setInterval(render, 1000);
    return {
      update: function (value, age) {
        target = valid(value) ? value : null;
        received = Date.now() - Math.max(0, Number(age) || 0) * 1000;
        render();
      },
      destroy: function () { clearInterval(timer); target = null; render(); }
    };
  }
  var api = {label: label, create: create, STALE_SECONDS: STALE_SECONDS};
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.PogTargetCountdown = api;
})(typeof window !== 'undefined' ? window : this);

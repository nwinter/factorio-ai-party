// One phase for countdowns, startup/save labels and recap headings. Clock time
// can make a handover overdue; only records/Operator announcements confirm it.
(function (root) {
  function notice(m) {
    if (!m || m.op !== true || !Number.isFinite(m.t)) return null;
    var t = m.text || '', n, phase;
    if ((n = /(?:handover began; |is over; )shift (\d+) (?:is starting|starts in about)/i.exec(t))) phase = 'starting';
    else if ((n = /^Shift (\d+) is live\b/i.exec(t))) phase = 'live';
    else if ((n = /^The start of shift (\d+) has hit a problem/i.exec(t))) phase = 'failed';
    else if ((n = /^The start of shift (\d+) is taking longer/i.exec(t))) phase = 'starting';
    else if ((n = /^Shift (\d+) is running with degraded/i.exec(t))) phase = 'live';
    return phase ? { number: +n[1], phase: phase, t: m.t } : null;
  }
  function resolve(sh, now, messages) {
    if (!sh || !Number.isFinite(sh.end)) return null;
    var final = sh.next === null, number = sh.number, phase;
    if (sh.save_state === 'failed') phase = 'failed';
    else if (sh.stopped) { phase = final ? 'ended' : 'starting'; if (!final && number != null) number++; }
    else if (now >= sh.end) phase = 'pending';
    else phase = sh.started === true ? 'live' : sh.started === false ? 'starting' : 'unknown';
    var events = (messages || []).map(notice).filter(function (e) {
      return e && e.t >= sh.start && e.t <= now &&
        (e.number === number || (!final && e.number === number + 1));
    }).sort(function (a, b) { return a.t - b.t; });
    var e = events[events.length - 1];
    // A current shift's old live notice cannot undo its later deadline/stop.
    if (e && !(final && sh.stopped) && !(e.number === sh.number && (sh.stopped || now >= sh.end) && e.phase === 'live')) {
      phase = e.phase; number = e.number;
    }
    return { phase: phase, number: number, final: final, overdue: Math.max(0, Math.floor((now - sh.end) / 60)),
      save: sh.save_state === 'confirmed' ? 'save confirmed' : sh.save_state === 'failed' ? 'save failed' : 'save not confirmed',
      same: number === sh.number };
  }
  function label(p) {
    if (!p) return '';
    var who = p.number == null ? 'Shift' : 'Shift ' + p.number;
    return p.phase === 'ended' ? 'Run ended' : p.phase === 'pending' ?
      (p.final ? 'Run end pending' : 'Handover pending') + ' · overdue ' + p.overdue + ' min' :
      p.phase === 'starting' ? who + ' starting' : p.phase === 'failed' ?
      (p.final ? 'Run end failed' : 'Handover failed · ' + who + ' not confirmed up') :
      p.phase === 'live' ? who + ' live' : 'Shift status unconfirmed';
  }
  var api = { resolve: resolve, label: label, notice: notice };
  root.PogShiftPhase = api;
  if (typeof module !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);

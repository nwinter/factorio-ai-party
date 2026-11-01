"""Overlay stacking shared by scene builders, cuts, and the read-only watchdog.

OBS indices run bottom to top. Never infer them from the response's array order.
"""
OVERLAYS = ('stream overlay', 'vertical overlay')


def overlay_ids(items, names=OVERLAYS):
    return [r['sceneItemId'] for r in sorted(items, key=lambda r: r['sceneItemIndex']) if r['sourceName'] in names]


def overlays_last(ids, overlays):
    """Keep the relative order of every other item; overlay items go above all of them."""
    over = set(overlays)
    return [i for i in ids if i not in over] + [i for i in ids if i in over]


def raise_overlays(items, set_index, names=OVERLAYS):
    """Move only overlay items, using a caller-supplied setter; never enable or recreate anything."""
    cur = [r['sceneItemId'] for r in sorted(items, key=lambda r: r['sceneItemIndex'])]
    over = overlay_ids(items, names)
    if not over or cur[-len(over):] == over:
        return over
    for iid in over:
        if cur[-1] != iid:
            set_index(iid, len(cur) - 1)
            cur.remove(iid)
            cur.append(iid)
    return over


def report(items, scene, name='stream overlay'):
    """Strict top-enabled-item policy, including audio-only items as requested by the operator."""
    rows = sorted(items, key=lambda r: r['sceneItemIndex'])
    overlay = next((r for r in reversed(rows) if r['sourceName'] == name and r.get('sceneItemEnabled', True)), None)
    enabled = [r for r in rows if r.get('sceneItemEnabled', True)]
    result = {'scene': scene, 'overlay': name, 'ok': False,
              'top_enabled': enabled[-1]['sourceName'] if enabled else None}
    if overlay is None:
        result['reason'] = 'disabled' if any(r['sourceName'] == name for r in rows) else 'missing'
        return result
    above = [r for r in enabled if r['sceneItemIndex'] > overlay['sceneItemIndex']]
    result.update(ok=not above, reason='covered' if above else 'top', index=overlay['sceneItemIndex'],
                  above=[{'name': r['sourceName'], 'index': r['sceneItemIndex'], 'kind': r.get('inputKind')} for r in above])
    return result


def read_program(call):
    """Exactly two OBS reads. No source/scene changes or recovery actions."""
    program = call('GetCurrentProgramScene')
    scene = program.get('currentProgramSceneName') or program.get('sceneName')
    if not scene:
        raise ValueError('OBS did not name the program scene')
    items = call('GetSceneItemList', {'sceneName': scene})['sceneItems']
    return report(items, scene)


def line(result):
    if result is None:
        return None, False
    if result.get('error'):
        return 'overlay order UNKNOWN: ' + result['error'], True
    scene, overlay = result['scene'], result['overlay']
    if result['ok']:
        return f'overlay order: {overlay} is top enabled item in {scene}', False
    if result['reason'] in ('missing', 'disabled'):
        return f'overlay order NOT top: {overlay} {result["reason"]} in program scene {scene}', True
    above = ', '.join(f'{r["name"]} (index {r["index"]})' for r in result['above'])
    return f'overlay order NOT top: {overlay} at {result["index"]} in program scene {scene}; above: {above}', True

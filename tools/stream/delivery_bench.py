#!/usr/bin/env python3
"""Render a small delivery audition to --out (never pushes audio or contacts the stream service).

Uses configured TTS keys, and the normal recap writer when --recap-writer is set. Captures request
bodies only, never headers/keys. For the offline matrix use test_delivery.py --capture PATH.
"""
import argparse
import html
import json
import os
from pathlib import Path

import voices
import shift_recap


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--recap-writer', action='store_true')
    ap.add_argument('--resume', action='store_true', help='reuse already rendered samples in --out')
    ap.add_argument('--openai-model', choices=voices.OPENAI_TTS_MODELS, default=voices.DEFAULT_OPENAI_TTS_MODEL)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    # Keep the audition isolated from live caches; simple fixture text needs no spacing model.
    os.environ['POG_RESPACE'] = '0'
    os.environ['POG_TTS_CACHE'] = ''
    requests, samples = [], []
    if args.resume:
        requests = shift_recap.read_json(args.out / 'request-payloads-real.json', [])
        samples = shift_recap.read_json(args.out / 'samples.json', [])
    current = None
    real_http = voices._http
    injected = False

    def capture(method, url, headers, body=None, timeout=45):
        nonlocal injected
        inject = current == 'host-vale-timeout-plain' and not injected
        requests.append({'sample': current, 'mode': 'real', 'endpoint': url,
                         'keys': sorted(body or {}), 'body': body})
        if inject:
            requests[-1]['mode'] = 'injected-timeout-before-send'
            injected = True
            raise TimeoutError('audition timeout injection')
        return real_http(method, url, headers, body, timeout)

    voices._http = capture
    tts = voices.TTS('auto', openai_model=args.openai_model)
    real_run = tts.ai.run

    def cf_capture(model, inputs, **kw):
        requests.append({'sample': current, 'mode': 'real', 'endpoint': 'workers-ai:' + model,
                         'keys': sorted(inputs), 'body': inputs})
        return real_run(model, inputs, **kw)

    tts.ai.run = cf_capture

    def save():
        (args.out / 'request-payloads-real.json').write_text(json.dumps(requests, indent=2) + '\n')
        (args.out / 'samples.json').write_text(json.dumps(samples, indent=2) + '\n')

    jobs = [
        ('host-rook-directed', 'atlas', 'pbp', 'The wall has held all shift. The team can breathe again.', 'slow and calm.'),
        ('host-rook-natural', 'atlas', 'pbp', 'The wall has held all shift. The team can breathe again.', None),
        ('host-vale-directed', 'thalia', 'color', 'The wall has held all shift. The team can breathe again.', 'warm, measured, relieved.'),
        ('host-vale-timeout-plain', 'thalia', 'color', 'The wall has held all shift. The team can breathe again.', 'quick and excited.'),
        ('agent-eleven', 'el-george', None, 'I have sorted the chests by colour. Nobody asked. You are welcome.', 'dry and amused.'),
        ('agent-openai', 'oa-cedar', None, 'The train is still waiting. I am checking the signal.', None),
        ('agent-aura', 'orion', None, 'The train is still waiting. I am checking the signal.', 'slow and calm.'),
    ]
    for name, voice, role, text, direction in jobs:
        if any(row['name'] == name and row.get('asset') and (args.out / row['asset']).is_file()
               and row.get('openai_model', voices.DEFAULT_OPENAI_TTS_MODEL) == args.openai_model for row in samples):
            continue
        current = name
        row = dict(name=name, text=text, direction=direction, requested_voice=voice, role=role,
                   openai_model=args.openai_model)
        try:
            data, ctype, duration, latency = tts.speak(text, voice, caster=role, direction=direction)
            suffix = '' if args.openai_model == voices.DEFAULT_OPENAI_TTS_MODEL else '-' + args.openai_model
            path = args.out / (name + suffix + '.mp3')
            path.write_bytes(data)
            row.update(asset=path.name, duration=duration, latency=latency, actual=tts.last_here(),
                       loudness=voices.loudness(str(path)))
        except Exception as exc:
            row['error'] = type(exc).__name__
        samples.append(row)
        save()
        print(name, row.get('actual', row.get('error')), flush=True)

    if args.recap_writer:
        import hourly
        if not hourly.openrouter_key():
            raise RuntimeError('recap writer key unavailable')
        # Clearly fictional audition evidence; production gathers the shift's own records.
        evidence = {'run': 'delivery-audition', 'partial': True, 'rows': [
            {'id': 'a', 'kind': 'research', 'text': 'Research finished: logistics 2.',
             'source': 'audition fixture', 'row': 1, 't': 1000, 'weight': 5},
            {'id': 'b', 'kind': 'chat', 'text': 'Sol reported sorting the station chests by colour.',
             'source': 'audition fixture', 'row': 2, 't': 1001, 'weight': 5}]}
        script, audit = shift_recap.write_script(evidence, hourly.make_writer(hourly.MODEL), args.out / 'recap-audit')
        shift_recap.save_json(args.out / 'recap-script.json', dict(evidence=evidence, lines=script, audit=audit))
        for index, line in enumerate(script[:2]):
            current = f'recap-{index + 1}'
            row = shift_recap.render_lines([line], args.out / 'recap', tts)[0]
            path = args.out / 'recap' / 'assets' / row['asset']
            samples.append(dict(name=current, **line, asset=str(path.relative_to(args.out)),
                                duration=row['duration'], actual=tts.last_here(),
                                loudness=voices.loudness(str(path))))
            save()
            print(current, tts.last_here(), flush=True)

    cards = []
    for row in samples:
        cards.append('<h2>' + html.escape(row['name']) + '</h2><p>' + html.escape(row['text']) +
                     '</p><p>Direction: ' + html.escape(row.get('direction') or 'natural') + '</p>' +
                     ('<audio controls src="' + html.escape(row['asset']) + '"></audio>' if row.get('asset') else
                      '<p>Render failed: ' + html.escape(row['error']) + '</p>'))
    (args.out / 'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Delivery audition</title>'
        '<h1>Batch389 delivery audition</h1><p>Synthetic examples; not stream events.</p>' + ''.join(cards))


if __name__ == '__main__':
    main()

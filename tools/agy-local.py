#!/usr/bin/env python3
"""Agy stream adapter: resume only this workspace's ID, without shared indexes."""
import json
import os
from pathlib import Path
import subprocess
import sys

def main():
    folder=Path.cwd();marker=folder/'.agy-session.json';args=sys.argv[1:]
    if '-c' in args or '--continue' in args:
        args=[a for a in args if a not in ('-c','--continue')]
        if marker.exists():args=['--conversation',json.loads(marker.read_text())['id'],*args]
    p=subprocess.Popen([str(Path.home()/'.local/bin/agy'),'--output-format','stream-json',*args],stdout=subprocess.PIPE,text=True)
    state={}; response=[]
    for line in p.stdout:
        try:row=json.loads(line)
        except ValueError:
            print(line,end='',flush=True);continue
        if row.get('event')=='init':
            state={'id':row['conversation_id']};marker.write_text(json.dumps(state)+'\n')
        update=row.get('step_update') or {}
        if update.get('text_delta'):
            print(update['text_delta'],end='',flush=True);response.append(update['text_delta'])
        result=row.get('result') or {}
        usage=result.get('usage') or update.get('usage')
        if usage and state:
            state['tokens']=usage.get('input_tokens',0)+usage.get('cache_read_tokens',0)
            marker.write_text(json.dumps(state)+'\n')
        if result.get('response') and not response:print(result['response'],flush=True)
        if row.get('event')=='error':print(json.dumps(row),file=sys.stderr,flush=True)
    return p.wait()

if __name__=='__main__':sys.exit(main())

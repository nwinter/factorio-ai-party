#!/usr/bin/env python3
"""Operator-only mapping from coloured forces to separate anonymous agent trees."""
import argparse
import json
from pathlib import Path
import secrets
import subprocess

def prepare(root,template,run,teams):
    root,template=root.resolve(),template.resolve()
    assert run and '/' not in run and not run.startswith('.'),'a plain run ID is required'
    assert run.lower() not in {t.lower() for t in teams},'run ID must not be a force name'
    op=root/'runs'/run/'op';manifest=op/'workspaces.json'
    assert not manifest.exists(),'workspaces already allocated'
    paths={}
    for team in teams:
        tree=template.parent/('play-'+secrets.token_hex(4))
        tree.mkdir()
        subprocess.run(['rsync','-a','--exclude=/runs/',str(template)+'/',str(tree)+'/'],check=True)
        folder=tree/'runs'/run;folder.mkdir(parents=True)
        # The coloured index exists only in the operator checkout, denied to every agent.
        (root/'runs'/run/team).symlink_to(folder,target_is_directory=True)
        paths[team]={'tree':str(tree),'dir':str(folder)}
        manifest.write_text(json.dumps(paths,indent=2)+'\n')
    (op/'launch-tree').write_text(str(root)+'\n')
    return paths

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);p.add_argument('template',type=Path)
    p.add_argument('run');p.add_argument('teams',nargs='+');a=p.parse_args()
    prepare(a.root,a.template,a.run,a.teams)

if __name__=='__main__':main()

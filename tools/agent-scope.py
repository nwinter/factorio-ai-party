#!/usr/bin/env python3
"""Start a prepared game client with only its own project files and a clean environment.

Keeps native login state and applies one macOS filesystem/network scope to the
client and its child tools. Project listings and shared personal state are denied.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from urllib.parse import urlparse

KEEP={'PATH','HOME','USER','LOGNAME','SHELL','TMPDIR','LANG','LC_ALL','TERM','COLORTERM','TZ','__CF_USER_TEXT_ENCODING'}

def environment(env):
    return {k:v for k,v in env.items() if k in KEEP}

def profile(root,home,proxy=None,native=None):
    quote=json.dumps
    protected=[home/'code',home/'Dropbox',home/'Dropbox (Personal)']
    clauses=['(version 1)','(allow default)','(deny process-info*)','(allow process-info* (target self))',
             '(allow process-info-codesignature)']
    # Home contains shell histories, usage dashboards, terminal transcripts and
    # project registries. Only executable installations and native authentication/
    # runtime roots are visible; narrower history denies below still apply.
    installs=[root,home/'.local/bin',home/'.local/lib',home/'.nvm',home/'.grok/bin',home/'.grok/auth.json',
              home/'.gemini/config/projects',
              home/'.gemini/antigravity-cli',home/'.cache/antigravity',home/'Library/Keychains',
              home/'Dropbox (Personal)/misc/env/agents']
    allowed=' '.join(f'(subpath {quote(str(p.resolve()))})' for p in installs)
    clauses.append(f'(deny file-read-data file-write* (require-all (subpath {quote(str(home))}) (require-not (require-any {allowed}))))')
    for path in protected:
        exceptions=[root,home/'Dropbox (Personal)/misc/env/agents',home/'.profiles/agents']
        allowed=' '.join(f'(subpath {quote(str(p.resolve()))})' for p in exceptions)
        clauses.append(f'(deny file-read-data file-write* (require-all (subpath {quote(str(path.resolve()))}) (require-not (require-any {allowed}))))')
    # Closed test trees and recordings live on the external disk. Moving them
    # must not make another pair's old notes or spectator footage agent inputs.
    for path in ('/Volumes/POG Media/pog-runs','/Volumes/POG Media/pog-recordings'):
        clauses.append(f'(deny file-read* file-write* (subpath {quote(path)}))')
    clauses.append(f'(deny file-read* file-write* (subpath {quote(str(home/".config/pog"))}))')
    if native:
        clauses.append(f'(deny file-read-data file-write* (require-all (subpath "/private/tmp") (require-not (literal "/private/tmp")) (require-not (subpath {quote(str(native))}))))')
    # Shared native transcripts and session indexes contain old project paths.
    # Grok and Muse use run-local data. Agy has no working data-root option:
    # forbid existing transcripts and index reads, while allowing newly created
    # UUID files. Its loop resumes only the ID received in its own JSON stream.
    for part in ('.local/share/muse','.config/muse','.codex','.claude','.config/herdr',
                 '.local/share/herdr','.config/ai-session'):
        clauses.append(f'(deny file-read-data file-write* (subpath {quote(str(home/part))}))')
    clauses.append(f'(deny file-read-data file-write* (require-all (subpath {quote(str(home/".grok"))}) (require-not (subpath {quote(str(home/".grok/bin"))})) (require-not (literal {quote(str(home/".grok/auth.json"))}))))')
    clauses.append(f'(deny file-write* (literal {quote(str(home/".grok/auth.json"))}))')
    agy=home/'.gemini/antigravity-cli'
    for part in ('brain','conversations'):
        parent=agy/part
        clauses.append(f'(deny file-read-data (literal {quote(str(parent))}))')
        for child in parent.iterdir() if parent.exists() else ():
            clauses.append(f'(deny file-read-data file-write* (subpath {quote(str(child))}))')
    projects=home/'.gemini/config/projects'
    clauses.append(f'(deny file-read-data (literal {quote(str(projects))}))')
    for child in projects.iterdir() if projects.exists() else ():
        clauses.append(f'(deny file-read-data file-write* (subpath {quote(str(child))}))')
    for part in ('cache/last_conversations.json','conversation_summaries.db','conversation_summaries.db-wal',
                 'conversation_summaries.db-shm','jetbox_summaries_proto.pb','annotations','implicit','scratch','presence'):
        clauses.append(f'(deny file-read-data file-write* (subpath {quote(str(agy/part))}))')
    for part in ('cli.log','cli.log.tmp','log','crashes'):
        clauses.append(f'(deny file-read-data (subpath {quote(str(agy/part))}))')
    clauses.extend(['(deny network-outbound)',
                    f'(allow network-outbound (remote unix-socket (subpath {quote(str(root))})))'])
    if native:clauses.append(f'(allow network-outbound (remote unix-socket (subpath {quote(str(native))})))')
    if proxy:
        address=urlparse(proxy)
        assert address.scheme=='http' and address.hostname=='127.0.0.1' and address.port,'a local provider proxy is required'
        clauses.append(f'(allow network-outbound (remote tcp "localhost:{address.port}"))')
    return '\n'.join(clauses)+'\n'

def native_environment(env,folder,home,muse=False):
    # Call native binaries, not the owner's session-registry wrappers.
    env['PATH']=str(home/'.local/bin')+':'+env.get('PATH','/usr/bin:/bin')
    marker=folder/'.native-root'
    if marker.exists():native=Path(marker.read_text().strip()).resolve()
    else:
        native=Path(tempfile.mkdtemp(prefix='pg-',dir='/private/tmp')).resolve()
        marker.write_text(str(native)+'\n')
    assert native.parent==Path('/private/tmp') and native.name.startswith('pg-') and native.is_dir()
    config=native/'config';data=native/'data'
    config.mkdir(exist_ok=True,mode=0o700);data.mkdir(exist_ok=True,mode=0o700)
    if muse:
        provider=config/'muse';provider.mkdir(exist_ok=True,mode=0o700)
        auth=provider/'auth.json'
        if not auth.exists():
            shutil.copyfile(home/'.config/muse/auth.json',auth);auth.chmod(0o600)
    env.update(XDG_CONFIG_HOME=str(config),XDG_DATA_HOME=str(data),MUSE_NO_AUTO_UPDATE='1',TMPDIR=str(native)+'/',POG_SCOPE_ACTIVE='1')
    return env

def main():
    root=Path(sys.argv[1]).resolve();proxy=sys.argv[2];command=sys.argv[3:]
    assert (root/'.launch-tree').is_file() and command,'expected a prepared project tree and command'
    env=native_environment(environment(os.environ),Path(command[0]).parent,Path.home(),muse='.muse' in Path(command[0]).name)
    policy=Path(command[0]).parent/'.scope.sb'
    policy.write_text(profile(root,Path.home(),proxy,Path(env['XDG_DATA_HOME']).parent))
    os.execve('/usr/bin/sandbox-exec',['sandbox-exec','-f',str(policy),*command],env)

if __name__=='__main__':main()

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

def codex_home(home=None):
    """(mt309) The POG Codex home: its own device login (never a copy of ~/.codex/auth.json, whose refresh token is
    shared with the owner's other work), its config and the sessions of the current run only."""
    return Path(os.environ.get('POG_CODEX_HOME') or Path(home or Path.home())/'.pog-codex'/'home')

def agy_home():
    """(note-mt309-y) A team's own agy home (POG_AGY_HOME): agy's HOME, app data and Gemini folders, its sign-in kept
    there in a file; the scope then has no keychain."""
    v=os.environ.get('POG_AGY_HOME')
    return Path(v).resolve() if v else None

def profile(root,home,proxy=None,native=None,codex=None,keychain=True,team_agy=None,agy_player=False):
    quote=json.dumps
    protected=[home/'code',home/'Dropbox',home/'Dropbox (Personal)']
    clauses=['(version 1)','(allow default)','(deny process-info*)','(allow process-info* (target self))',
             '(allow process-info-codesignature)']
    # Home contains shell histories, usage dashboards, terminal transcripts and
    # project registries. Only executable installations and native authentication/
    # runtime roots are visible; narrower history denies below still apply.
    installs=[root,home/'.local/bin',home/'.local/lib',home/'.nvm',home/'.grok/bin',home/'.grok/auth.json',
              home/'.gemini/config/projects',
              home/'.gemini/antigravity-cli',home/'.cache/antigravity',*([home/'Library/Keychains'] if keychain else []),
              home/'Dropbox (Personal)/misc/env/agents']+([codex] if codex else [])+([team_agy] if team_agy else [])
    allowed=' '.join(f'(subpath {quote(str(p.resolve()))})' for p in installs)
    clauses.append(f'(deny file-read-data file-write* (require-all (subpath {quote(str(home))}) (require-not (require-any {allowed}))))')
    for path in protected:
        exceptions=[root,home/'Dropbox (Personal)/misc/env/agents',home/'.profiles/agents']
        allowed=' '.join(f'(subpath {quote(str(p.resolve()))})' for p in exceptions)
        clauses.append(f'(deny file-read-data file-write* (require-all (subpath {quote(str(path.resolve()))}) (require-not (require-any {allowed}))))')
    # (mt309 s1r1d/s1r2) Nick's personal agent skills and tooling notes are never a player's: Grok listed and Muse put
    # into its model request the user skills of ~/.agents/skills (a link into the Dropbox agents folder, allowed above
    # for its programs: ~/.local/bin links there), with descriptions such as "Nick's private lifelog archive".
    # The folder stays readable only for bin/ and lib/; ~/.agents itself and agy's global rules (an always-on
    # "Nick's shared agent tooling" note) are denied. Last match wins, so these follow the allows above.
    for agents in {(home/'Dropbox (Personal)/misc/env/agents').resolve(), (home/'.profiles/agents').resolve()}:
        clauses.append(f'(deny file-read* file-write* (require-all (subpath {quote(str(agents))}) '
                       f'(require-not (subpath {quote(str(agents/"bin"))})) (require-not (subpath {quote(str(agents/"lib"))}))))')
    clauses.append(f'(deny file-read* file-write* (subpath {quote(str(home/".agents"))}))')
    for part in ('rules', 'skills'):
        for d in {home/'.gemini/antigravity-cli'/part, (home/'.gemini/antigravity-cli'/part).resolve()}:
            clauses.append(f'(deny file-read* file-write* (subpath {quote(str(d))}))')
    # Closed test trees and recordings live in the media folder (~/pog-media since d46 Nov 16; before that the
    # external POG Media volume, still denied while it may be attached). Moving them must not make another
    # pair's old notes or spectator footage agent inputs.
    media=Path(os.environ.get('POG_MEDIA') or home/'pog-media')
    for path in (media/'pog-runs',media/'pog-recordings',
                 Path('/Volumes/POG Media/pog-runs'),Path('/Volumes/POG Media/pog-recordings')):
        clauses.append(f'(deny file-read* file-write* (subpath {quote(str(path.resolve()))}))')
    clauses.append(f'(deny file-read* file-write* (subpath {quote(str(home/".config/pog"))}))')
    # (mt309 note-mt309-i) No keychain in this scope: its files and the SecurityServer lookup are refused (last match
    # wins). agy and Muse keep it because their own logins live there; Grok and Codex log in from files.
    if not keychain:
        for d in {home/'Library/Keychains', (home/'Library/Keychains').resolve()}:
            clauses.append(f'(deny file-read* file-write* (subpath {quote(str(d))}))')
        clauses.append('(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc")'
                       ' (global-name "com.apple.security.keychainsyncingoveridsproxy"))')
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
    projects=home/'.gemini/config/projects'
    for parent in (agy/'brain',agy/'conversations',projects):
        clauses.append(f'(deny file-read-data (literal {quote(str(parent))}))')
        if not agy_player:
            # Every other player, and agy in a team home: the whole folder, whatever agy has written there
            clauses.append(f'(deny file-read-data file-write* (subpath {quote(str(parent))}))')
            continue
        # (note-mt309-z6) agy on this home writes new UUID entries here: each existing entry is denied by the first
        # 9 characters of its name, the UUID's first block and dash (a string prefix: about 11 bytes of the compiled
        # profile each, where a full path took about 47; sandbox-exec refuses a data object over 65,535 bytes, about
        # 6,100 entries this way).
        names=sorted(c.name for c in parent.iterdir()) if parent.exists() else []
        for i in range(0,len(names),200):
            group=' '.join(f'(prefix {quote(str(parent/n[:9]))})' for n in names[i:i+200])
            clauses.append(f'(deny file-read-data file-write* (require-any {group}))')
    for part in ('cache/last_conversations.json','conversation_summaries.db','conversation_summaries.db-wal',
                 'conversation_summaries.db-shm','jetbox_summaries_proto.pb','annotations','implicit','scratch','presence'):
        clauses.append(f'(deny file-read-data file-write* (subpath {quote(str(agy/part))}))')
    for part in ('cli.log','cli.log.tmp','log','crashes'):
        clauses.append(f'(deny file-read-data (subpath {quote(str(agy/part))}))')
    if team_agy:
        # (note-mt309-y) a team agy home: the owner's agy folders are closed (last match wins) and no browser is opened
        for part in ('.gemini','.cache/antigravity'):
            clauses.append(f'(deny file-read* file-write* (subpath {quote(str(home/part))}))')
        clauses.append('(deny process-exec (literal "/usr/bin/open"))')
    clauses.extend(['(deny network-outbound)',
                    f'(allow network-outbound (remote unix-socket (subpath {quote(str(root))})))'])
    if native:clauses.append(f'(allow network-outbound (remote unix-socket (subpath {quote(str(native))})))')
    if proxy:
        address=urlparse(proxy)
        assert address.scheme=='http' and address.hostname=='127.0.0.1' and address.port,'a local provider proxy is required'
        clauses.append(f'(allow network-outbound (remote tcp "localhost:{address.port}"))')
    return '\n'.join(clauses)+'\n'

def native_environment(env,folder,home,muse=False,codex=None):
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
        # (mt309 s2a) Muse reads $HOME/.agents/skills and $HOME/.claude/skills (whose entries link into
        # ~/.agents/skills) on every start, and fails outright ("runtime host failed to start: failed to read skill
        # file") when the deny below refuses them; context.foreign_personal_skills=false does not stop the read and
        # TBH_USER_SKILLS_HOME moves only the first. So Muse gets a home of its own: empty but for the keychain its
        # login lives in. The deny of ~/.agents stays whole. muse-local.py finds the launcher through POG_MUSE_BIN.
        own=native/'home';(own/'Library').mkdir(parents=True,exist_ok=True,mode=0o700)
        if not (own/'Library/Keychains').is_symlink():(own/'Library/Keychains').symlink_to(home/'Library/Keychains')
        env.update(HOME=str(own),POG_MUSE_BIN=str(home/'.local/bin/muse'))
    env.update(XDG_CONFIG_HOME=str(config),XDG_DATA_HOME=str(data),MUSE_NO_AUTO_UPDATE='1',TMPDIR=str(native)+'/',POG_SCOPE_ACTIVE='1')
    if codex:
        assert (codex/'auth.json').is_file(),f'{codex} has no login: run CODEX_HOME={codex} codex login --device-auth once'
        env['CODEX_HOME']=str(codex)
        # (note-mt309-m) Codex verifies TLS through the Security framework, which needs the SecurityServer lookup the
        # scope refuses (note-mt309-i): every request failed ("error sending request", 5 reconnects). It reads this
        # CA file instead, and the scope keeps no keychain.
        if Path('/etc/ssl/cert.pem').is_file():env.setdefault('SSL_CERT_FILE','/etc/ssl/cert.pem')
    return env

def main():
    root=Path(sys.argv[1]).resolve();proxy=sys.argv[2];command=sys.argv[3:]
    assert (root/'.launch-tree').is_file() and command,'expected a prepared project tree and command'
    name=Path(command[0]).name
    codex=codex_home() if '.codex' in name else None
    agy=agy_home() if '.agy' in name else None
    env=native_environment(environment(os.environ),Path(command[0]).parent,Path.home(),muse='.muse' in name,codex=codex)
    if agy:
        (agy/'home').mkdir(exist_ok=True,mode=0o700)    # agy's ~/.gemini resolves inside the team home
        env.update(HOME=str(agy/'home'),ANTIGRAVITY_APP_DATA_DIR=str(agy/'app'),ANTIGRAVITY_GEMINI_DIR=str(agy/'home/.gemini'),
                   AGY_CLI_DISABLE_AUTO_UPDATE='1')
    policy=Path(command[0]).parent/'.scope.sb'
    keychain=any(k in name for k in ('.agy','.muse')) and not agy   # their own logins need it (note-mt309-i)
    policy.write_text(profile(root,Path.home(),proxy,Path(env['XDG_DATA_HOME']).parent,codex,keychain,agy,
                              agy_player='.agy' in name and not agy))
    os.execve('/usr/bin/sandbox-exec',['sandbox-exec','-f',str(policy),*command],env)

if __name__=='__main__':main()

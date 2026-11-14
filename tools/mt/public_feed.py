"""Allowlisted character identities and chronological speech for broadcast consumers.

No relay or presentation. The input is the operator-only harness feed, never a
source that an agent can poll. Scope describes delivery to agents, not who can
watch the broadcast: ordinary team speech stays team-private.
"""
import re

PRIVATE=re.compile(r'(?:https?://|(?:^|[\s(=:])(?:~/|/(?=[\w.~])|[A-Za-z]:[\\/])|[\w.+-]+@[\w.-]+\.[a-z]{2,}|'
                   r'\b(?:Nick(?:Winter)?|Winter|token|password|secret|api[_ -]?key|operator|traceback|exception)\b|'
                   r'\b(?:tools|runs|vendor|agent|site|docs|mt|port21|eng)/|\bsk-[\w-]+)',re.I)
AVATAR={'base':{'engineer','robot','biter','drone'},'helmet':{'none','hardhat','armor','power','crest','hood'},
        'visor':{'none','goggles','slit','wide','mono','grid'},'emblem':{'none','gear','bolt','flask','plate','circuit','rocket','leaf','star'},
        'accessory':{'none','antenna','headlamp','scarf','tank','horns','earpiece','pipe','headset'},
        'backdrop':{'dark','grid','hazard','glow','night'}}

def text(value,limit):
    if not isinstance(value,str) or PRIVATE.search(value):return ''
    return re.sub(r'\s+',' ',re.sub(r'\[/?[a-z-]+(?:=[^\]]*)?\]','',value)).strip()[:limit]

def identity(profile,fallback='Agent'):
    p=profile if isinstance(profile,dict) else {};out={}
    out['display_name']=text(p.get('display_name'),24) or text(fallback,24) or 'Agent'
    for k,limit in [('persona',160),('motto',80),('pronouns',32)]:
        value=text(p.get(k),limit)
        if value:out[k]=value
    color=p.get('color');glyph=p.get('glyph')
    if isinstance(color,str) and re.fullmatch(r'#[0-9a-fA-F]{6}',color):out['color']=color.lower()
    if isinstance(glyph,str) and 1<=len(glyph)<=8 and text(glyph,8)==glyph:out['glyph']=glyph
    avatar=p.get('avatar')
    if isinstance(avatar,dict):
        clean={k:v for k,v in avatar.items() if k in AVATAR and isinstance(v,str) and v in AVATAR[k]}
        accent=avatar.get('accent')
        if isinstance(accent,str) and re.fullmatch(r'#[0-9a-fA-F]{6}',accent):clean['accent']=accent.lower()
        if clean:out['avatar']=clean
    return out

def project_feed(messages,teams):
    rosters={t['team']:{a['name']:a for a in t['agents']} for t in teams}
    out={}
    for m in messages if isinstance(messages,list) else []:
        if not isinstance(m,dict):continue
        team,agent=m.get('team'),m.get('agent')
        if not isinstance(team,str) or team not in rosters or not isinstance(agent,str):continue
        if text(team,32)!=team or text(agent,32)!=agent:continue
        if any(m.get(k) for k in ('operator','viewer','source','confess')):continue
        seq,tick=m.get('seq'),m.get('tick')
        if type(seq) is not int or seq<1 or type(tick) is not int or tick<0:continue
        kind,scope,to=m.get('kind'),m.get('scope'),m.get('to',[])
        if to=={}:to=[]  # Factorio serializes an empty Lua array as an object.
        if not isinstance(to,list) or any(not isinstance(n,str) for n in to):continue
        if kind=='market':
            event=m.get('event','fill')
            if (scope!='market' or m.get('system') is not True or agent!='Trading Post'
                or event not in ('fill','coinage','raid','embargo','shipment_loss')
                or type(m.get('source_seq')) is not int or m['source_seq']<1):continue
            if event in ('fill','embargo','shipment_loss'):
                if len(to)!=1 or to[0] not in rosters or to[0]==team:continue
            elif to:continue
            body=text(m.get('text'),4000)
            if body:out.setdefault(seq,{'seq':seq,'tick':tick,'team':team,'agent':agent,'kind':kind,
                'scope':scope,'system':True,'event':event,'source_seq':m['source_seq'],'text':body,'to':to})
            continue
        if agent not in rosters[team] or m.get('system'):continue
        if kind=='diplomacy':
            if scope!='diplomacy' or len(to)!=1 or to[0] not in rosters or to[0]==team:continue
        elif kind=='identity':
            if scope!='public' or to:continue
        elif kind in ('say','tell','board'):
            if scope!='team-private' or any(n not in rosters[team] for n in to):continue
            if kind=='tell' and not to:continue
            if kind!='tell' and to:continue
        else:continue
        body=text(m.get('text'),4000)
        if not body:continue
        author=rosters[team][agent]
        who=identity(m.get('identity'),author.get('display_name') or agent.capitalize())
        model=text(author.get('model'),60)
        out.setdefault(seq,{'seq':seq,'tick':tick,'team':team,'agent':agent,'kind':kind,'scope':scope,
                            'text':body,'to':to,'identity':who,'model':model})
    return [out[n] for n in sorted(out)][-500:]

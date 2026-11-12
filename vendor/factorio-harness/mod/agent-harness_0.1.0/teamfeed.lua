-- Operator-only chronological broadcast log. This never delivers to an agent inbox.
return function(api)
  local M={operator={}}
  local KEEP=2000
  local function store()
    local mt=api.state().mt
    if not (mt and mt.teams) then return nil end
    mt.feed=mt.feed or {seq=0,lines={}}
    return mt.feed
  end
  function M.emit(who,kind,scope,text,to,source_seq)
    local s=store();if not s or type(text)~='string' or not text:find('%S') then return end
    local team=api.team_now();local author
    for _,a in ipairs(api.agents()) do if a.name==who then author=a;break end end
    if not author or not api.state().mt.teams[team] then return end -- excludes operator/system/viewers
    local identity={}
    for k,v in pairs(api.profile(author.index) or {}) do
      if ({display_name=true,color=true,glyph=true,persona=true,motto=true,pronouns=true,avatar=true})[k] then
        if type(v)=='table' then local copy={} for a,b in pairs(v) do copy[a]=b end;identity[k]=copy else identity[k]=v end
      end
    end
    local recipients={};for _,v in ipairs(to or {}) do recipients[#recipients+1]=v end
    s.seq=s.seq+1
    s.lines[#s.lines+1]={seq=s.seq,tick=game.tick,team=team,agent=who,kind=kind,scope=scope,
      text=text:sub(1,4000),truncated=#text>4000 or nil,to=recipients,identity=identity,source_seq=source_seq}
    while #s.lines>KEEP do table.remove(s.lines,1) end
  end
  -- Explicit system facts, never accepted from an agent's chat payload.
  function M.market(e)
    local s=store();if not s then return end
    s.seq=s.seq+1
    s.lines[#s.lines+1]={seq=s.seq,tick=e.tick,team=e.a,agent='Trading Post',kind='market',scope='market',
      text=e.text,to=e.b and {e.b} or {},source_seq=e.id or s.seq,system=true,event=e.kind or 'fill'}
    while #s.lines>KEEP do table.remove(s.lines,1) end
  end
  function M.operator.mt_feed(a)
    a=a or {};local since,limit=a.since,a.limit or 200
    assert(since==nil or type(since)=='number' and since>=0 and since==math.floor(since),'since: nonnegative sequence')
    assert(type(limit)=='number' and limit>=1 and limit<=500 and limit==math.floor(limit),'limit: 1..500')
    local s=store() or {seq=0,lines={}};local out={}
    local start=since==nil and math.max(1,#s.lines-limit+1) or 1
    for i=start,#s.lines do local v=s.lines[i]
      if since==nil or v.seq>since then out[#out+1]=v;if #out>=limit then break end end
    end
    local first=s.lines[1] and s.lines[1].seq or s.seq+1
    return {lines=out,last_seq=s.seq,cursor=#out>0 and out[#out].seq or since or s.seq,
      first_seq=first,gap=since~=nil and since<first-1 or nil,tick=game.tick}
  end
  return M
end

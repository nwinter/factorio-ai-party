-- mt281 (private: multi-team part I). Run from the harness root: lua tests/mt281.lua
-- Pacts (pacts.lua): shut before contact and in describe; propose, accept with a cease-fire both ways and the depot's
-- four chests; the depot's move less the cut, what does not fit waiting; an obligation reported short; pact_end with
-- the cease-fire lifting after the notice; amend, decline, withdraw, expiry; the human team's chat command; departures.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

defines={inventory={chest=1}}
prototypes={item={['iron-plate']={},['copper-plate']={}},space_location={nauvis={type='planet'}}}
local function force(name)
  local f={name=name,cease={},printed={},platforms={}}
  f.set_cease_fire=function(o,v) f.cease[type(o)=='table' and o.name or o]=v end
  f.get_cease_fire=function(o) return f.cease[type(o)=='table' and o.name or o]==true end
  f.add_chart_tag=function() end
  f.print=function(t) f.printed[#f.printed+1]=t end
  return f
end
local red,blue,green=force('red'),force('blue'),force('green')
-- a chest: an inventory of slots holding {name,count,quality}, insert up to 100 an item (a small chest)
local function chest(f)
  local slots,limit={},100
  local inv={}
  setmetatable(inv,{__len=function() return #slots end,__index=function(_,i) return slots[i] end})
  local function total() local n=0; for _,s in ipairs(slots) do if s.valid_for_read then n=n+s.count end end; return n end
  inv.insert=function(spec)
    local room=limit-total(); local n=math.min(room,spec.count)
    if n<=0 then return 0 end
    local s={valid_for_read=true,name=spec.name,count=n,quality={name=spec.quality or 'normal'}}
    setmetatable(s,{__newindex=function(t,k,v) rawset(t,k,v); if k=='count' and v<=0 then rawset(t,'valid_for_read',false) end end})
    slots[#slots+1]=s
    return n
  end
  inv.count=function(name) local n=0; for _,s in ipairs(slots) do if s.valid_for_read and s.name==name then n=n+s.count end end; return n end
  local c={valid=true,force=f,get_inventory=function() return inv end,inv=inv}
  c.destroy=function() c.valid=false end
  return setmetatable(c,{__newindex=function(t,k,v)
    assert(k~='minable','LuaEntity minable is read only')
    rawset(t,k,v)
  end})
end
local made={}
local surface={name='nauvis',can_place_entity=function() return true end,find_entities_filtered=function() return {} end,count_entities_filtered=function(f) return f.force=='blue' and 3 or 0 end,
  create_entity=function(a) local c=chest(a.force); c.position=a.position; made[#made+1]=c; return c end}
game={tick=1000,forces={red=red,blue=blue,green=green},get_surface=function(n) return (n==nil or n=='nauvis') and surface or nil end,
  get_player=function() return nil end}
helpers={json_to_table=function(t) return load('return '..t:gsub('"(%w+)":','%1='):gsub('%[','{'):gsub('%]','}'))() end,
  table_to_json=function() return '{}' end}
local s={mt={order={'red','blue','green'},teams={red=true,blue=true,green=true},first={}}}
local team='red'
local facts={}
local P=dofile('mod/agent-harness_0.1.0/pacts.lua'){state=function() return s end,team_now=function() return team end,
  who=function() return 'astra' end,as_team=function(t,fn,...) local was=team; team=t; local r=fn(...); team=was; return r end,
  fact=function(t,text,wake) facts[#facts+1]={team=t,text=text,wake=wake} end}
local H=P.handlers
local function last(t) for i=#facts,1,-1 do if facts[i].team==t then return facts[i].text end end end

-- shut before contact: refused, and not in describe
local actions={}
P.describe_into(actions); eq(actions.pact_propose,nil,'no pact actions before contact')
fails(function() H.pact_propose(nil,{with='blue'}) end,'no contact with another team yet')
s.mt.first['chart red>blue']=500
P.describe_into(actions); assert(actions.pact_propose and actions.pacts,'open after a contact')
fails(function() H.pact_propose(nil,{with='green'}) end,'no contact with green yet')

-- a proposal: checked terms, a fact line to blue that wakes it
fails(function() H.pact_propose(nil,{with='blue',terms={shares={red=0.9,blue=0.2}}}) end,'summing to 1')
fails(function() H.pact_propose(nil,{with='blue',terms={chart=true}}) end,'terms: no chart')
fails(function() H.pact_propose(nil,{with='blue',terms={obligations={{kind='deliver',who='blue',item='iron-plate',count=60}}}}) end,'needs a depot')
fails(function() H.pact_propose(nil,{with='blue',terms={shares={red=0.9,blue=0.1}}}) end,'at most 0.70 each')
local r=H.pact_propose(nil,{with='blue',note='trade',terms={cease_fire=true,shares={red=0.7,blue=0.3},depot={x=10,y=20},
  obligations={{kind='deliver',who='blue',item='iron-plate',count=60},{kind='keep_out',who='blue',x=0,y=0,r=50},{kind='no_attack',who='blue',target='green'}}}})
local id=r.pact.id
eq(r.pact.status,'proposed')
assert(last('blue'):find('red proposes pact #'..id..': cease%-fire; shares blue 0.30 / red 0.70; a depot at %(10,20%)'),last('blue'))
assert(last('blue'):find('blue delivers 60 iron%-plate an hour') and last('blue'):find('Note: trade'),last('blue'))
fails(function() H.pact_accept(nil,{id=id}) end,'the other team accepts it')

local duplicate=H.pact_propose(nil,{with='blue',terms={cease_fire=true}}).pact.id
-- blue accepts: cease-fire both ways, four chests, facts to both
team='blue'
-- A blocked second slot rolls back the first chest, without accepting the pact.
local checks=0
surface.can_place_entity=function() checks=checks+1;return checks~=2 end
fails(function() H.pact_accept(nil,{id=id}) end,'is taken')
eq(#made,1);eq(made[1].valid,false)
eq(s.mt.pacts.by_id[id].status,'proposed');eq(red.get_cease_fire('blue'),false)
made={};surface.can_place_entity=function() return true end
H.pact_accept(nil,{id=id})
eq(red.get_cease_fire('blue'),true); eq(blue.get_cease_fire('red'),true)
fails(function() H.pact_accept(nil,{id=duplicate}) end,'already holds')
eq(#made,4,'four chests: each team sends and receives')
local d=s.mt.pacts.by_id[id].terms.depot.chests
assert(d['red send'].force=='red' and d['blue receive'].force=='blue','each chest its team\'s')
eq(d['red send'].destructible,false); eq(d['red send'].minable_flag,false)
assert(last('red'):find('pact #'..id..' between red and blue holds'),last('red'))
team='red';H.pact_withdraw(nil,{id=duplicate})
fails(function() H.pact_propose(nil,{with='blue'}) end,'pact_amend replaces it')

-- the depot moves red's 50 iron plates: 40 arrive, 10 are the cut; 300 copper plates: 100 fit, the rest waits
d['red send'].inv.insert({name='iron-plate',count=50})
d['red send'].inv.insert({name='copper-plate',count=50})
d['blue send'].inv.insert({name='iron-plate',count=50})
s.mt.pacts.config.move_s=10
game.tick=1200; P.tick(1200+31-(1200%600))  -- a move tick (tick % 600 == 31)
P.tick(1231)
eq(d['blue receive'].inv.count('iron-plate'),40,'50 sent, 40 arrive (cut 20%)')
eq(d['red receive'].inv.count('iron-plate'),40,'both ways')
eq(d['blue receive'].inv.count('copper-plate'),40)
local l=s.mt.pacts.by_id[id].ledger[math.floor(game.tick/216000)]
eq(l.sent.red['iron-plate'],50); eq(l.cut.red['iron-plate'],10); eq(l.received.blue['iron-plate'],40)
d['red send'].inv.insert({name='copper-plate',count=300})
P.tick(1831)
eq(d['blue receive'].inv.count('copper-plate'),60,'the receiving chest full (100 items in this mock, 40 iron there): the rest waits')
assert(d['red send'].inv.count('copper-plate')>0,'what did not fit stays in the sending chest')

-- the obligations at their check (check_s): blue's delivery 40 of 60 short, its 3 entities in the circle; a hit on green
s.mt.pacts.hits['blue>green']=game.tick
local p=s.mt.pacts.by_id[id]
p.next_check=game.tick
P.tick(game.tick-(game.tick%60)+29)
do local all={}; for _,f in ipairs(facts) do if f.team=='red' then all[#all+1]=f.text end end
  assert(table.concat(all,'\n'):find('blue delivered 40 of 60 iron%-plate'),table.concat(all,'\n')) end
local seen={}
for _,f in ipairs(facts) do if f.team=='blue' then seen[#seen+1]=f.text end end
local txt=table.concat(seen,'\n')
assert(txt:find('blue has 3 entities within 50 of %(0,0%)') and txt:find('blue hit an entity of green'),txt)

-- pacts read; pact_end: ended now, the cease-fire lifts end_notice_s later
local list=H.pacts(nil,{}).pacts
eq(list[1].id,duplicate); eq(list[1].status,'withdrawn')
eq(list[2].id,id); eq(list[2].status,'active')
team='blue'
game.tick=3000
P.operator.mt_pacts({config={end_notice_s=600}})   -- the notice path (the default 0 lifts at once: below)
H.pact_end(nil,{id=id,note='enough'})
eq(p.status,'ended'); eq(p.lift_tick,3000+600*60)
assert(last('red'):find('blue ended pact #'..id..' at tick 3000; the cease%-fire lifts at tick 39000 %(600 s from now%). Note: enough'),last('red'))
eq(red.get_cease_fire('blue'),true,'the cease-fire holds through the notice')
P.tick(38999-(38999%60)+29)
eq(red.get_cease_fire('blue'),true)
P.tick(39029)
eq(red.get_cease_fire('blue'),false,'lifted after the notice'); eq(blue.get_cease_fire('red'),false)
d['red send'].inv.insert({name='iron-plate',count=10})
local before=d['blue receive'].inv.count('iron-plate')
P.tick(39631)
eq(d['blue receive'].inv.count('iron-plate'),before,'no moves after the end')

-- decline, withdraw, expiry, amend
team='red'
local a2=H.pact_propose(nil,{with='blue',terms={cease_fire=true}}).pact.id
team='blue'; H.pact_decline(nil,{id=a2,note='no'}); eq(s.mt.pacts.by_id[a2].status,'declined')
team='red'
local a3=H.pact_propose(nil,{with='blue',terms={cease_fire=true}}).pact.id
H.pact_withdraw(nil,{id=a3}); eq(s.mt.pacts.by_id[a3].status,'withdrawn')
local a4=H.pact_propose(nil,{with='blue',terms={cease_fire=true},expires_min=1}).pact.id
local exp=s.mt.pacts.by_id[a4].expires_tick
P.tick(exp-(exp%60)+89)
eq(s.mt.pacts.by_id[a4].status,'expired')
local a5=H.pact_propose(nil,{with='blue',terms={cease_fire=true}}).pact.id
team='blue'; H.pact_accept(nil,{id=a5})
team='red'
local a6=H.pact_amend(nil,{id=a5,terms={cease_fire=true,shares={red=0.5,blue=0.5}}}).pact.id
eq(s.mt.pacts.by_id[a6].replaces,a5)
team='blue'; H.pact_accept(nil,{id=a6})
eq(s.mt.pacts.by_id[a5].status,'ended','the amended pact replaced'); eq(s.mt.pacts.by_id[a6].status,'active')

-- the human team (blue here) through chat
s.mt.humans={team='blue',players={nick=true}}
local nick={name='nick',force=blue,valid=true}
game.get_player=function(i) return i==7 and nick or nil end
team='player'
P.on_console_chat({player_index=7,message='!pact list'})
assert(blue.printed[#blue.printed]:find('^%[pact%] '),blue.printed[#blue.printed])
P.on_console_chat({player_index=7,message='!pact bogus'})
assert(blue.printed[#blue.printed]:find('refused: no pact action bogus'),blue.printed[#blue.printed])

-- a departure: red's platform leaves nauvis's orbit with the pact with blue active
local pl={valid=true,index=1,name='Edge',space_location={name='nauvis'}}
red.platforms={pl}
P.tick(39600+37)
pl.space_location=nil
P.tick(40200+37)
local dep=s.mt.pacts.departures[1]
eq(dep.team,'red'); eq(dep.from,'nauvis'); eq(dep.pacts[1].with,'blue'); eq(dep.pacts[1].shares.red,0.5)

-- the operator read and its settings
local o=P.operator.mt_pacts({config={cut=0.3}})
eq(o.config.cut,0.3); eq(o.config.end_notice_s,600); eq(o.config.share_max_score,1.4)
fails(function() P.operator.mt_pacts({config={chart=true}}) end,'is no setting')
-- the scoring's allied edge (mt284): shares bounded by share_max_score / N; 0.7/0.3 of two is 1.4/0.6, even 1.0 each
local sc=P.allied_scores({red=0.7,blue=0.3},{'red','blue'})
assert(math.abs(sc.red-1.4)<1e-9 and math.abs(sc.blue-0.6)<1e-9,sc.red..' '..sc.blue)
sc=P.allied_scores(nil,{'red','blue'}); assert(sc.red==1 and sc.blue==1)
assert(math.abs(P.share_max(2)-0.7)<1e-9 and math.abs(P.share_max(3)-1.4/3)<1e-9 and math.abs(P.share_max(4)-0.35)<1e-9)
-- pact_end with the default end_notice_s 0: the cease-fire lifts on the same tick, one fact line says so
P.operator.mt_pacts({config={end_notice_s=0}})
team='red'
H.pact_end(nil,{id=a6})
local q=H.pact_propose(nil,{with='blue',terms={cease_fire=true}}).pact.id
team='blue'; H.pact_accept(nil,{id=q})
eq(red.get_cease_fire('blue'),true)
local before_n=#facts
H.pact_end(nil,{id=q})
eq(red.get_cease_fire('blue'),false,'lifted at once'); eq(blue.get_cease_fire('red'),false)
assert(last('red'):find('blue ended pact #'..q..' at tick %d+; the cease%-fire lifted now'),last('red'))
eq(#facts-before_n,2,'one line to each team, no second lift line')
print('mt281 pacts: ok')

team='red'
local original=H.pact_propose(nil,{with='blue',terms={cease_fire=true,depot={x=30,y=30}}}).pact.id
team='blue';H.pact_accept(nil,{id=original})
local original_chests=s.mt.pacts.by_id[original].terms.depot.chests
team='red'
local amend=H.pact_amend(nil,{id=original,terms={cease_fire=true,depot={x=30,y=30},shares={red=.5,blue=.5}}}).pact.id
local count=#made
team='blue';H.pact_accept(nil,{id=amend})
eq(#made,count,'same depot amendment retains chests')
eq(s.mt.pacts.by_id[amend].terms.depot.chests,original_chests)
team='red'
local bad=H.pact_amend(nil,{id=amend,terms={cease_fire=true,depot={x=40,y=40}}}).pact.id
surface.can_place_entity=function() return false end
team='blue';fails(function() H.pact_accept(nil,{id=bad}) end,'is taken')
eq(s.mt.pacts.by_id[amend].status,'active','failed amendment keeps old pact')
eq(red.get_cease_fire('blue'),true)
print('mt291 depot creation rollback and amendment: ok')

game=nil; defines=nil; prototypes=nil; helpers=nil

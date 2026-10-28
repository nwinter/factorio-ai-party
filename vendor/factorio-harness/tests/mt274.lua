-- mt274 (private: multi-team phase 1). Run from the harness root: lua tests/mt274.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- Forces at war, spawns on every planet (surfaces made with the teams' starting points), and first contact: a team's
-- chart showing another team's entity, and a hit between teams, each once per ordered pair; nothing before mt_setup.
do
  local logged,written={},{}
  log=function(s) logged[#logged+1]=s end
  helpers={table_to_json=function(t) local k={} for n,v in pairs(t) do k[#k+1]=n..'='..tostring(v) end table.sort(k) return '{'..table.concat(k,',')..'}' end,
    write_file=function(name,data) written[#written+1]=name..' '..data end}
  defines={controllers={spectator=4}}
  local forces={}
  local function force(name)
    local f={name=name,cease={},friend={},spawn={},share_chart=true,players={},technologies={}}
    f.set_cease_fire=function(o,v) f.cease[o]=v end
    f.get_cease_fire=function(o) return f.cease[o] or false end
    f.set_friend=function(o,v) f.friend[o]=v end
    f.get_friend=function(o) return f.friend[o] or false end
    f.set_spawn_position=function(p,s) f.spawn[s.name]={x=p.x,y=p.y} end
    f.get_spawn_position=function(s) return f.spawn[s.name] or {x=0,y=0} end
    f.is_chunk_charted=function() return false end
    forces[name]=f
    return f
  end
  force('player'); force('enemy'); force('neutral')
  local surfaces={}
  local function surface(name)
    local s={name=name,map_gen_settings={starting_points={{x=0,y=0}}},ents={}}
    s.find_entities_filtered=function(f)
      local want={}
      for _,n in ipairs(f.force or {}) do want[n]=true end
      local out={}
      for _,e in ipairs(s.ents) do if want[e.force.name] then out[#out+1]=e end end
      return out
    end
    surfaces[name]=s
    return s
  end
  local nauvis=surface('nauvis')
  local planets={nauvis={surface=nauvis},vulcanus={}}
  planets.vulcanus.create_surface=function() local s=surface('vulcanus'); planets.vulcanus.surface=s; return s end
  local players={}
  game={tick=500,forces=forces,planets=planets,surfaces=surfaces,
    create_force=function(n) return force(n) end,
    get_surface=function(n) if type(n)=='number' then return n==1 and nauvis or surfaces.vulcanus end return surfaces[n] end,
    get_player=function(n) return players[n] end}
  local store={}
  local M=dofile('mod/agent-harness_0.1.0/multiteam.lua'){state=function() return store end}

  -- before setup, no contact is read or recorded (a normal run)
  local red0=force('red')
  M.on_damaged({force=red0,entity={valid=true,force=forces.player,name='gun-turret',position={x=1,y=1},surface=nauvis}})
  eq(store.mt and store.mt.contacts and #store.mt.contacts or 0,0,'nothing before mt_setup')
  forces.red=nil

  local r=M.operator.mt_setup({teams={{name='red',spawns={nauvis={500.5,500.5},vulcanus={424.5,424.5}}},
    {name='blue',spawns={nauvis={-499.5,500.5},vulcanus={-423.5,424.5}}}}})
  eq(table.concat(r.teams,','),'red,blue'); eq(table.concat(r.made,','),'red,blue')
  has(table.concat(r.surfaces,'; '),'vulcanus (made, 2 starting points)')
  local sp=surfaces.vulcanus.map_gen_settings.starting_points
  eq(#sp,2,'vulcanus made with the teams\' spawns as its starting points'); eq(sp[1].x,424.5); eq(sp[2].x,-423.5)
  eq(forces.red.get_cease_fire('blue'),false); eq(forces.red.get_friend('blue'),false); eq(forces.blue.cease.red,false)
  eq(forces.red.cease.enemy,false); eq(forces.red.share_chart,false)
  eq(forces.red.spawn.nauvis.x,500.5); eq(forces.blue.spawn.vulcanus.x,-423.5)
  fails(function() M.operator.mt_setup({teams={{name='player',spawns={nauvis={0,0}}},{name='x',spawns={nauvis={1,1}}}}}) end,'not player, enemy or neutral')
  fails(function() M.operator.mt_setup({teams={{name='a',spawns={nauvis={0,0}}}}}) end,'teams: 2..8')

  -- chart: red's chart shows a blue pole; once per ordered pair
  local pole={name='small-electric-pole',force=forces.blue,position={x=-10.5,y=3.5}}
  nauvis.ents={pole}
  game.tick=600
  M.on_charted({force=forces.red,surface_index=1,area={{-32,0},{0,32}}})
  local c=store.mt.contacts
  eq(#c,1); eq(c[1].kind,'chart'); eq(c[1].team,'red'); eq(c[1].other,'blue'); eq(c[1].entity,'small-electric-pole'); eq(c[1].tick,600)
  eq(c[1].x,-10.5); eq(c[1].surface,'nauvis')
  M.on_charted({force=forces.red,surface_index=1,area={{-32,0},{0,32}}})
  eq(#c,1,'once per ordered pair')
  -- blue charting its own pole: nothing; blue seeing red's: its own record
  M.on_charted({force=forces.blue,surface_index=1,area={{-32,0},{0,32}}})
  eq(#c,1)
  nauvis.ents={pole,{name='radar',force=forces.red,position={x=5,y=5}}}
  M.on_charted({force=forces.blue,surface_index=1,area={{0,0},{32,32}}})
  eq(#c,2); eq(c[2].team,'blue'); eq(c[2].other,'red'); eq(c[2].entity,'radar')
  -- a force that is no team (player, enemy) charting: nothing
  M.on_charted({force=forces.player,surface_index=1,area={{0,0},{32,32}}})
  eq(#c,2)

  -- shots: red hits blue's turret (once), blue hits red, a biter's hit and a hit within a team are none
  local turret={valid=true,force=forces.blue,name='gun-turret',position={x=2,y=2},surface=nauvis}
  M.on_damaged({force=forces.red,entity=turret,cause={valid=true,name='gun-turret'},final_damage_amount=5})
  eq(#c,3); eq(c[3].kind,'shot'); eq(c[3].team,'red'); eq(c[3].other,'blue'); eq(c[3].cause,'gun-turret'); eq(c[3].damage,5)
  M.on_damaged({force=forces.red,entity=turret,final_damage_amount=5})
  eq(#c,3,'once per ordered pair')
  M.on_damaged({force=forces.enemy,entity=turret,final_damage_amount=5})
  M.on_damaged({force=forces.blue,entity=turret,final_damage_amount=5})
  M.on_damaged({force=nil,entity=turret,final_damage_amount=5})
  eq(#c,3)
  M.on_damaged({force=forces.blue,entity={valid=true,force=forces.red,name='character',position={x=0,y=0},surface=nauvis},final_damage_amount=3})
  eq(#c,4); eq(c[4].team,'blue'); eq(c[4].other,'red')
  eq(#logged,4); has(logged[1],'mt contact: '); eq(#written,4); has(written[1],'pog/mt-contacts.jsonl')

  -- the read: all of them, or since a tick
  local read=M.operator.mt_contacts({})
  eq(#read.contacts,4); eq(table.concat(read.teams,','),'red,blue')
  game.tick=700
  M.on_damaged({force=forces.red,entity={valid=true,force=forces.blue,name='wall',position={x=0,y=0},surface=nauvis},final_damage_amount=1})
  eq(#M.operator.mt_contacts({since=600}).contacts,0,'shot red>blue already recorded')

  -- mt_assign: a connected player moves into a team's force as a spectator, its character gone
  local destroyed=false
  local ch={valid=true,destroy=function() destroyed=true end}
  local p={name='mt-red',force=forces.player,connected=true,character=ch}
  p.set_controller=function(c2) p.controller=c2.type; p.character=nil end
  players['mt-red']=p
  local as=M.operator.mt_assign({player='mt-red',team='red'})
  eq(p.force,'red'); eq(as.was,'player'); eq(as.spectator,true)
  eq(p.controller,4); eq(destroyed,true)
  fails(function() M.operator.mt_assign({player='mt-red',team='green'}) end,'not a team: green')
  fails(function() M.operator.mt_assign({player='nobody',team='red'}) end,'no player nobody')
  game,defines,helpers,log=nil,nil,nil,nil
end
-- (mt275) a second site slides as a whole along its axis to dry land; clears take only the named resources
do
  local made,destroyed={},{}
  local res={}
  local function rent(name,x,y) local e={name=name,position={x=x,y=y},destroy=function() destroyed[#destroyed+1]=name end} res[#res+1]=e return e end
  rent('stone',0,0); rent('iron-ore',1,1)
  local surface={name='nauvis'}
  -- water where y < 100 (the site's centre at 0,0 is a lake); land beyond
  surface.can_place_entity=function(f) return f.position.y>=100 end
  surface.create_entity=function(f) made[#made+1]=f end
  surface.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(res) do if not f.name or (function() for _,n in ipairs(f.name) do if n==e.name then return true end end end)() then out[#out+1]=e end end
    return out
  end
  game={get_surface=function() return surface end,tick=1}
  prototypes={entity={['iron-ore']={type='resource'},['copper-ore']={type='resource'},stone={type='resource'}}}
  local store={}
  local M=dofile('mod/agent-harness_0.1.0/multiteam.lua'){state=function() return store end}
  local r=M.operator.mt_resources({surface='nauvis',clear={{x=0,y=0,r=50,names={'stone'}}},
    sites={{name='second a-b',x=0.5,y=0.5,axis={0,1},slide=400,patches={{name='iron-ore',dx=-40,dy=0,r=5,amount=1000},{name='copper-ore',dx=40,dy=0,r=5,amount=800}}}}})
  eq(r.cleared,1,'only the named resource cleared'); eq(destroyed[1],'stone')
  eq(#r.placed,2)
  eq(r.placed[1].slid,112,'slid along the axis to the first centre where both fit'); eq(r.placed[1].y,112.5); eq(r.placed[1].x,-39.5)
  eq(r.placed[2].x,40.5); eq(r.placed[2].y,112.5)
  local total=0 for _,m in ipairs(made) do if m.name=='iron-ore' then total=total+m.amount end end
  eq(total,1000,'the iron total kept'); eq(r.placed[1].amount,1000)
  game,prototypes=nil,nil
end
print('mt274 multi-team setup and first contact: ok')

-- d17 batch33. Run from the harness root: lua tests/d17_batch33.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Sol: Wayfarer's 3318 tile ghosts; the one-tick check stopped at 4096 steps and the dry run read the rest as 107
-- unbuildable): the play stops undecided, never unbuilt; a check across ticks finishes it.
do
  game={tick=1000,surfaces={}}
  local found={}
  for x=0,9 do found[x..','..0]=true end
  local surface={index=7,get_tile=function(x,y) return {name=found[x..','..y] and 'space-platform-foundation' or 'empty-space'} end}
  game.surfaces[7]=surface
  local TC=dofile('mod/agent-harness_0.1.0/tilecheck.lua')()
  local tiles={}
  for y=1,20 do for x=0,9 do tiles[#tiles+1]={x,y,'space-platform-foundation'} end end
  tiles[#tiles+1]={40,40,'space-platform-foundation'}  -- far from any foundation
  -- in one go: every fill tile built, the far one not
  local play=TC.play(surface,tiles,nil,{},{},100000)
  local n=0 for _ in pairs(play.built) do n=n+1 end
  eq(n,200); eq(play.left,0); eq(play.rule({40,40}),'no foundation among the 8 tiles round it')
  -- each tile once on the work list: checks stay near the tile count
  assert(play.steps<=2*#tiles,play.steps)
  -- stopped early: the rest is unchecked, not unbuilt
  play=TC.play(surface,tiles,nil,{},{},50)
  assert(play.left>0); local u=0 for _ in pairs(play.unchecked) do u=u+1 end; eq(u,play.left)
  -- across ticks
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/floorcheck.lua'){state=function() return st end}
  local cells={}
  for i,t in ipairs(tiles) do cells[i]={t[1],t[2]} end
  local id=F.start(surface,cells,nil,{},'test fill')
  local r=F.read(id)
  eq(r.state,'running'); has(r.line,'floor check #1 (test fill): 201 tiles, running: 0 rule checks so far (150 a tick), 201 tiles still queued')
  for _=1,20 do F.tick() end
  r=F.read(id)
  eq(r.state,'done'); eq(r.built,200); eq(r.unbuilt_count,1)
  eq(r.unbuilt[1],'(40.5,40.5): no foundation among the 8 tiles round it')
  has(r.line,'201 tiles checked by the hub\'s rules'); has(r.line,'200 built in turn, 1 never built (1 no foundation among the 8 tiles round it)')
  eq(st.floorcheck.jobs[id].ghosts,nil,'the large tables go when done')
  fails(function() F.read(99) end,'no floor check #99 (kept: 1)')
  game=nil
end
print('d17_batch33 A1 floor check across ticks: ok')

-- A3 (Sol: Wayfarer's arithmetic combinators asked 2 against the default, a full rocket of 50, even with tail): tail
-- lowers a slot on the game's default minimum payload too, and each line says the minimum the slot has.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={nauvis={}},item={['arithmetic-combinator']={weight=20000}},utility_constants={rocket_lift_weight=1000000}}
  local ghosts={}
  local proto={name='arithmetic-combinator',items_to_place_this={{name='arithmetic-combinator',count=1}}}
  for i=1,4 do ghosts[i]={type='entity-ghost',ghost_name='arithmetic-combinator',ghost_prototype=proto} end
  local sections={}
  local function section(group)
    local sec={group=group,slots={},is_manual=true,filters_count=0}
    sec.set_slot=function(i,f) sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local held=2
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return held end} end}
  local pl={valid=true,index=6,name='Wayfarer',hub=hub,space_location={name='nauvis'},surface={find_entities_filtered=function() return ghosts end}}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
  -- without tail: the game's default, said
  local r=B.read({force=force},{platform='Wayfarer',request=true,import_from='nauvis'})
  eq(sections[1].slots[1].minimum_delivery_count,nil)
  has(r.lines[1],'minimum payload: a full rocket, 50 by weight (the game\'s default)')
  -- tail: 4 asked, 2 held: 2 to come, under the 50 a full rocket takes
  r=B.read({force=force},{platform='Wayfarer',request=true,import_from='nauvis',tail=true})
  eq(sections[1].slots[1].minimum_delivery_count,2)
  has(r.lines[1],'custom minimum payload 2 (tail: 2 of the 50 a full rocket takes, what is still to come)')
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch33 A3 tail on the default payload: ok')

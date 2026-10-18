-- Run from the harness root: lua tests/d17_territory.lua
-- Demolisher territories, cleared or not (d17 territory, Nick 17:08: Vulcanus territory 1 had no demolisher after Sol
-- killed it, and the reads and build notes did not tell that from one out of sight).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,w) assert(s and s:find(w,1,true),tostring(s)..' lacks '..w) end
local function lacks(s,w) assert(not (s and s:find(w,1,true)),tostring(s)..' has '..w) end
game={tick=4888121}
local st={}
local function territory(cx0,cy0,cx1,cy1,units)
  local chunks={}
  for cx=cx0,cx1 do for cy=cy0,cy1 do chunks[#chunks+1]={x=cx,y=cy} end end
  -- the engine's chunk order is not sorted: the key is the smallest chunk whatever the order
  table.sort(chunks,function(a,b) return a.y>b.y end)
  return {get_chunks=function() return chunks end,get_segmented_units=function() return units end,box={cx0,cy0,cx1,cy1}}
end
local live={unit_number=91,health=30000,max_health=30000,speed=0,prototype={name='small-demolisher'},
  segments={{position={x=200,y=330},orientation=0.25,prototype={collision_box={left_top={x=-1.5,y=-1.5},right_bottom={x=1.5,y=1.5}}}}}}
local t1,t2,t3=territory(-10,-6,2,12,{}),territory(4,-6,8,0,{}),territory(4,8,8,12,{live})
local territories={t1,t2,t3}
local surface={name='vulcanus',get_territories=function() return territories end,
  get_territory_for_chunk=function(c) for _,t in ipairs(territories) do local b=t.box if c.x>=b[1] and c.x<=b[3] and c.y>=b[2] and c.y<=b[4] then return t end end end}
local force={is_chunk_charted=function() return true end,is_chunk_visible=function(_,c) return c.x>=4 and c.y>=8 end}
local sol={valid=true,type='character'}
local D=dofile('mod/agent-harness_0.1.0/demolishers.lua'){state=function() return st end,position=function(v) return v end,
  character_name=function(e) return e==sol and 'sol' or nil end}
local T=dofile('mod/agent-harness_0.1.0/territory.lua'){state=function(s,f,t) return D.state(s,f,t) end}

-- Sol kills territory 1's demolisher: its territory, when and by whom are kept; its last-seen memory goes.
st.demolisher_seen={[77]={x=-200,y=40,tick=4800000,name='small-demolisher'}}
local head={valid=true,type='segmented-unit',name='small-demolisher',surface=surface,position={x=-200.5,y=40.5},
  segmented_unit={unit_number=77,territory=t1}}
D.died({entity=head,cause=sol,tick=4888121,force={name='player'}})
eq(st.demolisher_seen[77],nil)
local d=st.demolisher_deaths['vulcanus|-10,-6']
eq(d.by,'sol'); eq(d.tick,4888121); eq(d.name,'small-demolisher')

game.tick=4888121+3*216000
local p={surface=surface,force=force,position={x=0,y=0}}
local r=D.read(p,{surface=nil})
local by={}
for _,row in ipairs(r.territories) do by[row.charted_chunks]=row end
eq(by[13*19].state,'killed')
has(by[13*19].line,'its small-demolisher was killed at tick 4888121 (game 22h37m, 3h ago) by sol; none seen since')
eq(by[5*7].state,'none'); has(by[5*7].line,'no demolisher in it now')
eq(by[5*5].state,'has a demolisher'); has(by[5*5].line,'small-demolisher: head at (200,330)')

-- Build notes: a placement in the cleared territory says so, with no "attacks what is built" line; in the empty one,
-- none in it now; by the live one, the demolisher.
local n1=T.note(surface,force,{-225,30,-224,45})
has(n1,'(its small-demolisher was killed at tick 4888121 (game 22h37m, 3h ago) by sol; none seen since)'); lacks(n1,'attacks what is built')
local n2=T.note(surface,force,{140,-100,141,-99})
has(n2,'(no demolisher in it now)'); lacks(n2,'attacks what is built')
local n3=T.note(surface,force,{150,300,151,301})
has(n3,'a demolisher attacks what is built in its territory')

-- A cause that is not a character: the entity and who built it; none: the killing force.
D.died({entity={valid=true,type='segmented-unit',name='small-demolisher',surface=surface,position={x=170,y=-100},segmented_unit={unit_number=78,territory=t2}},
  cause={valid=true,type='artillery-turret',name='artillery-turret',last_user={name='opus'}},tick=5000000})
eq(st.demolisher_deaths['vulcanus|4,-6'].by,'artillery-turret (built by opus)')
print('d17_territory: ok')

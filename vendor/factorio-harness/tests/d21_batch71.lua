-- d20 batch71 AG1 (#1686, Sol). Run from the harness root: lua tests/d21_batch71.lua
-- Rail and chain signals on a rail layer: the signal spots of rail ends, the game's check on the layer asked (else
-- ground then elevated), the spot's facing when none is given, placements, inspect's read. Fake engine.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,err=pcall(f); assert(not ok,'did not fail'); has(err,x) end
defines={rail_direction={front=0,back=1},build_check_type={manual=1,manual_ghost=2},signal_state={open=0,closed=1,reserved=2,reserved_by_circuit_network=3},
  chain_signal_state={none=0,all_open=1,partially_open=2,none_open=3}}
prototypes={entity={['rail-signal']={type='rail-signal'},['rail-chain-signal']={type='rail-chain-signal'},['elevated-straight-rail']={type='elevated-straight-rail'}}}
-- an elevated east-west line at y=1: rails at x=-151,-149,-147; each joint has an out spot below (facing west) and an in
-- spot above (facing east), on the elevated layer (as 2.0.77 gave them)
local rails={}
local function rail(x)
  local r={valid=true,name='elevated-straight-rail',type='elevated-straight-rail',position={x=x,y=1}}
  r.get_rail_end=function(rd)
    local jx=rd==0 and x+1 or x-1
    local sx=rd==0 and jx-0.5 or jx+0.5
    return {in_signal_location={position={x=sx,y=-0.5},direction=4,rail_layer=1},out_signal_location={position={x=sx,y=2.5},direction=12,rail_layer=1}}
  end
  rails[#rails+1]=r
end
rail(-151); rail(-149); rail(-147)
local taken={}
local surface={find_entities_filtered=function(f)
    local out={}
    for _,r in ipairs(rails) do if (r.position.x-f.position.x)^2+(r.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=r end end
    return out
  end,
  can_place_entity=function(a)
    if a.rail_layer~=1 then return false end
    if taken[a.position.x..','..a.position.y] then return false end
    for _,r in ipairs(rails) do for rd=0,1 do local e=r.get_rail_end(rd)
      for _,l in ipairs({e.in_signal_location,e.out_signal_location}) do
        if math.abs(l.position.x-a.position.x)<0.01 and math.abs(l.position.y-a.position.y)<0.01 and l.direction==a.direction then return true end
      end
    end end
    return false
  end}
local R=require('railsignal'){position=function(p) return {x=p.x or p[1],y=p.y or p[2]} end,integer=function(v,d) return v or d end}
eq(R.layer_arg('elevated'),1); eq(R.layer_arg('ground'),0); eq(R.layer_arg(nil),nil)
fails(function() R.layer_arg('up') end,'rail_layer is ground or elevated')
-- the game's check: none asked, ground first then elevated
local c=R.check(surface,nil,'rail-signal',{x=-148.5,y=2.5},12,nil,true)
eq(c.ok,true); eq(c.layer,1)
c=R.check(surface,nil,'rail-signal',{x=-148.5,y=2.5},12,0,true)
eq(c.ok,false); has(c.why,'on the ground rail layer (its ghost check)'); has(c.why,'of 0 signal spots within 6 tiles on that layer, the game takes it on none now')
c=R.check(surface,nil,'rail-signal',{x=-148.5,y=2.5},0,1,false)
eq(c.ok,false); has(c.why,'facing north on the elevated rail layer; spots within 6 tiles the game takes it on now: (-148.5,2.5) facing west (elevated, beside elevated-straight-rail')
-- no direction: the facing of the spot there
local r=R.resolve(surface,nil,'rail-chain-signal',{x=-148.5,y=-0.5},nil,nil,true)
eq(r.direction,4); eq(r.layer,1); has(r.line,'facing east on the elevated rail layer (direction east: the signal spot there faces so)')
-- placements: the spots on that layer the game takes, nearest first; ground has none here
local p={surface=surface,position={x=-148,y=2}}
local pl=R.placements(p,{name='rail-signal',near={x=-148,y=2},radius=6,limit=50},prototypes.entity['rail-signal'])
eq(pl.count,12); eq(pl.placements[1].rail_layer,'elevated'); eq(pl.placements[1].position.y,2.5)
taken['-148.5,2.5']=true
pl=R.placements(p,{name='rail-signal',near={x=-148,y=2},radius=6,limit=50},prototypes.entity['rail-signal'])
eq(pl.count,11); eq(pl.refused,1)
eq(R.placements(p,{name='rail-signal',near={x=-148,y=2},radius=6,rail_layer='ground'},prototypes.entity['rail-signal']).count,0)
-- inspect's read
local sig={valid=true,type='rail-chain-signal',name='rail-chain-signal',position={x=-146.5,y=-0.5},rail_layer=1,signal_state=0,chain_signal_state=1,
  get_connected_rails=function() return {rails[3]} end}
local rd=R.read(sig)
eq(rd.rail_layer,'elevated'); eq(rd.rails[1].name,'elevated-straight-rail'); eq(rd.signal_state,'open'); eq(rd.state,'all_open')
has(rd.line,'rail-chain-signal (-146.5,-0.5) on the elevated rail layer, attached to elevated-straight-rail (-147,1); block open, chain all_open')
eq(R.read({valid=true,type='entity-ghost',ghost_type='rail-signal'}).note,'a ghost: its rail layer and rails are read once built')
eq(R.read({valid=true,type='assembling-machine'}),nil)
-- a ghost entry and a build entry take rail_layer
local A=dofile('mod/agent-harness_0.1.0/argshapes.lua')()
A.check('place_ghosts',{entities={{name='rail-signal',position={x=1,y=2},rail_layer='elevated'}}})
A.check('build',{builds={{item='rail-signal',position={x=1,y=2},rail_layer='elevated'}}})
print('d21_batch71 AG1 signals on a rail layer: ok')

-- d20 batch67 (operator d21 08:13). Run from the harness root: lua tests/d20_batch67.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end

-- AC1 (Astra #1609): platform names in free text, longest whole name first, names that are prefixes of others.
do
  local N=dofile('mod/agent-harness_0.1.0/namematch.lua')
  local cands={{name='Kestrel'},{name='Kestrel II'},{name='Kestrel IV'},{name='Kestrel IVa'},{name='Kestrel IVc'},
    {name='Limestone'},{name='Limestone-spare-unbuilt'},{name='Petrel'},{name='Petrel II'}}
  local function names(text)
    local t={}
    for k,m in ipairs(N.find(text,cands)) do t[k]=m.name end
    return table.concat(t,'|')
  end
  eq(names('Kestrel IVc refuel and Kestrel II ammo'),'Kestrel IVc|Kestrel II')
  eq(names('Kestrel to Aquilo'),'Kestrel')
  eq(names('Kestrel IV hub; Kestrel IVb hub'),'Kestrel IV|Kestrel','IVb is no name here: Kestrel stands before a space')
  eq(names('kestrel ii at Fulgora'),'Kestrel II','any case when the case differs')
  eq(names('Kestrels and KestrelII'),'','no whole name')
  eq(names('Limestone-spare-unbuilt, then Limestone'),'Limestone-spare-unbuilt|Limestone')
  eq(names('Petrel II/Petrel'),'Petrel II|Petrel')
  eq(names(nil),''); eq(names(''),'')
  -- one name in two cases: the case the game keeps first
  local two={{name='Wren',id=1},{name='wren',id=2}}
  eq(N.find('wren docks',two)[1].c.id,2); eq(N.find('Wren docks',two)[1].c.id,1); eq(N.find('WREN docks',two)[1].c.id,1)
  eq(#N.find('WREN docks',two),1,'one span, one name')
end
print('d20_batch67 AC1 name matcher: ok')

-- AC1: board_review {ownership}: a claim titled with a platform's whole name covers it ("Petrel II" is not "Petrel");
-- a claim's planet from its title is a whole planet name outside our platforms' names.
do
  game={tick=100000}
  local function plsurf(index,name) local s={name='platform-'..index,index=index}; s.platform={valid=true,index=index,name=name,surface=s}; return s end
  local p1,p2=plsurf(5,'Petrel'),plsurf(6,'Petrel II')
  local items={
    [5]={id=5,kind='claim',status='claimed',owner='astra',title='Petrel II ammo line',surface='nauvis',active_tick=99000},
    [6]={id=6,kind='claim',status='claimed',owner='sol',title='Petrel: rockets',surface='nauvis',active_tick=99000}}
  local st={board={items=items}}
  local force={platforms={p1.platform,p2.platform},logistic_networks={}}
  game.surfaces={}
  local C=dofile('mod/agent-harness_0.1.0/claims.lua'){state=function() return st end,crafters=function() return {} end,
    planets=function() return {'nauvis','gleba','fulgora'} end}
  local r=C.ownership({force=force},{})
  local by={}
  for _,s in ipairs(r.surfaces) do for _,row in ipairs(s.systems) do by[row.name or '']=row end end
  eq(by['Petrel'].claims,1); assert(by['Petrel'].line:find('#6 sol',1,true),by['Petrel'].line); assert(not by['Petrel'].line:find('#5',1,true),by['Petrel'].line)
  eq(by['Petrel II'].claims,1); assert(by['Petrel II'].line:find('#5 astra',1,true),by['Petrel II'].line)
  -- a claim from before claims had a surface: its title's planet
  game.forces={player={platforms={{valid=true,name='Gleba Express'},{valid=true,name='Fulgora Runner'}}}}
  local function surf(title) return C.surface_of({id=9,kind='claim',title=title,owner='luna'}) end
  eq(surf('Gleba Express refuel at Fulgora'),'fulgora','Gleba Express is a platform')
  eq(surf('Gleba landing power'),'gleba')
  eq(surf('Fulgora Runner hub at gleba, Gleba side'),'gleba','one planet named twice')
  eq(surf('Glebalike rows'),'nauvis','no whole planet name: the owner surface fallback')
  eq(surf('Gleba to Fulgora seeds'),'nauvis','two planets: the fallback')
  game=nil
end
print('d20_batch67 AC1 ownership and claim surfaces: ok')

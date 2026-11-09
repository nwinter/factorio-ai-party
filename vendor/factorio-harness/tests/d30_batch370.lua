-- d30 batch370 SF: preserve splitter ItemFilter conditions; report local outlet capacity.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s:find(t,1,true),s..' missing '..t) end
prototypes={item={['railgun-ammo']={},rocket={}},quality={normal={level=0},rare={level=2},legendary={level=4},hidden={hidden=true}}}
defines={}
local D=dofile('mod/agent-harness_0.1.0/details.lua'){}
local reads=0
local function belt(full)
 return {type='transport-belt',name='turbo-transport-belt',direction=0,get_transport_line=function(i)
  return {can_insert_at_back=function() return not full end,get_contents=function() return full and {{name='rocket',quality='normal',count=4}} or {} end}
 end}
end
local left,right=belt(true),belt(false)
local e={type='splitter',name='turbo-splitter',position={x=-18,y=-61.5},direction=0,bounding_box={{-19,-62},{-17,-61}},splitter_input_priority='none',splitter_output_priority='none',
 surface={find_entities_filtered=function(q)
  if q.area then return {} end
  reads=reads+1; eq(q.limit,1); eq(q.position.y,-62.5)
  return q.position.x==-18.5 and {left} or {right}
 end}}
local cases={
 {'railgun-ammo','normal','=', 'railgun-ammo'},
 {{name='railgun-ammo',quality='normal'},'normal','=', 'railgun-ammo'},
 {{name='railgun-ammo'},'any','none', 'railgun-ammo@any'},
 {'railgun-ammo@any','any','none','railgun-ammo@any'},
 {{name='railgun-ammo',quality='any'},'any','none','railgun-ammo@any'},
 {{name='railgun-ammo',quality='rare'},'rare','=', 'railgun-ammo@rare'},
 {{name='railgun-ammo',quality='normal',comparator='>='},'normal','>=','railgun-ammo@>=normal'},
 {'railgun-ammo@<=rare','rare','<=','railgun-ammo@<=rare'},
 {{name='railgun-ammo',quality='rare',comparator='≠'},'rare','!=','railgun-ammo@!=rare'},
}
for _,case in ipairs(cases) do
 local r=D.configure_splitter(e,{output_priority='right',filter=case[1]})
 eq(r.filter_quality,case[2]); eq(r.filter_comparator,case[3]); eq(r.filter,case[4])
 if case[2]=='any' then eq(e.splitter_filter.quality,nil) else eq(e.splitter_filter.quality,case[2]) end
 if case[3]=='none' then eq(e.splitter_filter.comparator,nil) else eq(e.splitter_filter.comparator,case[3]) end
 local r2=D.splitter(e); eq(r2.filter_quality,r.filter_quality); eq(r2.filter_comparator,r.filter_comparator)
 has(r.line,'filter quality: '..case[2]..'; comparator: '..case[3])
end
-- Bad conditions are refused before either priority or the saved filter changes.
for _,bad in ipairs({{name='railgun-ammo',quality='missing'},{name='railgun-ammo',quality='hidden'},
 {name='railgun-ammo',quality='normal',comparator='~'},{name='railgun-ammo',comparator='>='},
 {name='railgun-ammo',quality='any',comparator='='},{name='railgun-ammo',quality='normal',comparitor='='},
 'railgun-ammo@>=any','missing',3}) do
 local f=e.splitter_filter; local ok=pcall(D.configure_splitter,e,{input_priority='left',output_priority='left',filter=bad})
 eq(ok,false); eq(e.splitter_input_priority,'none'); eq(e.splitter_output_priority,'right'); eq(e.splitter_filter,f)
end
-- Native readback uses Unicode comparisons and sometimes prototype objects.
e.splitter_filter={name={name='railgun-ammo'},quality={name='rare'},comparator='≥'}
local r=D.splitter(e); eq(r.filter,'railgun-ammo@>=rare'); eq(r.filter_quality,'rare'); eq(r.filter_comparator,'≥')
local ghost={type='entity-ghost',ghost_name='turbo-splitter',ghost_type='splitter',position=e.position,direction=0,
 splitter_input_priority='none',splitter_output_priority='none'}
r=D.configure_splitter(ghost,{output_priority='right',filter='railgun-ammo@any'}); eq(r.ghost,true); eq(r.filter_quality,'any'); eq(D.splitter_outputs(ghost),nil)
-- Inspect: two tile reads, two surface lanes each. Full left and empty right are distinct facts.
D.configure_splitter(e,{filter={name='railgun-ammo',quality='normal'}})
reads=0; local out={}; D.inspect(e,out)
eq(reads,2); eq(out.splitter.filter_quality,'normal'); eq(out.splitter.filter_comparator,'=')
local lo,ro=out.splitter.outputs[1],out.splitter.outputs[2]
eq(lo.side,'left'); eq(lo.position.x,-18.5); eq(ro.side,'right'); eq(ro.position.x,-17.5)
for i=1,2 do eq(lo.lanes[i].can_insert_at_back,false); eq(lo.lanes[i].items[1].name,'rocket'); eq(ro.lanes[i].can_insert_at_back,true); eq(#ro.lanes[i].items,0) end
-- Missing targets and adjacent splitters carry no invented lane capacities.
e.surface.find_entities_filtered=function(q) return q.position and q.position.x==-17.5 and {{type='splitter',name='splitter',direction=4}} or {} end
local outlets=D.splitter_outputs(e); eq(outlets[1].name,'none'); eq(outlets[1].lanes,nil); eq(outlets[2].name,'splitter'); eq(outlets[2].lanes,nil)
for _,clear in ipairs({false,'none',''}) do r=D.configure_splitter(e,{filter=clear}); eq(r.filter,'none'); eq(r.filter_quality,nil); eq(r.filter_comparator,nil); eq(e.splitter_filter,nil) end
print('d30_batch370: splitter conditions, atomic refusal, ghosts and bounded outlet facts: ok')

-- Run from repository root: lua tests/nametags.lua
-- Bot name tags, colour tint and pixel avatars (nametags.lua, avatar.lua, data.lua)
-- against a fake engine. Pixel parity with avatar.js: node tools/stream/avatar_sprites_mod.js --check.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local parts=require('avatar_parts')
local avatar=require('avatar')(parts)
local n=0
local function check(a,b,m) n=n+1; eq(a,b,m) end

-- Data stage: one sprite per layer, cells inside the sheet, unique names.
data={extend=function(self,list) self.list=list end}
dofile('mod/agent-harness_0.1.0/data.lua')
check(#data.list,parts.count)
local names={}
for i,s in ipairs(data.list) do
  assert(not names[s.name]); names[s.name]=true
  check(s.width,parts.cell); assert(s.x+s.width<=parts.columns*parts.cell)
  check(s.filename,'__agent-harness__/graphics/avatar-parts.png')
end
check(data.list[parts.columns+1].y,parts.cell); check(data.list[parts.columns+1].x,0)

-- Same choices as avatar.js resolve() (values printed by PogAvatar.resolve).
local function hex(c) return string.format('#%02x%02x%02x',c[1],c[2],c[3]) end
local s=avatar.resolve('astra','#9977ff',nil)
check(s.base,'drone'); check(s.visor,'wide'); check(s.emblem,'leaf'); check(s.accessory,'pipe'); check(s.backdrop,'night'); check(hex(s.accent),'#3ee0ff')
s=avatar.resolve('sonnet',nil,nil)
check(s.helmet,'armor'); check(s.emblem,'rocket'); check(hex(s.color),'#b58cff'); check(hex(s.accent),'#ffb627')
s=avatar.resolve('grok','#1a1a1a',{base='robot',accent='#33ccff'})
check(s.base,'robot'); check(s.accessory,'horns'); check(s.backdrop,'glow'); check(hex(s.accent),'#33ccff')
check(avatar.hash('astra'),avatar.hash('astra')); check(avatar.hash(''),2166136261)

-- Fake engine.
local drawn={}
local function obj(kind,t) local o={id=#drawn+1,valid=true,kind=kind,args=t}; o.destroy=function() o.valid=false end; drawn[#drawn+1]=o; return o end
rendering={draw_text=function(t) return obj('text',t) end,draw_sprite=function(t) return obj('sprite',t) end,
  get_object_by_id=function(id) return drawn[id] end}
local sprites_valid=false
helpers={is_valid_sprite_path=function(path) return sprites_valid and path:find('^agent%-harness%-avatar%-')~=nil end}
local unit=0
local function character() unit=unit+1; return {valid=true,unit_number=unit,surface={index=1}} end
local bots={{index=1000001,name='astra',character=character()},{index=1000002,name='grok',character=character()}}
local profiles={}
local st={}
local function make()
  return require('nametags'){state=function() return st end,bots=function() return bots end,profile=function(i) return profiles[i] end,
    parts=parts,avatar=avatar}
end
package.loaded.nametags=nil
local tags=make()
local function live(kind,target) local out={} for _,o in ipairs(drawn) do if o.valid and o.kind==kind and o.args.target.entity==target then out[#out+1]=o end end return out end

-- A tag with glyph and display name over the character, in the profile colour; the character is tinted.
profiles[1000001]={display_name='Astra',glyph='A',color='#9977ff',rgb={r=0x99/255,g=0x77/255,b=1}}
tags.refresh(bots[1])
local c=bots[1].character
local t=live('text',c)
check(#t,1); check(t[1].args.text,'A Astra'); check(t[1].args.target.offset[2]<-1.5,true); check(t[1].args.use_rich_text,false)
check(t[1].args.color.b,1); check(c.color.r,0x99/255)
check(#live('sprite',c),0) -- an old world has no avatar sprites: tag only
check(tags.bubble_y(1000001)<t[1].args.target.offset[2]-0.4,true) -- bubbles start above the tag

-- No profile: the name and the avatar's default colour (what the overlay shows); dark colours are lifted for text.
tags.refresh(bots[2])
local g=bots[2].character
check(live('text',g)[1].args.text,'grok')
local spec=avatar.resolve('grok',nil,nil)
check(g.color.r,spec.color[1]/255)
profiles[1000002]={color='#1a1a1a',rgb={r=0x1a/255,g=0x1a/255,b=0x1a/255}}
tags.refresh(bots[2])
check(#live('text',g),1); check(live('text',g)[1].args.color.r>0.5,true); check(g.color.r,0x1a/255)

-- Bounded upkeep: nothing off the recheck tick; a changed profile, a respawned
-- character or a hot deploy (no records) is redrawn on the next one.
local before=#drawn
tags.tick(301); check(#drawn,before)
tags.tick(300); check(#drawn,before) -- up to date
profiles[1000001].glyph='🚀'
tags.tick(600); check(live('text',c)[1].args.text,'🚀 Astra'); check(#live('text',c),1)
local old=c; bots[1].character=character(); c=bots[1].character
tags.tick(900); check(#live('text',old),0); check(#live('text',c),1)
st.nametags=nil
for _,o in ipairs(drawn) do o.valid=false end
tags.tick(1200); check(#live('text',c),1); check(#live('text',g),1)

-- A world with the sprites: the avatar's layers ride above the tag, and bubbles go above the avatar.
sprites_valid=true
package.loaded.nametags=nil
tags=make()
tags.tick(1500) -- the sprites appearing changes the key: redrawn
local layers=avatar.layers('astra','#9977ff',nil)
local sp=live('sprite',c)
check(#sp,#layers); check(sp[1].args.sprite,layers[1].sprite); check(sp[#sp].args.target.offset[2]<t[1].args.target.offset[2],true)
check(sp[1].args.x_scale,1/(parts.cell*parts.scale/32))
check(tags.bubble_y(1000001)<sp[1].args.target.offset[2]-0.5,true)
-- Tinted layers carry the suit or accent; the fixed ones none.
local tinted,fixed=0,0
for _,l in ipairs(layers) do if l.tint then tinted=tinted+1 else fixed=fixed+1 end end
check(tinted>0 and fixed>0,true)

-- Death and removal drop the records (the engine already destroyed attached objects).
bots[2].character.valid=false
tags.tick(1800); check(st.nametags[1000002],nil)
table.remove(bots,1)
tags.tick(2100); check(st.nametags[1000001],nil); check(#live('sprite',c),0)

-- Space Age: no body while riding or aboard. The tag rides on the cargo pod (the pod is not tinted),
-- then over the platform hub, clear of its 8x8 body; a second rider stacks above; landing moves it to the body.
local carriers={}
package.loaded.nametags=nil
tags=require('nametags'){state=function() return st end,bots=function() return bots end,profile=function(i) return profiles[i] end,
  parts=parts,avatar=avatar,carrier=function(b) return carriers[b.index] end}
local pod={valid=true,unit_number=900,name='cargo-pod',type='cargo-pod',surface={index=2}}
carriers[1000002]=pod
tags.tick(2400); check(#live('text',pod),1); check(live('text',pod)[1].args.text,'grok'); check(pod.color,nil)
check(live('text',pod)[1].args.target.offset[2],-1.75-0.5); check(#live('sprite',pod),#avatar.layers('grok','#1a1a1a',nil))
local hub={valid=true,unit_number=901,name='space-platform-hub',type='space-platform-hub',surface={index=3}}
carriers[1000002]=hub; pod.valid=false
tags.tick(2700); check(#live('text',pod),0); check(#live('text',hub),1); check(live('text',hub)[1].args.target.offset[2]<-4,true)
bots[#bots+1]={index=1000003,name='astra'}
carriers[1000003]=hub
tags.tick(3000)
local rows=live('text',hub); check(#rows,2)
check(rows[2].args.target.offset[2]<rows[1].args.target.offset[2]-1,true)
check(tags.bubble_y(1000003)<rows[2].args.target.offset[2],true)
local landed=character(); bots[1].character=landed; carriers[1000002]=nil
tags.tick(3300); check(#live('text',landed),1); check(#live('text',hub),1); check(live('text',landed)[1].args.target.offset[2],-1.75)
carriers[1000003]=nil
tags.tick(3600); check(#live('text',hub),0); check(st.nametags[1000003],nil)
print('nametags: '..n..' assertions passed')

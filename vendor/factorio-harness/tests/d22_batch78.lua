package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or '')..': expected '..tostring(b)..', got '..tostring(a),2) end end

-- AN1 (#1809, Astra: Gleba had thousands of dropped items; inspect of an item-on-ground and scan's inventory and spoil
-- fields gave no stack): the stack as hovering it shows, and ground_items with the stalest freshness by item.
do
  local SPOIL={yumako=3600,['iron-plate']=0}
  local function stack(name,count,q,spoiled)
    local quality={name=q or 'normal'}
    return {valid=true,valid_for_read=true,name=name,count=count,quality=quality,spoil_percent=spoiled or 0,
      prototype={get_spoil_ticks=function(qq) assert(qq==quality); return SPOIL[name] end}}
  end
  local function ground(x,y,s) return {valid=true,type='item-entity',name='item-on-ground',position={x=x,y=y},stack=s} end
  local G=dofile('mod/agent-harness_0.1.0/groundstack.lua')
  local st=G.stack(ground(1,2,stack('yumako',3,'normal',0.385)))
  eq(st.name,'yumako'); eq(st.quality,'normal'); eq(st.count,3); eq(st.fresh,61)
  eq(G.text(st),'yumako*3'); eq(G.spoil_text(st),'yumako*3 61%'); eq(G.holds(st),'yumako*3, 61% fresh')
  st=G.stack(ground(1,2,stack('iron-plate',4,'uncommon')))
  eq(st.fresh,nil,'iron does not spoil'); eq(G.text(st),'iron-plate@uncommon*4'); eq(G.spoil_text(st),nil); eq(G.holds(st),'iron-plate@uncommon*4')
  eq(G.stack({valid=true,stack={valid_for_read=false}}),nil,'an empty stack'); eq(G.holds(nil),'empty')
  eq(G.stack({valid=true}),nil,'no stack at all')
  -- ground.lua's summary: by item, the stalest freshness of each that spoils
  local R=dofile('mod/agent-harness_0.1.0/ground.lua'){}
  local sum=R.summary({ground(0,0,stack('yumako',2,'normal',0.1)),ground(3,1,stack('yumako',5,'normal',0.5)),
    ground(1,1,stack('iron-plate',1))})
  eq(sum.stacks,3); eq(sum.items[1].name,'yumako'); eq(sum.items[1].count,7); eq(sum.items[1].fresh,50)
  eq(sum.items[2].name,'iron-plate'); eq(sum.items[2].fresh,nil)
end
print('d22_batch78 AN1 ground stacks: ok')

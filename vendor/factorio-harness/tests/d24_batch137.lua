-- d24 batch137 PI1 (Sol #2107): Petrel at Nauvis kept all 1980 calcite under calcite 200..inf from nauvis (and 0..inf
-- from gleba, 2000..2500 from vulcanus) while the pad asked 2000; shipment said 1776 would go down. The rule 2.0.77
-- showed on a copy of world n: only active sections importing from the stop's planet count, their maxes add up, an
-- infinite max keeps it all, a finite max sends down all above it asked or not, an item no such section names goes
-- down as far as the pads ask.
-- Run from the harness root: lua tests/d24_batch137.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
local function secs(list) return {sections_count=#list,get_section=function(i) return list[i] end} end
local function slot(min,max,from) return {value={name='calcite'},min=min,max=max,import_from=from} end
-- Sol's sections: kept all at Nauvis, whatever the pad asks
local sol=secs({{active=true,filters={slot(200,nil,'nauvis')}},{active=true,filters={}},{active=true,filters={}},{active=true,filters={slot(0,nil,'gleba')}},
  {active=true,filters={slot(2000,2500,'vulcanus')}}})
local k=F.hub_keeps_at(sol,'nauvis')
local n,row=F.hub_gives(k,'calcite',1980,2000)
eq(n,0,'before: 1776 forecast'); eq(F.keep_text(row),'hub section 1 keeps calcite 200..inf at nauvis')
-- Sol's change to 200..200: all above 200 goes down
n=F.hub_gives(F.hub_keeps_at(secs({{active=true,filters={slot(200,200,'nauvis')}},{active=true,filters={slot(2000,2500,'vulcanus')}}}),'nauvis'),'calcite',1980,2000)
eq(n,1780)
-- sections for other planets keep nothing here: the pads' ask
n,row=F.hub_gives(F.hub_keeps_at(secs({{active=true,filters={slot(0,nil,'gleba'),slot(2000,2500,'vulcanus')}}}),'nauvis'),'calcite',1980,1200)
eq(n,1200); eq(row,nil)
-- two sections for the planet: maxes add up (100..300 and 200..400 kept 700)
n,row=F.hub_gives(F.hub_keeps_at(secs({{active=true,filters={slot(100,300,'nauvis')}},{active=true,filters={slot(200,400,'nauvis')}}}),'nauvis'),'calcite',1500,2000)
eq(n,800); has(F.keep_text(row),'hub section 1 keeps calcite 100..300 at nauvis; hub section 2 keeps calcite 200..400 at nauvis')
-- a finite max sends down with no pad asking (200..500: 1000 of 1500 went)
eq((F.hub_gives(F.hub_keeps_at(secs({{active=true,filters={slot(200,500,'nauvis')}}}),'nauvis'),'calcite',1500,0)),1000)
-- no section: the pads' ask only, none without one
eq((F.hub_gives({},'calcite',1500,2000)),1500); eq((F.hub_gives({},'calcite',1500,0)),0)
-- a section switched off counts for nothing
eq((F.hub_gives(F.hub_keeps_at(secs({{active=false,filters={slot(200,nil,'nauvis')}}}),'nauvis'),'calcite',1500,2000)),1500)
print('d24_batch137 PI1 hub keep rule: ok')

#!/usr/bin/env python3
"""Strict native export fields and versioned analyst math, offline."""
import json, pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'tools/analyst'))
import kb, dump_prototypes as dp

def main():
    assert kb.product_mean({'amount':1,'probability':0})==0
    assert abs(kb.product_mean({'amount':1,'independent_probability':.5,'shared_probability':{'min':.2,'max':.6}})-.2)<1e-9
    assert kb.product_mean({'amount':99,'expected_amount':0})==0
    assert abs(kb.product_mean({'amount':4,'extra_count_fraction':.5,'independent_probability':.2,'shared_probability':{'min':.2,'max':.6}})-.36)<1e-9
    code=dp.command('recipes',1).removeprefix('/silent-command ')
    pre="""
local r={name='test',categories={'secondary','primary'},energy=1,enabled=true,hidden=false,ingredients={},products={{name='ore',type='item',amount=1,independent_probability=1,shared_probability={min=0,max=.007}}},get_product_amount=function(i,p) assert(i==1 and p==0);return .007 end}
setmetatable(r,{__index=function(_,k) error('removed or missing: '..k) end})
prototypes={recipe={test=r}};rcon={print=function() end};helpers={table_to_json=function(v) local r=v.items[1];assert(r.category==nil and r.categories[2]=='primary');assert(r.products[1].expected_amount==.007 and r.products[1].shared_probability.max==.007);return 'ok' end}
"""
    subprocess.run(['lua','-'],input=pre+code,text=True,check=True)
    data=root/'tools/analyst/kb/space-age-2.1.24'
    assert json.loads((data/'version.json').read_text())['base']=='2.1.24'
    k=kb.KB('space-age-2.1.24')
    assert abs(kb.product_mean(k.recipes['uranium-processing']['products'][0])-.007)<1e-9
    assert 'recycler' in k.machines_for(['missing','recycling'])
    assert k.items['coal']['fuel_categories']==['chemical']
    assert k.items['quality-module-3']['effects_by_quality']['legendary']['quality']==.0625
    assert all('categories' in r and all('expected_amount' in p for p in r['products']) for r in k.recipes.values())
    assert k.entities['boiler']['fluid']['fluid_boxes'][0]['volume']==200
    print('port21 KB: strict native categories/means, zero chance, fuel lists, quality and fluid volume passed')
if __name__=='__main__':main()

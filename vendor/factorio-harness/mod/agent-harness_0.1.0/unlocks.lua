-- Technologies and the buildings they unlock, for "researched, none built"
-- (research.lua, the shift block) and the stream hosts' unused_unlocks
-- (pog tools/stream/model.py reads this file). Only buildings pog's score
-- counts (tools/pog.py SCORE_LUA). One entry per line:
-- {technology, {buildings}, label}.
return {
  {'logistic-robotics', {'roboport'}, 'roboports'},
  {'construction-robotics', {'roboport'}, 'roboports'},
  {'logistic-system', {'requester-chest', 'buffer-chest'}, 'requester chests'},
  {'electric-energy-accumulators', {'accumulator'}, 'accumulators'},
  {'solar-energy', {'solar-panel'}, 'solar panels'},
  {'gun-turret', {'gun-turret'}, 'gun turrets'},
  {'laser-turret', {'laser-turret'}, 'laser turrets'},
  {'stone-wall', {'stone-wall'}, 'walls'},
  {'effect-transmission', {'beacon'}, 'beacons'},
  {'oil-processing', {'pumpjack', 'oil-refinery'}, 'pumpjacks or refineries'},
  {'advanced-material-processing-2', {'electric-furnace'}, 'electric furnaces'},
  {'automation-3', {'assembling-machine-3'}, 'assembling machine 3s'},
  {'logistics-2', {'fast-transport-belt'}, 'fast belts'},
  {'logistics-3', {'express-transport-belt'}, 'express belts'},
  {'railway', {'locomotive'}, 'trains'},
  {'nuclear-power', {'nuclear-reactor'}, 'nuclear reactors'},
  {'uranium-processing', {'centrifuge'}, 'centrifuges'},
  {'rocket-silo', {'rocket-silo'}, 'a rocket silo'},
  {'space-platform', {'space-platform-hub'}, 'a space platform'},
  {'foundry', {'foundry'}, 'foundries'},
  {'electromagnetic-plant', {'electromagnetic-plant'}, 'electromagnetic plants'},
  {'big-mining-drill', {'big-mining-drill'}, 'big mining drills'},
  {'recycling', {'recycler'}, 'recyclers'},
}

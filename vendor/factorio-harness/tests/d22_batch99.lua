-- d22 batch99 contracts (BI5, viewer Aurora site:4333: "Asterion still shows stalled while Astra's timed flight watch is
-- running"). lua tests/d22_batch99.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- flightwatch.card: the setter's flight watches as status work rows (armed, running, done until read)
do
  game={tick=10000}
  local st={flightwatch={seq=4,events={},eseq=0,list={
    {id=1,platform='Asterion',setter='astra',set=9000,from='departure',minutes=90,state='armed'},
    {id=2,platform='Asterion',setter='astra',set=100,start=200,until_tick=200+120*3600,minutes=120,state='watching'},
    {id=3,platform='Kestrel II',setter='sol',set=100,state='armed',minutes=120},
    {id=4,platform='Cinder',setter='astra',set=100,start=200,ended=900,state='done',read_tick=950,minutes=10}}}}
  local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end}
  local rows=F.card('astra')
  eq(#rows,2,'astra\'s armed and running ones; sol\'s and the read one left out')
  eq(rows[1].id,'flight#1'); eq(rows[1].kind,'flight_watch'); eq(rows[1].scope,'Asterion'); eq(rows[1].state,'armed')
  eq(rows[1].line,'flight watch #1 on Asterion: waiting for its next departure, then at most 90 min'); eq(rows[1].minutes,90)
  eq(rows[2].state,'running'); eq(rows[2].start_tick,200); eq(rows[2].end_tick,200+120*3600)
  eq(rows[2].line,'flight watch #2 on Asterion: watching until its next arrival or tick 432200 (1h57m17s more), 0 samples')
  eq(F.card('luna'),nil)
  st.flightwatch=nil; eq(F.card('astra'),nil)
  game=nil
  print('BI5 flight watches on the status work rows: ok')
end

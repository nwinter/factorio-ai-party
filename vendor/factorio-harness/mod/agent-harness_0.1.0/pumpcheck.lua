-- Platform layout checks: declared pump enable conditions and their circuit
-- connections. Only pumps in the plan are read; no platform-wide scan.
return function(api)
  local M={}
  local function try(fn) local ok,v=pcall(fn);if ok then return v end end
  local function key(p)
    if type(p)~='table' then return nil end
    local x,y=p.x or p[1],p.y or p[2]
    return type(x)=='number' and type(y)=='number' and string.format('%.4f,%.4f',x,y) or nil
  end
  function M.plan(p,entries)
    local rows,wires,n={}, {},0
    for _,e in ipairs(entries) do
      for _,w in ipairs(e.wires or {}) do
        if not w.disconnect and (w.color=='red' or w.color=='green') then
          local a,b=key(e.position),key(w.to)
          if a then wires[a]=(wires[a] or 0)+1 end
          if b and b~=a then wires[b]=(wires[b] or 0)+1 end
        end
      end
    end
    for _,e in ipairs(entries) do
      local proto=prototypes.entity[e.name or '']
      if proto and proto.type=='pump' then
        n=n+1
        if n<=64 then
          local built=try(function() return p.surface.find_entities_filtered{position=e.position,name=e.name,force=p.force,limit=1}[1] end)
          local current=built and api.read(built) or nil
          local enabled=current and current.enable
          local spec=e.circuit
          if spec and spec.enable~=nil then enabled=spec.enable end
          if spec and spec.settings and spec.settings.circuit_enable_disable~=nil then enabled=spec.settings.circuit_enable_disable end
          if enabled then
            local wired=current and current.networks and next(current.networks)~=nil
            local planned=wires[key(e.position)] or 0
            if not wired then
              rows[#rows+1]=string.format('pump (%g,%g): enable condition has no connected circuit wire%s',e.position.x,e.position.y,
                planned>0 and '; '..planned..' circuit wire(s) declared in this plan, not connected yet' or '; no red or green wire declared in this plan')
            end
          end
        end
      end
    end
    if n>64 then rows[#rows+1]=(n-64)..' further pumps not checked (limit 64)' end
    return #rows>0 and rows or nil
  end
  return M
end

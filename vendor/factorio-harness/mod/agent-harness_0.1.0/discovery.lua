-- Private-world information boundary. Ordinary worlds and trusted broadcast reads stay unchanged.
return function(api)
  local M={}
  local function teams() return (api.state().mt or {}).teams or {} end
  function M.active(reader) return teams()[reader]~=nil end
  function M.known(reader,other)
    if reader==other then return true end
    local first=(api.state().mt or {}).first or {}
    for _,kind in ipairs{'chart ','shot '} do
      if first[kind..reader..'>'..other] or first[kind..other..'>'..reader] then return true end
    end
    return false
  end
  function M.open(reader)
    for other in pairs(teams()) do if other~=reader and M.known(reader,other) then return true end end
    return false
  end
  -- Identity only: no position, activity, speech or unknown third-party roster.
  function M.roster(reader,other)
    if not M.active(reader) or not M.known(reader,other) then return {} end
    local out={};local models=(api.state().mt or {}).roster or {}
    for _,b in ipairs(api.bots and api.bots() or {}) do if b.force==other then
      local p=api.profile and api.profile(b.index) or {}
      out[#out+1]={name=b.name,team=other,display_name=p.display_name,model=models[b.name] and models[b.name].model}   -- (mt309 note-mt309-w) the team with the name: two teams may share a display name
    end end
    table.sort(out,function(a,b) return a.name<b.name end)
    return out
  end
  local function word(text,name)
    return text:lower():find('%f[%w_%-]'..name:lower():gsub('([^%w])','%%%1')..'%f[^%w_%-]')~=nil
  end
  local function hidden(reader)
    local names,known_names={},{}
    for _,b in ipairs(api.bots and api.bots() or {}) do
      if M.known(reader,b.force) then
        known_names[b.name:lower()]=true
        local p=api.profile and api.profile(b.index) or {}
        if p.display_name and p.display_name~='' then known_names[p.display_name:lower()]=true end
      end
    end
    for name in pairs(teams()) do if name~=reader and not M.known(reader,name) then names[#names+1]=name end end
    for _,b in ipairs(api.bots and api.bots() or {}) do
      if b.force~=reader and teams()[b.force] and not M.known(reader,b.force) then
        if not known_names[b.name:lower()] then names[#names+1]=b.name end
        local p=api.profile and api.profile(b.index) or {}
        if p.display_name and p.display_name~='' and not known_names[p.display_name:lower()] then names[#names+1]=p.display_name end
      end
    end
    return names
  end
  local function contains(text,names)
    for _,name in ipairs(names) do if word(text,name) then return true end end
    return false
  end
  function M.hidden_text(text,reader)
    return contains(text,hidden(reader))
  end
  function M.viewer(reader,name,text)
    return not M.active(reader) -- Nick d41: audience is never game input, even after contact.
  end
  function M.project(value,reader)
    if not M.active(reader) then return value end
    local open=M.open(reader)
    local hidden_names=hidden(reader)
    local function ownership(s,name)
      local pattern=name:lower():gsub('([^%w])','%%%1')
      return s==name:lower() or s:match('^'..pattern.."[%s:']")
        or s:match('force[ =:]+'..pattern..'%f[^%w_%-]') or s:match('team[ =:]+'..pattern..'%f[^%w_%-]')
        or s:match('%f[%w_%-]'..pattern..'%s+team%f[^%w_%-]') or (s:find('pact',1,true) and word(s,name))
    end
    local function text(s)
      local lower=s:lower()
      if not open and (lower:find('mt%-coinage') or lower:find('mt%-trading%-post') or lower:find('mt%-coin') or lower:find('mt%-shipment')) then return nil end
      if lower:match('%f[%a]viewer [^:]+:') then return nil end -- old saves' viewer trailers
      for _,name in ipairs(hidden_names) do
        if word(s,name) and (not teams()[name] or ownership(lower,name)) then return nil end
      end
      if not open then
        if ownership(lower,reader) then
          s=s:gsub('[%w_%-]+',function(token) return token:lower()==reader:lower() and 'ours' or token end)
        end
        if lower:find('another team',1,true) or lower:find('other teams',1,true) or lower:find('contact with',1,true) then return nil end
      end
      return s
    end
    local function project(v,depth,context)
      if type(v)=='string' then
        if context=='base-model' then return v end -- verified against the operator roster below
        if context=='wire-selection' and (v=='red' or v=='green' or v=='red+green') then return v end
        return text(v)
      end
      if type(v)~='table' then return v end
      assert(depth<48,'response nesting exceeds limit')
      if not open and type(v.name)=='string' and (v.name=='mt-coinage' or v.name=='mt-trading-post' or v.name=='mt-coin' or v.name=='mt-shipment') then return nil end
      if v.viewer or v.source=='site' or v.source=='youtube' then return nil end -- old saves too
      -- Omit entire foreign entity/event rows rather than leaving coordinates with an anonymous owner.
      for _,key in ipairs{'force','force_name','team','owner_force','attacker_force','seller','buyer','from_team','to_team'} do
        local owner=v[key]
        if type(owner)=='string' and teams()[owner] and not M.known(reader,owner) then return nil end
      end
      for _,key in ipairs{'agent','from','by','owner','name','display_name'} do
        local identity=v[key]
        if type(identity)=='string' then
          for _,name in ipairs(hidden_names) do if identity:lower()==name:lower() then return nil end end
        end
      end
      local out={}
      if #v>0 then
        for _,x in ipairs(v) do local y=project(x,depth+1);if y~=nil then out[#out+1]=y end end
      else
        for k,x in pairs(v) do
          local key=k
          -- Circuit wire colours are physical controls, not force identities. Keep
          -- only these schema positions; ownership rows and arbitrary text still filter.
          if type(k)=='string' and not (context=='wire-map' and (k=='red' or k=='green')) then key=text(k) end
          if key~=nil then
            local child=k=='circuit' and 'circuit' or nil
            if k=='model' then
              local models=(api.state().mt or {}).roster or {}
              for _,b in ipairs(api.bots and api.bots() or {}) do
                if b.name==v.name and M.known(reader,b.force) and models[b.name] and models[b.name].model==x then child='base-model' end
              end
            end
            if context=='circuit' then
              if k=='wires' or k=='networks' then child='wire-map'
              elseif k=='settings' then child='circuit-settings' end
            elseif context=='circuit-settings' and (k=='input_networks' or k=='output_networks') then child='wire-selection' end
            local y=project(x,depth+1,child)
            if k=='force' and x==reader and not open then y=nil end
            if y~=nil then out[key]=y end
          end
        end
      end
      return out
    end
    return project(value,0)
  end
  return M
end

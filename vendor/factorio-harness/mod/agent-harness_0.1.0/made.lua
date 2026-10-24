-- (d24 batch141 PM1, Sol #2125: requests set Meridian-V's bioflux to 20..30, then its reply failed in sends_down and the
-- call answered a plain failure, exit 1, the change made) a mutating action marks each change it makes (mark); a wrapped
-- action that fails after a mark answers the changes and the error as its reply, and one that fails before any mark
-- fails as before. A wrapped action called inside another adds its marks to the outer one's.
return function(api)
  local M={}
  local now
  function M.mark(text) if now then now[#now+1]=tostring(text) end end
  function M.wrap(handlers,names)
    for _,name in ipairs(names) do
      local inner=handlers[name]
      if inner then
        handlers[name]=function(p,a)
          local outer=now
          now={}
          local ok,r=pcall(inner,p,a)
          local made=now
          now=outer
          if outer then for _,t in ipairs(made) do outer[#outer+1]=t end end
          if ok then return r end
          if #made==0 then error(r,0) end
          return {change_made=made,reply_failed=api.reason and api.reason(r) or tostring(r),
            reply_failed_note='the change in change_made was made; after it the call failed with reply_failed: the rest of the call and its reply did not run'}
        end
      end
    end
  end
  return M
end

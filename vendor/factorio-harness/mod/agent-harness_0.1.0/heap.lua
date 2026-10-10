-- Binary min-heap on node.f, shared by the belt and pipe routers' A*.
local M={}
function M.push(heap,node)
  heap[#heap+1]=node
  local i=#heap
  while i>1 do
    local parent=math.floor(i/2)
    if heap[parent].f<=node.f then break end
    heap[i]=heap[parent]; i=parent
  end
  heap[i]=node
end
function M.pop(heap)
  local top,last=heap[1],heap[#heap]
  heap[#heap]=nil
  local n=#heap
  if n>0 then
    local i=1
    while true do
      local child=i*2
      if child>n then break end
      if child<n and heap[child+1].f<heap[child].f then child=child+1 end
      if heap[child].f>=last.f then break end
      heap[i]=heap[child]; i=child
    end
    heap[i]=last
  end
  return top
end
return M

local _getter = function(attr)
  return function(self)
    return self:getattr(attr)
  end
end

local _simple_setter = function(attr)
  return function(self, val)
    return self:setattr(attr, val)
  end
end

local _indexed_setter = function(attr)
  return function(self, val)
    assert(
      (type(val) == "string") or
      (type(val) == "number")
    )
    local old_val = self["get_" .. attr](self)
    if old_val then
      self.model.R:hdel(self.model:rk("_by_" .. attr), val)
    end
    self.model.R:hset(self.model:rk("_by_" .. attr), val, self.id)
    self:setattr(attr, val)
  end
end

local _resolver = function(attr)
  return function(cls, val)
    assert(type(val) == "string")
    return tonumber(cls.R:hget(cls:rk("_by_" .. attr), val))
  end
end

local _indexed_getter = function(attr)
  return function(cls, val)
    assert(type(val) == "string")
    local id = cls["resolve_" .. attr](cls, val)
    if id then
      return cls:new(id)
    else return nil end
  end
end

local toboolean = function(x) -- for resty-redis
  return x and x ~= 0
end

local rk = function(cls, ...)
  return table.concat({cls.prefix, cls.name, ...}, ":")
end

local used_name = function(cls, name)
  return (
    (name == "id") or
    (cls.attributes[name]) or
    (cls.nn_associations[name])
  )
end

local add_attribute = function(cls, attr)
  assert(not used_name(cls, attr))
  cls.attributes[attr] = true
  cls.methods["get_" .. attr] = _getter(attr)
  cls.methods["set_" .. attr] = _simple_setter(attr)
end

local add_index = function(cls, attr)
  assert(
    cls.attributes[attr] and
    (not cls.indexed[attr])
  )
  cls.indexed[attr] = true
  cls.methods["set_" .. attr] = _indexed_setter(attr)
  cls.m_methods["resolve_" .. attr] = _resolver(attr)
  cls.m_methods["get_by_" .. attr] = _indexed_getter(attr)
end

local new = function(cls, id)
  id = assert(tonumber(id))
  if not cls.obj_cache[id] then
    local r = {
      id = id,
      model = cls,
      attr_cache = {},
      coll_cache = {},
    }
    cls.obj_cache[id] = setmetatable(r, {__index=cls.methods})
  end
  return cls.obj_cache[id]
end

local next_id = function(cls)
  return cls.R:incr(cls:rk("_next_id"))
end

local mhget_script = [[
  local r = {}
  local field = ARGV[1]
  for i=1,#KEYS do
    r[i] = redis.call("hget", KEYS[i], field)
  end
  return r
]]

local _mhget_scripting = function(R, field, ks)
  local n = #ks
  ks[n+1] = field
  local r = R:eval(mhget_script, n, unpack(ks))
  ks[n+1] = nil
  return r
end

local _mhget_base = function(R, field, ks)
  local r = {}
  for i=1,#ks do
    r[i] = R:hget(ks[i], field)
  end
  return r
end

local mhget = function(R, field, ks)
  return _mhget_scripting(R, field, ks)
end

local msmembers_script = [[
  local r = {}
  for i=1,#KEYS do
    r[i] = redis.call("smembers", KEYS[i])
  end
  return r
]]

local _msmembers_scripting = function(R, ks)
  local r = R:eval(msmembers_script, #ks, unpack(ks))
  return r
end

local _msmembers_base = function(R, ks)
  local r = {}
  for i=1,#ks do
    r[i] = R:smembers(ks[i])
  end
  return r
end

local msmembers = function(R, ks)
  return _msmembers_scripting(R, ks)
end

local all_with_ids = function(cls, ids, params)
  assert(type(ids) == "table")
  params = params or {}
  assert(type(params) == "table")
  local sort = params.sort
  local prefetch_attrs = params.prefetch_attrs or {}
  local prefetch_colls = params.prefetch_colls or {}
  local r = {}
  for i=1,#ids do r[i] = cls:new(ids[i]) end
  local s, n = #r, 500
  local ks, vs, attr, last
  for i=1,#r,n do
    ks = {}
    last = math.min(i+n-1,s)
    for j=i,last do
      ks[j-i+1] = r[j]:rk()
    end
    for k=1,#prefetch_attrs do
      attr = prefetch_attrs[k]
      vs = mhget(cls.R, attr, ks)
      for j=i,last do
        if vs[j-i+1] then
          r[j]:cache_setattr(attr, vs[j-i+1])
        end
      end
    end
    for k=1,#prefetch_colls do
      coll = prefetch_colls[k]
      ks = {}
      for j=i,last do
        ks[j-i+1] = r[j]:rk(coll)
      end
      vs = msmembers(cls.R, ks)
      for j=i,last do
        if vs[j-i+1] then
          r[j]:cache_setcoll(coll, vs[j-i+1])
        end
      end
    end
  end
  if not sort then return r end
  if type(sort) == "string" then
    local _getprop = sort
    sort = {
      function(self) return self[_getprop](self) end,
      function(a, b) return a < b end,
    }
  end
  assert(type(sort) == "table")
  local getprop = sort[1]
  if type(getprop) == "string" then
    getprop = function(self) return self[getprop](self) end
  end
  assert(type(getprop) == "function")
  local cmp = sort[2] or function(a, b) return a < b end
  assert(type(cmp) == "function")
  local t = {}
  for i=1,#r do t[i] = {getprop(r[i]), r[i]} end
  local _cmp = function(a, b) return cmp(a[1], b[1]) end
  table.sort(t, _cmp)
  for i=1,#t do r[i] = t[i][2] end
  return r
end

local all = function(cls, params)
  local ids = cls.R:smembers(cls:rk("_all"))
  return cls:all_with_ids(ids, params)
end

local exists = function(cls, id)
  assert(type(id) == "number")
  return toboolean(cls.R:sismember(cls:rk("_all"), id))
end

local create = function(cls, t)
  for attr,_ in pairs(cls.indexed) do
    local x = assert(t[attr])
    assert(not cls["resolve_" .. attr](cls, attr))
  end
  local r = cls:new( cls:next_id() )
  cls.R:sadd(cls:rk("_all"), r.id)
  for attr,_ in pairs(cls.attributes) do
    if t[attr] then r["set_" .. attr](r, t[attr]) end
  end
  return r
end

local export = function(cls)
  local r = cls:all()
  for i=1,#r do r[i] = r[i]:export() end
  return r
end

base_m_methods = function()
  return {
    rk = rk,
    add_attribute = add_attribute,
    add_index = add_index,
    new = new,
    next_id = next_id,
    sort_by_attr = sort_by_attr,
    all_with_ids = all_with_ids,
    all = all,
    exists = exists,
    create = create,
    export = export,
  }
end

local rk = function(self, ...)
  return table.concat({self.model:rk(self.id), ...}, ":")
end

local getattr = function(self, attr)
  assert(type(attr) == "string")
  if not self.attr_cache[attr] then
    self.attr_cache[attr] = {self.model.R:hget(self:rk(), attr)}
  end
  return self.attr_cache[attr][1]
end

local cache_setattr = function(self, attr, val)
  assert(type(attr) == "string")
  assert(
    (type(val) == "string") or
    (type(val) == "number")
  )
  self.attr_cache[attr] = {val}
end

local cache_setcoll = function(self, coll, val)
  assert(type(coll) == "string")
  assert(type(val) == "table")
  self.coll_cache[coll] = {val}
end

local setattr = function(self, attr, val)
  cache_setattr(self, attr, val)
  self.model.R:hset(self:rk(), attr, val)
end

local delattr = function(self, attr)
  assert(type(attr) == "string")
  self.attr_cache[attr] = {}
  self.model.R:hdel(self:rk(), attr)
end

local check_attributes = function(self, t)
  for k,_ in pairs(self.model.attributes) do
    if self["get_" .. k](self) ~= t[k] then
      return false
    end
  end
  return true
end

local export = function(self)
  local r = {}
  r.id = self.id
  for k,_ in pairs(self.model.attributes) do
    r[k] = self["get_" .. k](self)
  end
  for k,_ in pairs(self.model.nn_associations) do
    r[k] = self.model.R:smembers(self:rk(k))
  end
  return r
end

local exists = function(self)
  return self.model:exists(self.id)
end

local base_methods = function()
  return {
    rk = rk,
    getattr = getattr,
    setattr = setattr,
    delattr = delattr,
    cache_setattr = cache_setattr,
    cache_setcoll = cache_setcoll,
    check_attributes = check_attributes,
    export = export,
    exists = exists,
  }
end

local m_new = function(t)
  assert(
    (type(t.name) == "string") and
    (type(t.prefix) == "string") and
    t.redis
  )
  local r = {
    R = t.redis,
    prefix = t.prefix,
    name = t.name,
    attributes = {},
    indexed = {},
    nn_associations = {},
    methods = base_methods(),
    m_methods = base_m_methods(),
    obj_cache = {},
  }
  r = setmetatable(r, {__index=r.m_methods})
  return r
end

local _nn_assoc_create = function(master_collection, slave_collection)
  return function(self, m)
    local R = assert(self.model.R)
    assert(
      (type(m) == "table")
      and tonumber(m.id)
    )
    self.coll_cache[master_collection] = nil
    m.coll_cache[slave_collection] = nil
    R:sadd(self:rk(master_collection), m.id)
    R:sadd(m:rk(slave_collection), self.id)
  end
end

local _nn_assoc_remove = function(master_collection, slave_collection)
  return function(self, m)
    local R = assert(self.model.R)
    assert(
      (type(m) == "table")
      and tonumber(m.id)
    )
    self.coll_cache[master_collection] = nil
    m.coll_cache[slave_collection] = nil
    R:srem(self:rk(master_collection), m.id)
    R:srem(m:rk(slave_collection), self.id)
  end
end

local _nn_assoc_check = function(master_collection)
  return function(self, m)
    local R = assert(self.model.R)
    assert(
      (type(m) == "table")
      and tonumber(m.id)
    )
    return toboolean(R:sismember(self:rk(master_collection), m.id))
  end
end

local _nn_assoc_get_collection = function(cls, collection)
  return function(self, params)
    if not self.coll_cache[collection] then
      self.coll_cache[collection] = {
        self.model.R:smembers(self:rk(collection))
      }
    end
    local ids = self.coll_cache[collection][1]
    return cls:all_with_ids(ids, params)
  end
end

local _nn_assoc_count_collection = function(cls, collection)
  return function(self)
    if self.coll_cache[collection] then
      return #self.coll_cache[collection][1]
    end
    return self.model.R:scard(self:rk(collection))
  end
end

local add_nn_assoc = function(t)
  assert(
    (type(t.master) == "table") and
    (type(t.slave) == "table") and
    (type(t.assoc_create) == "string") and
    (type(t.assoc_remove) == "string") and
    (type(t.assoc_check) == "string") and
    (type(t.master_collection) == "string") and
    (type(t.slave_collection) == "string")
  )
  assert(not used_name(t.master, t.master_collection))
  t.master.nn_associations[t.master_collection] = true
  t.master.methods[t.assoc_create] = _nn_assoc_create(
    t.master_collection, t.slave_collection
  )
  t.master.methods[t.assoc_remove] = _nn_assoc_remove(
    t.master_collection, t.slave_collection
  )
  t.master.methods[t.assoc_check] = _nn_assoc_check(
    t.master_collection
  )
  t.master.methods[t.master_collection] = _nn_assoc_get_collection(
    t.slave, t.master_collection
  )
  t.slave.methods[t.slave_collection] = _nn_assoc_get_collection(
    t.master, t.slave_collection
  )
  t.master.methods["nb_" .. t.master_collection] = _nn_assoc_count_collection(
    t.slave, t.master_collection
  )
  t.slave.methods["nb_" .. t.slave_collection] = _nn_assoc_count_collection(
    t.master, t.slave_collection
  )
end

return {
  new = m_new,
  add_nn_assoc = add_nn_assoc,
}

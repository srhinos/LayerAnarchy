local _, LA = ...

local Stats = {}
LA.Stats = Stats

local HOUR, EVENTS_MAX, KEYS_MAX, ASK_GAP = 3600, 500, 1000, 60
local SKIPPED = "skipped "
local EMPTY = {}

local s
local watched = false
local view = { ground = {}, flying = {} }

local function changed() if watched then LA.Refresh() end end

local function sessionWindow() return LA.Setting("statsWindow") == "session" end

local function windowStart()
  if sessionWindow() then return s.since end
  return time() - HOUR
end

local function keepFrom(t) return math.min(s.since, t - HOUR) end

local function trim(list, from)
  local drop = 0
  while list[drop + 1] and list[drop + 1].at < from do drop = drop + 1 end
  if drop == 0 then return end
  for i = 1, #list do list[i] = list[i + drop] end
end

local function trimAll(from)
  for kind, list in pairs(s.recent) do
    trim(list, from)
    if not list[1] then s.recent[kind] = nil end
  end
end

local function prune(set, from)
  local n = 0
  for key, at in pairs(set) do
    if at < from then set[key] = nil else n = n + 1 end
  end
  return n
end

local function dropOldest(set)
  local oldest, oldestAt
  for key, at in pairs(set) do
    if not oldestAt or at < oldestAt then oldest, oldestAt = key, at end
  end
  if oldest then set[oldest] = nil end
end

local function see(group, netId, key)
  if not (netId and key) or key == LA.MyKey() then return end
  local set = group[netId] or {}
  group[netId] = set
  local t = time()
  if not set[key] and prune(set, keepFrom(t)) >= KEYS_MAX then dropOldest(set) end
  set[key] = t
  changed()
end

function Stats.Heard(netId, key) see(s.talking, netId, key) end

function Stats.Offered(netId, key) see(s.hosts, netId, key) end

function Stats.Note(kind, value)
  local t = time()
  trimAll(t - HOUR)
  local list = s.recent[kind] or {}
  s.recent[kind] = list
  if #list >= EVENTS_MAX then table.remove(list, 1) end
  list[#list + 1] = { at = t, value = value }
  local e = s.session[kind] or { n = 0, sum = 0 }
  s.session[kind] = e
  e.n = e.n + 1
  if value then e.sum, e.best = e.sum + value, math.min(e.best or value, value) end
  changed()
end

function Stats.Asked(asker, why)
  local key = LA.NameKey(asker)
  if not key or key == LA.MyKey() then return end
  if LA.Gate("stats asked", key, ASK_GAP) then Stats.Note("asked") end
  if why and LA.Gate("stats skipped", key, ASK_GAP) then Stats.Note(SKIPPED .. why) end
end

function Stats.Watch(on) watched = on end

local function total(kind)
  if sessionWindow() then
    local e = s.session[kind] or EMPTY
    return e.n or 0, e.sum or 0, e.best
  end
  local n, sum, best, from = 0, 0, nil, time() - HOUR
  local list = s.recent[kind] or EMPTY
  for i = #list, 1, -1 do
    local e = list[i]
    if e.at < from then break end
    n = n + 1
    if e.value then sum, best = sum + e.value, math.min(best or e.value, e.value) end
  end
  return n, sum, best
end

local function count(kind) return (total(kind)) end

local function distinct(set)
  local from, n = windowStart(), 0
  for _, at in pairs(set or EMPTY) do
    if at >= from then n = n + 1 end
  end
  return n
end

function Stats.Net(netId)
  local net = LA.Net(netId)
  local talking = distinct(s.talking[netId])
  local hosts = net.offers ~= false and distinct(s.hosts[netId]) or nil
  return math.max(LA.Call(net, "Seen") or 0, talking), talking, hosts
end

local function hosting(row, prefix, asked)
  row.asked, row.invited, row.moved = asked, count(prefix .. "invited"), count(prefix .. "moved")
  row.failed = count(prefix .. "stuck") + count(prefix .. "noshow")
end

function Stats.View()
  local v = view
  local swaps, swapTime, best = total("swap")
  v.swaps, v.avg, v.best = swaps, swaps > 0 and swapTime / swaps or nil, best
  v.taken, v.same, v.late = count("invite"), count("declined same shard"), count("declined late")
  v.thisHour, v.limit = LA.Limit.ThisHour()
  hosting(v.ground, "host.", count("asked"))
  hosting(v.flying, "fly.", nil)
  return v
end

local function pruneSets(from)
  for _, group in ipairs({ s.talking, s.hosts }) do
    for netId, set in pairs(group) do
      if prune(set, from) == 0 then group[netId] = nil end
    end
  end
end

local function startSession()
  local t = time()
  s.since = t
  wipe(s.session)
  trimAll(t - HOUR)
  pruneSets(keepFrom(t))
end

local function load()
  local c = LA.char
  c.stats = c.stats or {}
  s = c.stats
  s.since = s.since or time()
  s.recent, s.session = s.recent or {}, s.session or {}
  s.talking, s.hosts = s.talking or {}, s.hosts or {}
end

local function onEnteringWorld(_, isInitialLogin)
  if LA.Safe(isInitialLogin) then startSession() end
end

LA.On("PLAYER_LOGIN", load)
LA.On("PLAYER_ENTERING_WORLD", onEnteringWorld)

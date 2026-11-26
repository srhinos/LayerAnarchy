local _, LA = ...

local VL, VN = "VLAYER", "VOIDNET"
local NET = { id = "voidnet", name = "VoidNet", prefixes = { VL, VN } }

local ALPHA, MOD = "bcdfghjkmnpqrstvwxz23456789", 2147483629
local TAG, SALT, SLOTS, NAME_LEN, PW_LEN = "Vn", 52817, 3, 6, 8
local CODE_PRIME, SALT_PRIME, PW_PRIME, HASH_MUL = 7919, 97, 104729, 31
local HORDE, ALLIANCE, NEUTRAL, HOUR = 1, 2, 3, 3600
local JITTER_MIN, JITTER_MAX, JOIN_DEBOUNCE, REJOIN_AFTER, REJOIN_TRIES = 20, 40, 10, 10, 3
local ROSTER_FRESH, ROSTER_MAX, ROSTER_WAIT, ROSTER_SETTLE = 300, 300, 8, 2
local FANOUT, RELAY, KNOWN_FIRST, RELAY_QUEUE_MAX, RANDOM_TRIES = 10, 4, 3, 20, 3
local HR_WAIT, OK_WAIT, A_WINDOW, ANSWER_GAP, Q_GAP = 12, 30, 60, 60, 60
local CENSUS_HOST, CENSUS_KEEP, HEARD_KEEP, REACH, PING_GAP = 300, 600, 7200, 3600, 10
local IN_MAX, IN_WINDOW, QUEUE_MAX, BURST, REFILL = 20, 60, 60, 8, 1.1
local Q_TTL, RELAY_TTL, A_TTL, H_TTL = 15, 6, 6, 10
local NAME_MAX, PAIR_MAX, TEXT_MAX, VOTES_NEEDED = 48, 20, 255, 2
local NONCE_MIN, NONCE_MAX = 100000, 999999
local RESULT = Enum.SendAddonMessageResult
local REFUSALS = { WRONG_PASSWORD = true, BANNED = true, password = true }
local REASONS = { off = "off", zone = "layer" }
local UNLOCK_EVENTS = { "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_END", "ADDON_RESTRICTION_STATE_CHANGED" }

local db, book
local faction
local chan
local started, waiting, joinTries = false, false, 0
local roster = { names = {}, keyList = {}, keys = {}, at = 0 }
local reading
local heard, census, seenQ, inbound, votes = {}, {}, {}, {}, {}
local cur
local queue, tokens, filled, pumping, held = {}, BURST, 0, false, false
local join, refused, check, scheduleHour

local function newNonce() return tostring(math.random(NONCE_MIN, NONCE_MAX)) end

local function validName(n) return n and #n >= 1 and #n <= NAME_MAX and not n:find("[|:]") end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local function mix(h, n) return (h * HASH_MUL + n) % MOD end

local function code(seed, len)
  local h, out = seed, {}
  for i = 1, len do
    h = mix(mix(h, i), CODE_PRIME)
    local c = h % #ALPHA + 1
    out[i] = ALPHA:sub(c, c)
  end
  return table.concat(out)
end

local function derive(slot, hour, factionId)
  local salt = SALT + slot
  local s = mix(mix(mix(salt, hour), salt % SALT_PRIME), factionId)
  return TAG .. code(s, NAME_LEN), code(mix(s, PW_PRIME), PW_LEN)
end

local function hourNow() return math.floor(GetServerTime() / HOUR) end

local function side()
  if not faction then
    local f = LA.Safe(UnitFactionGroup("player"))
    faction = (f == "Horde" and HORDE) or (f == "Alliance" and ALLIANCE) or nil
  end
  return faction or NEUTRAL
end

local function pair() return LA.LayerToken(NET.id) .. "-0" end

local function canon(p) return p and p:match("^(%d+)%-%d+$") end

local function locked() return InCombatLockdown() or C_ChatInfo.InChatMessagingLockdown() end

local pump

local function tokensAt(t) return math.min(BURST, tokens + (t - filled) / REFILL) end

local function refill()
  pumping = false
  pump()
end

pump = function()
  if held then return end
  local t = GetTime()
  tokens, filled = tokensAt(t), t
  while tokens >= 1 and queue[1] do
    local m = table.remove(queue, 1)
    if not m.exp or m.exp > t then
      local result = LA.SendAddon(m.prefix, m.text, "WHISPER", m.to)
      if result == RESULT.AddonMessageThrottle or result == RESULT.AddOnMessageLockdown then
        table.insert(queue, 1, m)
        held = result == RESULT.AddOnMessageLockdown
        tokens = 0
        break
      end
      tokens = tokens - 1
    end
  end
  if queue[1] and not pumping and not held then
    pumping = true
    LA.After(REFILL, refill)
  end
end

local function send(prefix, text, to, urgent, life)
  if held and not locked() then held = false end
  if #queue >= QUEUE_MAX then
    if not urgent then return end
    table.remove(queue)
  end
  local m = { prefix = prefix, text = text, to = to, urgent = urgent, exp = life and (GetTime() + life) or nil }
  if urgent then
    local i = 1
    while queue[i] and queue[i].urgent do i = i + 1 end
    table.insert(queue, i, m)
  else
    queue[#queue + 1] = m
  end
  pump()
end

local function sendRoom(life) return math.floor(tokensAt(GetTime()) + life / REFILL) - #queue end

local function question(ttl, zone, nonce, asker) return ("Q:1:%d:%d:%s:%s"):format(ttl, zone, nonce, asker) end

local function reachable(key, t)
  if LA.Offline(key) then return false end
  local h = heard[key]
  return roster.keys[key] ~= nil or (h ~= nil and t - h.t < REACH)
end

local function pick(n, exclude)
  local t, me = GetTime(), LA.MyKey()
  local used, hosts, known, strangers = {}, {}, {}, {}
  local function usable(key)
    if key == me or used[key] or exclude[key] then return false end
    if not LA.Gate("voidnet ask", key, Q_GAP, true) or not reachable(key, t) then return false end
    used[key] = true
    return true
  end
  for key, e in pairs(book.entries) do
    if usable(key) then hosts[#hosts + 1] = roster.keys[key] or e.name end
  end
  for key, h in pairs(heard) do
    if usable(key) then known[#known + 1] = h.name end
  end
  for i, name in ipairs(roster.names) do
    if usable(roster.keyList[i]) then strangers[#strangers + 1] = name end
  end
  shuffle(hosts)
  shuffle(known)
  shuffle(strangers)
  for _, name in ipairs(known) do hosts[#hosts + 1] = name end
  local out = {}
  local room = n - math.min(KNOWN_FIRST, #strangers)
  for i = 1, math.min(room, #hosts) do out[#out + 1] = hosts[i] end
  for i = 1, #strangers do
    if #out >= n then break end
    out[#out + 1] = strangers[i]
  end
  for i = room + 1, #hosts do
    if #out >= n then break end
    out[#out + 1] = hosts[i]
  end
  return out
end

local function pickRandom(n, exclude)
  local out, used, me, list = {}, {}, LA.MyKey(), roster.names
  if #list == 0 then return out end
  for _ = 1, n * RANDOM_TRIES do
    if #out >= n then break end
    local i = math.random(1, #list)
    local key = roster.keyList[i]
    if key ~= me and not used[key] and not exclude[key] and not LA.Offline(key) then
      used[key] = true
      out[#out + 1] = list[i]
    end
  end
  return out
end

local function channelFrameOpen() return ChannelFrame ~= nil and ChannelFrame:IsShown() end

local function displayIndex(name)
  local wanted = name:lower()
  for i = 1, GetNumDisplayChannels() do
    local cname, header, _, _, count, active = GetChannelDisplayInfo(i)
    if not header and cname and cname:lower() == wanted then return i, count, active end
  end
end

local function selectedIndex()
  local ok, i = pcall(GetSelectedDisplayChannel)
  if ok and i then return i end
  local list = ChannelFrame and ChannelFrame:GetList()
  local id, supportsText = list and list:GetSelectedChannelIDAndSupportsText()
  if id and supportsText then return id end
end

local function readNow(idx, count)
  count = count or 0
  local names, keyList, keys = {}, {}, {}
  local first = count > ROSTER_MAX and math.random(1, count) or 1
  for j = 0, math.min(count, ROSTER_MAX) - 1 do
    local ok, name = pcall(C_ChatInfo.GetChannelRosterInfo, idx, (first + j - 1) % count + 1)
    name = ok and LA.Safe(name) or nil
    local key = LA.NameKey(name)
    if key and not keys[key] then
      keys[key] = name
      names[#names + 1] = name
      keyList[#keyList + 1] = key
    end
  end
  if #names == 0 then return false end
  roster.names, roster.keyList, roster.keys, roster.at = names, keyList, keys, GetTime()
  return true
end

local onRoster

local function finishRead(ok)
  local r = reading
  if not r then return end
  reading = nil
  LA.Off("CHANNEL_ROSTER_UPDATE", onRoster)
  if r.prev and r.prev ~= r.idx and not channelFrameOpen() then pcall(SetSelectedDisplayChannel, r.prev) end
  for _, callback in ipairs(r.callbacks) do LA.Try(NET.id, callback, ok) end
end

onRoster = function(_, idx, count)
  local r = reading
  idx, count = LA.Safe(idx), LA.Safe(count)
  if r and idx == r.idx and readNow(idx, count) then finishRead(true) end
end

local function readTimeout(r)
  if reading == r then finishRead(readNow(r.idx, select(5, GetChannelDisplayInfo(r.idx)))) end
end

local function fail(callback) if callback then callback(false) end end

local function readRoster(callback)
  if reading then
    reading.callbacks[#reading.callbacks + 1] = callback
    return
  end
  if not chan or channelFrameOpen() then return fail(callback) end
  local idx, _, active = displayIndex(chan.name)
  if not idx then
    if joinTries < REJOIN_TRIES and not LA.ChannelId(chan.name) then LA.After(REJOIN_AFTER, join) end
    return fail(callback)
  end
  if active == false then
    refused(chan.name, "disabled")
    return fail(callback)
  end
  local r = { idx = idx, prev = selectedIndex(), callbacks = { callback } }
  reading = r
  LA.On("CHANNEL_ROSTER_UPDATE", onRoster)
  pcall(SetSelectedDisplayChannel, idx)
  if r.prev == idx and readNow(idx, select(5, GetChannelDisplayInfo(idx))) then return finishRead(true) end
  LA.After(ROSTER_WAIT, readTimeout, r)
end

local function slotFor(hour)
  local s = db.slots[side()]
  return s and s.hour == hour and s.slot or 0
end

local function setSlot(hour, slot) db.slots[side()] = { hour = hour, slot = slot } end

local function onJoined(name, id, why)
  if not chan or chan.name ~= name then return end
  if not id and REFUSALS[why] then return refused(name, why) end
  LA.After(ROSTER_SETTLE, readRoster)
end

join = function()
  if not started then return end
  if locked() then
    waiting = true
    return
  end
  waiting = false
  local hour = hourNow()
  local slot = slotFor(hour)
  local name, pw = derive(slot, hour, side())
  if chan and chan.name == name and GetTime() - chan.at < JOIN_DEBOUNCE then return end
  chan = { name = name, hour = hour, slot = slot, at = GetTime() }
  LA.LeaveChannels(NET.id, { [name] = true })
  if not LA.ChannelId(name) then joinTries = joinTries + 1 end
  LA.JoinChannel(NET.id, name, pw, onJoined)
end

local function moveToSlot(hour, slot, why)
  LA.Log(NET.id, "slot", slot, why)
  setSlot(hour, slot)
  chan.at = 0
  join()
end

refused = function(name, why)
  if not chan or name ~= chan.name or chan.slot >= SLOTS then return end
  moveToSlot(chan.hour, chan.slot + 1, why)
end

local function sweep(t)
  wipe(seenQ)
  wipe(inbound)
  wipe(votes)
  for key, c in pairs(census) do
    if t - c.t > CENSUS_KEEP then census[key] = nil end
  end
  for key, h in pairs(heard) do
    if t - h.t > HEARD_KEEP then heard[key] = nil end
  end
end

local function onHour()
  if not (chan and hourNow() == chan.hour) then
    sweep(GetTime())
    joinTries = 0
    join()
  end
  scheduleHour()
end

scheduleHour = function()
  LA.After(HOUR - GetServerTime() % HOUR + math.random(JITTER_MIN, JITTER_MAX), onHour)
end

local function unlocked()
  if held then
    held = false
    pump()
  end
  if waiting then join() end
end

local function live(st) return st ~= nil and st == cur and st.ask.active end

local function enqueue(st, key)
  if st.tried[key] or st.queued[key] then return end
  st.queued[key] = true
  st.queue[#st.queue + 1] = key
end

local function freshHost(st, key, t)
  local c = census[key]
  return not st.tried[key] and c ~= nil and c.zone == st.zone and t - c.t <= CENSUS_HOST and not LA.Offline(key)
end

local function tryNext()
  local st = cur
  if not live(st) or st.try or IsInGroup() then return end
  local t = GetTime()
  while st.queue[1] do
    local key = table.remove(st.queue, 1)
    if freshHost(st, key, t) then
      local c = census[key]
      local try = { key = key, name = c.name, nonce = newNonce(), at = t }
      st.tried[key], st.try, st.nonces[try.nonce] = true, try, key
      st.ask.Asked(c.name)
      send(VL, ("HR:1:%d:%s:%s"):format(st.zone, c.pair, try.nonce), c.name, true, HR_WAIT)
      LA.After(HR_WAIT, check, st, try)
      return
    end
  end
end

check = function(st, try)
  if not live(st) or st.try ~= try then return end
  if IsInGroup() then
    try.grouped = true
    return
  end
  if try.ok and not try.grouped and GetTime() - try.at < OK_WAIT then
    LA.After(try.at + OK_WAIT - GetTime(), check, st, try)
    return
  end
  st.try = nil
  if not try.ok then census[try.key] = nil end
  tryNext()
end

local function onGroupLeft()
  local st = cur
  if not st then return end
  if st.try then check(st, st.try) else tryNext() end
end

local function wave(st)
  if not live(st) then return false end
  local me = LA.Me()
  if not validName(me) then return false end
  local room = math.min(FANOUT, sendRoom(Q_TTL))
  if room < 1 then return true end
  local targets = pick(room, st.asked)
  if #targets == 0 then return false end
  st.lastQ = GetTime()
  local text = question(1, st.zone, st.nonce, me)
  for _, name in ipairs(targets) do
    local key = LA.NameKey(name)
    if key then
      st.asked[key] = true
      LA.Gate("voidnet ask", key, 0)
      st.ask.Asked(name)
      send(VL, text, name, false, Q_TTL)
    end
  end
  LA.Log("vn-wave", #targets)
  return true
end

local function relay(zone, nonce, asker, exclude)
  local text = question(0, zone, nonce, asker)
  for _, name in ipairs(pickRandom(RELAY, exclude)) do send(VL, text, name, false, RELAY_TTL) end
end

local function onQ(text, _, key)
  local ttl, zone, nonce, asker = text:match("^Q:1:(%d+):(%d+):(%d+):(.+)$")
  ttl, zone = tonumber(ttl), tonumber(zone)
  if not ttl or ttl > 1 or not validName(asker) then return end
  local askerKey = LA.NameKey(asker)
  if not askerKey or askerKey == LA.MyKey() then return end
  if ttl == 1 and askerKey ~= key then return end
  if ttl == 0 and not (roster.keys[askerKey] or heard[askerKey]) then return end
  if seenQ[nonce] == askerKey then return end
  seenQ[nonce] = askerKey
  if ttl == 1 and #queue < RELAY_QUEUE_MAX then relay(zone, nonce, asker, { [key] = true, [askerKey] = true }) end
  if IsInInstance() or zone ~= LA.ZoneMapID() then return end
  if not LA.Gate("voidnet answer", askerKey, ANSWER_GAP) then return end
  send(VL, ("A:1:%d:%s:%d"):format(zone, pair(), LA.Host.Can(asker, zone) and 1 or 0), asker, true, A_TTL)
end

local function onA(text, sender, key)
  local zone, p, h = text:match("^A:1:(%d+):(%d+%-%d+):([01])$")
  zone = tonumber(zone)
  local st = cur
  if not zone or #p > PAIR_MAX or h ~= "1" or not live(st) or (st.only and not st.only[key]) then return end
  if zone ~= st.zone or not st.lastQ or GetTime() - st.lastQ > A_WINDOW then return end
  census[key] = { name = sender, zone = zone, pair = p, t = GetTime() }
  book:Remember(sender)
  enqueue(st, key)
  tryNext()
end

local function hostAsk(sender, zone, p)
  local ok, why = LA.Host.Can(sender, zone)
  if not ok then return REASONS[why] or "busy" end
  if canon(p) ~= canon(pair()) then return "layer" end
  if not LA.Host.Invite(sender, NET.id) then return "busy" end
end

local function onHR(text, sender)
  local zone, p, nonce = text:match("^HR:1:(%d+):(%d+%-%d+):(%d+)$")
  zone = tonumber(zone)
  if not zone or #p > PAIR_MAX then return end
  local no = hostAsk(sender, zone, p)
  if no then return send(VL, ("HA:1:%s:no:%s"):format(nonce, no), sender, true, H_TTL) end
  send(VL, ("HA:1:%s:ok"):format(nonce), sender, true, H_TTL)
  send(VL, ("HP:1:%s:%s"):format(nonce, pair()), sender, true, H_TTL)
end

local function onHA(text, sender, key)
  local nonce, rest = text:match("^HA:1:(%d+):(.+)$")
  local st = cur
  if not nonce or not st or st.nonces[nonce] ~= key then return end
  local try = st.try and st.try.nonce == nonce and st.try or nil
  if rest == "ok" then
    st.ask.Offer(sender, NET.id)
    book:Remember(sender)
    if try then try.ok = true end
  elseif rest:sub(1, 2) == "no" then
    st.ask.Refuse(sender)
    census[key] = nil
    if try then
      st.try = nil
      tryNext()
    end
  end
end

local HANDLERS = { Q = onQ, A = onA, HR = onHR, HA = onHA }

local function onSlotVote(text, key)
  local slot, hour = text:match("^M:(%d+):(%d+)$")
  slot, hour = tonumber(slot), tonumber(hour)
  if not slot or not chan or hour ~= chan.hour or slot <= chan.slot or slot > SLOTS then return end
  if not roster.keys[key] then return end
  local v = votes[slot]
  if not v or v.hour ~= hour then
    v = { hour = hour, n = 0, by = {} }
    votes[slot] = v
  end
  if v.by[key] then return end
  v.by[key], v.n = true, v.n + 1
  if v.n >= VOTES_NEEDED then moveToSlot(hour, slot, "votes") end
end

local function onGuard(text, sender, key)
  if not text:find("^O:%d+$") then return onSlotVote(text, key) end
  if LA.Gate("voidnet ping", key, PING_GAP) then send(VN, "o", sender, true) end
end

local function overLimit(key, t)
  local r = inbound[key] or {}
  inbound[key] = r
  if not r.t or t - r.t > IN_WINDOW then r.t, r.n = t, 0 end
  r.n = r.n + 1
  return r.n > IN_MAX
end

local function noteHeard(key, sender, t)
  local h = heard[key] or {}
  heard[key] = h
  h.name, h.t = sender, t
end

function NET.Init(net)
  db = net.db
  db.slots = db.slots or {}
  book = LA.Book(net.id)
  for _, event in ipairs(UNLOCK_EVENTS) do LA.On(event, unlocked) end
  LA.On("GROUP_LEFT", onGroupLeft)
end

function NET.OnChannels()
  started = true
  join()
  scheduleHour()
end

function NET.Seen()
  local n = #roster.names
  if roster.keys[LA.MyKey()] then n = n - 1 end
  return n
end

function NET.OnAddon(_, prefix, text, chatType, sender, key)
  if chatType ~= "WHISPER" or not text or #text > TEXT_MAX then return end
  local t = GetTime()
  noteHeard(key, sender, t)
  if prefix == VN then return onGuard(text, sender, key) end
  if overLimit(key, t) then return end
  local handler = HANDLERS[text:match("^(%u%u?):1:")]
  if handler then handler(text, sender, key) end
end

local function newState(ask)
  local st = {
    ask = ask, zone = ask.zone, nonce = newNonce(),
    queue = {}, queued = {}, tried = {}, nonces = {}, asked = {},
  }
  cur = st
  return st
end

function NET.Ask(_, ask)
  local zone = ask.zone
  if not zone then return end
  local st = newState(ask)
  local t = GetTime()
  for key, c in pairs(census) do
    if c.zone == zone and t - c.t <= CENSUS_HOST then enqueue(st, key) end
  end
  tryNext()
  wave(st)
  if t - roster.at > ROSTER_FRESH then readRoster(function(ok) if ok then wave(st) end end) end
end

function NET.Target(_, ask, names)
  local me = LA.Me()
  if not (ask.zone and validName(me)) then return 0 end
  local st, t = newState(ask), GetTime()
  st.only, st.lastQ = {}, t
  local text = question(1, st.zone, st.nonce, me)
  for _, name in ipairs(names) do
    local key = LA.NameKey(name)
    if key and not LA.Offline(key) then
      st.only[key], st.asked[key] = true, true
      st.ask.Asked(name)
      send(VL, text, name, true, Q_TTL)
      if freshHost(st, key, t) then enqueue(st, key) end
    end
  end
  tryNext()
  local n = 0
  for _ in pairs(st.only) do n = n + 1 end
  return n
end

function NET.Round(_, ask)
  local st = cur
  if not (st and st.ask == ask) then return false end
  return wave(st) or reading ~= nil
end

function NET.StopAsk(_, ask) if cur and cur.ask == ask then cur = nil end end

function NET.OnSwapResult(_, _, result, host)
  local key = LA.NameKey(host)
  if key and (result == "moved" or result == "same") then census[key] = nil end
end

function NET.OnHostFailed(_, ask, why, host)
  local key = LA.NameKey(host)
  if key and why == "same" then census[key] = nil end
  local st = cur
  if st and st.ask == ask and st.try and st.try.key == key then
    st.try = nil
    tryNext()
  end
end

LA.RegisterNetwork(NET)

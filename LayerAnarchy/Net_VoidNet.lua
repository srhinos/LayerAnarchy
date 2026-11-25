local _, LA = ...

local VL, VN = "VLAYER", "VOIDNET"
local NET = { id = "voidnet", name = "VoidNet", prefixes = { VL, VN } }

local ALPHA, MOD = "bcdfghjkmnpqrstvwxz23456789", 2147483629
local TAG, SALT, SLOTS, NAME_LEN, PW_LEN = "Vn", 52817, 3, 6, 8
local CODE_PRIME, SALT_PRIME, PW_PRIME, HASH_MUL = 7919, 97, 104729, 31
local HORDE, ALLIANCE, NEUTRAL, HOUR = 1, 2, 3, 3600
local JITTER_MIN, JITTER_MAX, JOIN_DEBOUNCE, REJOIN_AFTER, REJOIN_TRIES = 20, 40, 10, 10, 3
local ROSTER_FRESH, ROSTER_MAX, ROSTER_WAIT, ROSTER_SETTLE = 300, 300, 8, 2
local FANOUT, RELAY, WAVES, WAVE_GAP, KNOWN_FIRST, RELAY_QUEUE_MAX = 10, 4, 3, 8, 3, 20
local HR_WAIT, OK_WAIT, A_WINDOW, ANSWER_GAP, Q_GAP = 12, 30, 60, 60, 60
local CENSUS_HOST, CENSUS_KEEP, HEARD_KEEP, REACH, PING_GAP = 300, 600, 7200, 3600, 10
local IN_MAX, IN_WINDOW, QUEUE_MAX, BURST, REFILL = 20, 60, 60, 8, 1.1
local Q_TTL, RELAY_TTL, A_TTL, H_TTL = 15, 6, 6, 10
local NAME_MAX, PAIR_MAX, TEXT_MAX, VOTES_NEEDED = 48, 20, 255, 2
local NONCE_MIN, NONCE_MAX = 100000, 999999
local RESULT = Enum.SendAddonMessageResult
local REFUSALS = { WRONG_PASSWORD = true, BANNED = true, password = true }
local HR_REPLY = { off = "off", zone = "layer" }
local UNLOCK_EVENTS = { "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_END", "ADDON_RESTRICTION_STATE_CHANGED" }

local db, book
local faction
local chan
local started, waiting, joinTries = false, false, 0
local roster = { names = {}, ks = {}, keys = {}, at = 0 }
local reading
local heard, census, seenQ, inbound, votes = {}, {}, {}, {}, {}
local asking
local queue, tokens, filled, pumping, held = {}, BURST, 0, false, false
local join, refused, check, scheduleHour

local function now() return GetTime() end

local function newNonce() return tostring(math.random(NONCE_MIN, NONCE_MAX)) end

local function validName(n)
  return type(n) == "string" and #n >= 1 and #n <= NAME_MAX and not n:find("[|:]")
end

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

local function locked() return InCombatLockdown() or LA.ChatLocked() end

local pump

local function refill()
  pumping = false
  pump()
end

pump = function()
  if held then return end
  local t = now()
  tokens = math.min(BURST, tokens + (t - filled) / REFILL)
  filled = t
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
  if not to then return end
  if held and not locked() then held = false end
  if #queue >= QUEUE_MAX then
    if not urgent then return end
    table.remove(queue)
  end
  local m = { prefix = prefix, text = text, to = to, urgent = urgent, exp = life and (now() + life) or nil }
  if urgent then
    local i = 1
    while queue[i] and queue[i].urgent do i = i + 1 end
    table.insert(queue, i, m)
  else
    queue[#queue + 1] = m
  end
  pump()
end

local function reachable(k, t)
  if LA.Offline(k) then return false end
  local h = heard[k]
  return roster.keys[k] ~= nil or (h ~= nil and t - h.t < REACH)
end

local function pick(n, exclude)
  local t, me = now(), LA.MyKey()
  local used, hosts, known, strangers = {}, {}, {}, {}
  local function usable(k)
    if not k or k == me or used[k] or exclude[k] then return false end
    if not LA.Gate("voidnet ask", k, Q_GAP, true) or not reachable(k, t) then return false end
    used[k] = true
    return true
  end
  for k, e in pairs(book.entries) do
    if usable(k) then hosts[#hosts + 1] = roster.keys[k] or e.name end
  end
  for k, h in pairs(heard) do
    if usable(k) then known[#known + 1] = h.name end
  end
  for i, name in ipairs(roster.names) do
    if usable(roster.ks[i]) then strangers[#strangers + 1] = name end
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
  for _ = 1, n * 3 do
    if #out >= n then break end
    local i = math.random(1, #list)
    local k = roster.ks[i]
    if k and k ~= me and not used[k] and not exclude[k] then
      used[k] = true
      out[#out + 1] = list[i]
    end
  end
  return out
end

local function channelFrameOpen() return ChannelFrame ~= nil and ChannelFrame:IsShown() end

local function displayIndex(name)
  for i = 1, GetNumDisplayChannels() do
    local cname, header, _, _, count, active = GetChannelDisplayInfo(i)
    if not header and cname == name then return i, count, active end
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
  count = tonumber(count) or 0
  local names, ks, keys, owner = {}, {}, {}, nil
  local first = count > ROSTER_MAX and math.random(1, count) or 1
  for j = 0, math.min(count, ROSTER_MAX) - 1 do
    local ok, name, isOwner = pcall(C_ChatInfo.GetChannelRosterInfo, idx, (first + j - 1) % count + 1)
    name = ok and LA.Safe(name) or nil
    local k = LA.NameKey(name)
    if k and not keys[k] then
      keys[k] = name
      names[#names + 1] = name
      ks[#ks + 1] = k
      if LA.Safe(isOwner) then owner = name end
    end
  end
  if #names == 0 then return false end
  roster.names, roster.ks, roster.keys, roster.owner, roster.at = names, ks, keys, owner, now()
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
  if chan and chan.name == name and now() - chan.at < JOIN_DEBOUNCE then return end
  chan = { name = name, hour = hour, slot = slot, at = now() }
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
  for k, c in pairs(census) do
    if t - c.t > CENSUS_KEEP then census[k] = nil end
  end
  for k, h in pairs(heard) do
    if t - h.t > HEARD_KEEP then heard[k] = nil end
  end
end

local function onHour()
  if not (chan and hourNow() == chan.hour) then
    sweep(now())
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

local function enqueue(a, k)
  if a.tried[k] or a.queued[k] then return end
  a.queued[k] = true
  a.queue[#a.queue + 1] = k
end

local function freshHost(a, k, t)
  local c = census[k]
  return not a.tried[k] and c ~= nil and c.zone == a.zone and t - c.t <= CENSUS_HOST
end

local function tryNext()
  local a = asking
  if not a or not a.ask.active or a.cur or IsInGroup() then return end
  local t = now()
  while a.queue[1] do
    local k = table.remove(a.queue, 1)
    if freshHost(a, k, t) then
      local c = census[k]
      local try = { k = k, name = c.name, nonce = newNonce(), at = t }
      a.tried[k], a.cur, a.nonces[try.nonce] = true, try, k
      a.ask.Asked(c.name)
      send(VL, ("HR:1:%d:%s:%s"):format(a.zone, c.pair, try.nonce), c.name, true, HR_WAIT)
      LA.After(HR_WAIT, check, a, try)
      return
    end
  end
end

check = function(a, try)
  if asking ~= a or a.cur ~= try or not a.ask.active then return end
  if IsInGroup() then
    try.grouped = true
    return
  end
  if try.ok and not try.grouped and now() - try.at < OK_WAIT then
    LA.After(try.at + OK_WAIT - now(), check, a, try)
    return
  end
  a.cur = nil
  if not try.ok then census[try.k] = nil end
  tryNext()
end

local function onGroupLeft()
  local a = asking
  if not a then return end
  if a.cur then check(a, a.cur) else tryNext() end
end

local function wave(a, first)
  if asking ~= a or not a.ask.active or a.waves >= WAVES then return end
  if not first and a.ask.found > 0 then return end
  local me = LA.Me()
  if not validName(me) then return end
  local targets = pick(FANOUT, a.asked)
  if #targets == 0 then return end
  a.waves, a.lastQ = a.waves + 1, now()
  local text = ("Q:1:1:%d:%s:%s"):format(a.zone, a.nonce, me)
  for _, name in ipairs(targets) do
    local k = LA.NameKey(name)
    if k then
      a.asked[k] = true
      LA.Gate("voidnet ask", k, 0)
      a.ask.Asked(name)
      send(VL, text, name, false, Q_TTL)
    end
  end
end

function NET.Ask(_, ask)
  local zone = tonumber(ask.zone)
  if not zone then return end
  local a = {
    ask = ask, zone = zone, nonce = newNonce(), waves = 0, hosts = 0,
    queue = {}, queued = {}, tried = {}, nonces = {}, asked = {},
  }
  asking = a
  local t = now()
  for k, c in pairs(census) do
    if c.zone == zone and t - c.t <= CENSUS_HOST then enqueue(a, k) end
  end
  tryNext()
  wave(a, true)
  if t - roster.at > ROSTER_FRESH then readRoster(function() wave(a) end) end
  LA.After(WAVE_GAP, wave, a)
end

function NET.StopAsk(_, ask) if asking and asking.ask == ask then asking = nil end end

function NET.OnSwapResult(_, _, result, host)
  local k = LA.NameKey(host)
  if k and (result == "moved" or result == "same") then census[k] = nil end
end

function NET.OnHostFailed(_, ask, why, host)
  local k = LA.NameKey(host)
  if k and why == "same" then census[k] = nil end
  local a = asking
  if a and a.ask == ask and a.cur and a.cur.k == k then
    a.cur = nil
    tryNext()
  end
end

local function relay(zone, nonce, asker, exclude)
  local text = ("Q:1:0:%d:%s:%s"):format(zone, nonce, asker)
  for _, name in ipairs(pickRandom(RELAY, exclude)) do send(VL, text, name, false, RELAY_TTL) end
end

local function onQ(text, sender, k)
  local ttl, zone, nonce, asker = text:match("^Q:1:(%d+):(%d+):(%d+):(.+)$")
  ttl, zone = tonumber(ttl), tonumber(zone)
  if not ttl or ttl > 1 or not validName(asker) then return end
  local ak = LA.NameKey(asker)
  if not ak or ak == LA.MyKey() then return end
  if ttl == 1 and ak ~= k then return end
  if ttl == 0 and not (roster.keys[ak] or heard[ak]) then return end
  if seenQ[nonce] == ak then return end
  seenQ[nonce] = ak
  if ttl == 1 and #queue < RELAY_QUEUE_MAX then relay(zone, nonce, asker, { [k] = true, [ak] = true }) end
  if LA.InInstance() or zone ~= LA.ZoneMapID() then return end
  if not LA.Gate("voidnet answer", ak, ANSWER_GAP) then return end
  send(VL, ("A:1:%d:%s:%d"):format(zone, pair(), LA.Host.Can(asker, zone) and 1 or 0), asker, true, A_TTL)
end

local function onA(text, sender, k)
  local zone, p, h = text:match("^A:1:(%d+):(%d+%-%d+):([01])$")
  zone = tonumber(zone)
  local a = asking
  if not zone or #p > PAIR_MAX or h ~= "1" or not a or not a.ask.active then return end
  if zone ~= a.zone or not a.lastQ or now() - a.lastQ > A_WINDOW then return end
  census[k] = { name = sender, zone = zone, pair = p, t = now() }
  a.hosts = a.hosts + 1
  book:Remember(sender)
  enqueue(a, k)
  tryNext()
end

local function hostReply(sender, zone, p)
  local ok, why = LA.Host.Can(sender, zone)
  if not ok then return HR_REPLY[why] or "busy" end
  if canon(p) ~= canon(pair()) then return "layer" end
  if not LA.Host.Invite(sender, NET.id) then return "busy" end
end

local function onHR(text, sender)
  local zone, p, nonce = text:match("^HR:1:(%d+):(%d+%-%d+):(%d+)$")
  zone = tonumber(zone)
  if not zone or #p > PAIR_MAX then return end
  local no = hostReply(sender, zone, p)
  if no then return send(VL, ("HA:1:%s:no:%s"):format(nonce, no), sender, true, H_TTL) end
  send(VL, ("HA:1:%s:ok"):format(nonce), sender, true, H_TTL)
  send(VL, ("HP:1:%s:%s"):format(nonce, pair()), sender, true, H_TTL)
end

local function onHA(text, sender, k)
  local nonce, rest = text:match("^HA:1:(%d+):(.+)$")
  local a = asking
  if not nonce or not a or a.nonces[nonce] ~= k then return end
  local try = a.cur and a.cur.nonce == nonce and a.cur or nil
  if rest == "ok" then
    a.ask.Offer(sender, NET.id)
    book:Remember(sender)
    if try then try.ok = true end
  elseif rest:sub(1, 2) == "no" then
    a.ask.Refuse(sender)
    census[k] = nil
    if try then
      a.cur = nil
      tryNext()
    end
  end
end

local HANDLERS = { Q = onQ, A = onA, HR = onHR, HA = onHA }

local function onSlotVote(text, k)
  local slot, hour = text:match("^M:(%d+):(%d+)$")
  slot, hour = tonumber(slot), tonumber(hour)
  if not slot or not chan or hour ~= chan.hour or slot <= chan.slot or slot > SLOTS then return end
  if not roster.keys[k] then return end
  local v = votes[slot]
  if not v or v.hour ~= hour then
    v = { hour = hour, n = 0, by = {} }
    votes[slot] = v
  end
  if v.by[k] then return end
  v.by[k], v.n = true, v.n + 1
  if v.n >= VOTES_NEEDED then moveToSlot(hour, slot, "votes") end
end

local function onGuard(text, sender, k)
  if not text:find("^O:%d+$") then return onSlotVote(text, k) end
  if LA.Gate("voidnet ping", k, PING_GAP) then send(VN, "o", sender, true) end
end

local function overLimit(k, t)
  local r = inbound[k] or {}
  inbound[k] = r
  if not r.t or t - r.t > IN_WINDOW then r.t, r.n = t, 0 end
  r.n = r.n + 1
  return r.n > IN_MAX
end

local function noteHeard(k, sender, t)
  local h = heard[k] or {}
  heard[k] = h
  h.name, h.t = sender, t
end

function NET.OnAddon(_, prefix, text, chatType, sender, k)
  if chatType ~= "WHISPER" or type(text) ~= "string" or #text > TEXT_MAX then return end
  local t = now()
  noteHeard(k, sender, t)
  if prefix == VN then return onGuard(text, sender, k) end
  if overLimit(k, t) then return end
  local handler = HANDLERS[text:match("^(%u%u?):1:")]
  if handler then handler(text, sender, k) end
end

function NET.Init(net)
  db = net.db
  db.slots = db.slots or {}
  book = LA.Book(net.id)
  for _, event in ipairs(UNLOCK_EVENTS) do LA.On(event, unlocked) end
  LA.On("GROUP_LEFT", onGroupLeft)
end

function NET.Seen()
  local n = #roster.names
  if roster.keys[LA.MyKey()] then n = n - 1 end
  return n
end

function NET.OnChannels()
  started = true
  join()
  scheduleHour()
end

LA.RegisterNetwork(NET)

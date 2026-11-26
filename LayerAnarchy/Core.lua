local ADDON, LA = ...
LA.VERSION = C_AddOns.GetAddOnMetadata(ADDON, "Version")

local TITLE = "|cffe8cc6aLayer Anarchy|r"
local DEFAULTS = {
  help = true, hostWhileFlying = true, auto = true, sound = false, askAutoLayer = true, invitesPerHour = 0,
  locked = false, scale = 1, minimized = false, hidden = false, statsWindow = "hour",
}
local UNDEFAULTED = { point = true }
local OTHERS = {
  "LayerSwap", "BuloLayerForever", "ForeverLayers", "AutoLayer", "LayerHopForAutoLayer",
  "ForeverLayerHop", "VoidLayer", "VoidSweep", "VoidQuest", "VoidGather", "VoidBounty", "VoidDungeon",
  "ChangeLayer", "LayerHop", "MerrinxUI_LayerHop", "Meshly", "MyLayerTracker",
}
local API_CHECKS = {
  "JoinTemporaryChannel", "JoinChannelByName", "JoinPermanentChannel", "GetSelectedDisplayChannel",
  "C_FriendList.SendWho", "C_FriendList.SetWhoToUi", "UnitPhaseReason", "GetEvictionTimeRemaining",
  "C_PlayerInteractionManager.ShardTransferConfirm", "ChatFrameUtil.OpenChat", "ERR_UNINVITE_YOU",
  "C_ChatInfo.AreOutgoingAddonChatMessagesRestricted",
}

local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local TOKEN_MIN, TOKEN_MAX = 100000, 999999
local HOUR, DAY = 3600, 86400
local LOG_MAX, LOG_SHOWN, FLASH_FOR, WAKE_SLACK = 400, 30, 10, 0.02
local MIN_WINDOW, MOVES_MAX, LOCKOUTS_MAX, SECONDS_SHOWN = 300, 200, 50, 60
local COUNTDOWN_MINUTES = { 5, 10, 15, 30, 45 }
local BORDER_BEFORE, BORDER_AFTER, TRANSFER_SETTLE = 10, 2, 2
local NOT_FOUND_FOR, OFFLINE_FOR, GATE_MAX, GATE_AGE = 30, 1800, 256, 120
local BOOK_DAYS, BOOK_MAX, PARTY_SIZE, RAID_SIZE, MAP_CLIMB = 7, 300, 4, 40, 10
local CHANNEL_DELAY, JOIN_TIMEOUT, LOW_SLOTS, RELOCATE_AFTER = 10, 10, 5, 30
local QUIET_FOR, GROUP_QUIET_FOR = 150, 60
local MAX_WINDOWS = Constants.ChatFrameConstants.MaxChatWindows
local ZONE = Enum.UIMapType.Zone
local RESULT = Enum.SendAddonMessageResult
local ROUTINE_RESULTS = {
  [RESULT.Success] = true, [RESULT.AddonMessageThrottle] = true,
  [RESULT.AddOnMessageLockdown] = true, [RESULT.TargetOffline] = true,
}
local TARGET_ATTRIBUTE = { WHISPER = "tellTarget", CHANNEL = "channelTarget" }
local PREFILL_ATTRIBUTES = { "chatType", "stickyType", "channelTarget", "tellTarget" }
local NAMED_LINES = {
  "ERR_INVITE_PLAYER_S", "ERR_JOINED_GROUP_S", "ERR_LEFT_GROUP_S", "ERR_DECLINE_GROUP_S", "ERR_ALREADY_IN_GROUP_S",
  "ERR_BAD_PLAYER_NAME_S", "ERR_INVITED_TO_GROUP_SS", "ERR_INVITED_ALREADY_IN_GROUP_SS",
}
local GROUP_LINES = { "ERR_GROUP_DISBANDED", "ERR_LEFT_GROUP_YOU", "ERR_NOT_IN_GROUP" }
local LOOT_LINES = "^ERR_SET_LOOT_"
local JOINED = { YOU_CHANGED = true, YOU_JOINED = true }
local REFUSED = { WRONG_PASSWORD = true, BANNED = true }
local MAP_EVENTS = { "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }
local EMPTY = {}

local secret = issecretvalue or function() return false end

function LA.Safe(v)
  if secret(v) then return nil end
  return v
end

local lastLine, repeats = nil, 0
local counts = {}

local function logIndex(db) return db.logAt or (#db.log % LOG_MAX + 1) end

local function logText(kind, ...)
  local parts = { tostring(kind) }
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[i + 1] = secret(v) and "<secret>" or tostring(v)
  end
  return table.concat(parts, " ")
end

function LA.Log(kind, ...)
  local db = LA.db
  if not db then return end
  local line, at = logText(kind, ...), logIndex(db)
  if line == lastLine then
    repeats = repeats + 1
    db.log[(at - 2) % LOG_MAX + 1] = date("%H:%M:%S ") .. line .. " x" .. repeats
    return
  end
  lastLine, repeats = line, 1
  db.log[at] = date("%H:%M:%S ") .. line
  db.logAt = at % LOG_MAX + 1
end

function LA.Count(key) counts[key] = (counts[key] or 0) + 1 end

function LA.Tally(key)
  local tallies = LA.db.tallies
  tallies[key] = (tallies[key] or 0) + 1
end

function LA.Print(text) print(TITLE .. ": " .. text) end

function LA.Try(where, fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then return result end
  LA.Log("error", where, result)
end

local bus, handlers = CreateFrame("Frame"), {}

bus:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do LA.Try(event, list[i], event, ...) end
end)

function LA.On(event, fn)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    pcall(bus.RegisterEvent, bus, event)
  end
  list[#list + 1] = fn
end

function LA.Off(event, fn)
  local kept = {}
  for _, f in ipairs(handlers[event] or EMPTY) do
    if f ~= fn then kept[#kept + 1] = f end
  end
  handlers[event] = kept[1] and kept or nil
  if not kept[1] then bus:UnregisterEvent(event) end
end

function LA.After(sec, fn, a, b)
  return C_Timer.NewTimer(sec, function() LA.Try("timer", fn, a, b) end)
end

function LA.Setting(key)
  local v = LA.db and LA.db.settings[key]
  if v == nil then return DEFAULTS[key] end
  return v
end

function LA.SetSetting(key, value)
  if value == DEFAULTS[key] then value = nil end
  LA.db.settings[key] = value
  LA.Refresh()
end

function LA.ToggleHelp()
  if LA.disabled or LA.Debug.Previewing() then return end
  LA.SetSetting("help", not LA.Setting("help"))
end

function LA.Bare(name) return name:match("^(.-)%-[^%-%s]+$") or name end

function LA.NameKey(name)
  name = LA.Safe(name)
  if type(name) ~= "string" or name == "" then return nil end
  return LA.Bare(name):lower()
end

local myName, myKey

function LA.Me()
  if not myName then
    myName = LA.Safe(GetUnitName("player", false))
    myKey = LA.NameKey(myName)
  end
  return myName
end

function LA.MyKey()
  LA.Me()
  return myKey
end

function LA.IsMe(name)
  local key = LA.NameKey(name)
  return key ~= nil and key == LA.MyKey()
end

local zoneOfMap = {}
local rawMap, zoneMap

local function climbToZone(map)
  local id = map
  for _ = 1, MAP_CLIMB do
    local info = id and C_Map.GetMapInfo(id)
    if not info or (info.mapType and info.mapType < ZONE) then return map end
    if info.mapType == ZONE then return id end
    id = info.parentMapID
  end
  return map
end

function LA.ZoneOf(map)
  map = tonumber(map)
  if not map or map <= 0 then return nil end
  zoneOfMap[map] = zoneOfMap[map] or climbToZone(map)
  return zoneOfMap[map]
end

local function readMaps()
  rawMap = LA.Safe(C_Map.GetBestMapForUnit("player"))
  zoneMap = LA.ZoneOf(rawMap)
end

function LA.RawMapID()
  if not rawMap then readMaps() end
  return rawMap
end

function LA.ZoneMapID()
  if not rawMap then readMaps() end
  return zoneMap
end


function LA.InInstance() return IsInInstance() and true or false end

local function mapsChanged() rawMap = nil end

for _, event in ipairs(MAP_EVENTS) do LA.On(event, mapsChanged) end

local whisperedAt, offlineAt, lastWhisperAt = {}, {}, -math.huge
local notFoundPattern

local function forgetOldWhispers(now)
  wipe(whisperedAt)
  for key, at in pairs(offlineAt) do
    if now - at > OFFLINE_FOR then offlineAt[key] = nil end
  end
end

local function stampWhisper(target, result)
  local key = LA.NameKey(target)
  if not key then return end
  local now = GetTime()
  if now - lastWhisperAt > NOT_FOUND_FOR then forgetOldWhispers(now) end
  whisperedAt[key], lastWhisperAt = now, now
  if result == RESULT.TargetOffline then offlineAt[key] = now end
end

function LA.SendAddon(prefix, text, chatType, target)
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, text, chatType, target)
  if not ok then
    LA.Log("error", "send", prefix, chatType, result)
    return nil
  end
  if chatType == "WHISPER" then stampWhisper(target, result) end
  if type(result) == "number" and not ROUTINE_RESULTS[result] then LA.Log("send-result", prefix, chatType, result) end
  return result
end

function LA.Offline(key)
  local at = key and offlineAt[key]
  return at ~= nil and GetTime() - at < OFFLINE_FOR
end

local function linePattern(s)
  if type(s) ~= "string" or s == "" then return nil end
  local escaped = s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  local named = escaped:gsub("%%%%s", "(.-)", 1)
  return "^" .. named:gsub("%%%%s", ".-") .. "$"
end

local groupLines = {}

local function addGroupLine(kind, named)
  local pattern = linePattern(_G[kind])
  if pattern then groupLines[#groupLines + 1] = { kind = kind, pattern = pattern, named = named } end
end

local function buildGroupLines()
  for _, kind in ipairs(NAMED_LINES) do addGroupLine(kind, true) end
  for _, kind in ipairs(GROUP_LINES) do addGroupLine(kind, false) end
  for kind in pairs(_G) do
    if type(kind) == "string" and kind:find(LOOT_LINES) then addGroupLine(kind, false) end
  end
end

function LA.GroupLine(text)
  if type(text) ~= "string" then return nil end
  for _, line in ipairs(groupLines) do
    local name = text:match(line.pattern)
    if name then return line.kind, line.named and LA.NameKey(name) or nil end
  end
end

local quietAt, quietSweptAt, groupQuietAt = {}, 0, -math.huge

function LA.Quiet(name, on)
  local now, key = GetTime(), LA.NameKey(name)
  if now - quietSweptAt > QUIET_FOR then
    quietSweptAt = now
    for k, at in pairs(quietAt) do
      if now - at > QUIET_FOR then quietAt[k] = nil end
    end
  end
  if on == false then
    if key then quietAt[key] = nil end
    return
  end
  if key then quietAt[key] = now end
  groupQuietAt = now
end

local function hideGroupLine(_, _, msg)
  local kind, key = LA.GroupLine(LA.Safe(msg))
  if not kind then return false end
  local now = GetTime()
  if key then return quietAt[key] ~= nil and now - quietAt[key] < QUIET_FOR end
  return now - groupQuietAt < GROUP_QUIET_FOR
end

local function hideNotFound(_, _, msg)
  local now = GetTime()
  if now - lastWhisperAt > NOT_FOUND_FOR then return false end
  msg = LA.Safe(msg)
  local key = type(msg) == "string" and LA.NameKey(msg:match(notFoundPattern))
  local at = key and whisperedAt[key]
  if not at or now - at > NOT_FOUND_FOR then return false end
  offlineAt[key] = now
  return true
end

function LA.ChatRestricted()
  local ok, restricted = pcall(C_ChatInfo.AreOutgoingAddonChatMessagesRestricted)
  return ok and restricted == true
end

function LA.ChatLocked()
  local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
  return ok and locked == true
end

local prefill = {}

local function endPrefill()
  local box = prefill.box
  if not box then return end
  prefill.box = nil
  for _, name in ipairs(PREFILL_ATTRIBUTES) do box:SetAttribute(name, prefill.saved[name]) end
  pcall(box.UpdateHeader, box)
  local onEnd = prefill.onEnd
  prefill.onEnd = nil
  if onEnd then LA.Try("prefill", onEnd, prefill.sent) end
  LA.Refresh()
end

local function settlePrefill()
  local box = prefill.box
  if box and not (box:IsShown() and ChatFrameUtil.GetActiveWindow() == box) then endPrefill() end
end

local function onPreSend(_, box) if box == prefill.box then prefill.sent = true end end

local function onBoxClosed(_, box) if box == prefill.box then LA.After(0, settlePrefill) end end

local PREFILL_EVENTS = {
  ["ChatFrame.OnEditBoxPreSendText"] = onPreSend,
  ["ChatFrame.OnEditBoxHide"] = onBoxClosed,
  ["ChatFrame.OnEditBoxFocusLost"] = onBoxClosed,
}

local function watchPrefill()
  if prefill.watching then return end
  prefill.watching = true
  for event, fn in pairs(PREFILL_EVENTS) do EventRegistry:RegisterCallback(event, fn, prefill) end
end

function LA.PrefillChat(text, chatType, target, onEnd)
  local typing = ChatFrameUtil.GetActiveWindow()
  if typing and (typing:GetText() or "") ~= "" then return nil end
  watchPrefill()
  endPrefill()
  local box = ChatFrameUtil.ChooseBoxForSend(DEFAULT_CHAT_FRAME)
  local saved = {}
  for _, name in ipairs(PREFILL_ATTRIBUTES) do saved[name] = box:GetAttribute(name) end
  ChatFrameUtil.OpenChat(text, DEFAULT_CHAT_FRAME)
  box = ChatFrameUtil.GetActiveWindow() or box
  box:SetAttribute("chatType", chatType)
  local attribute = TARGET_ATTRIBUTE[chatType]
  if attribute then box:SetAttribute(attribute, target) end
  pcall(box.UpdateHeader, box)
  prefill.box, prefill.text, prefill.saved, prefill.onEnd, prefill.sent = box, text, saved, onEnd, false
  LA.Refresh()
  return "prefilled"
end

function LA.ClearPrefill()
  local box = prefill.box
  if not box then return end
  if box:GetText() == prefill.text then
    box:SetText("")
    ChatFrameUtil.DeactivateChat(box)
  end
  endPrefill()
end

local joins, relocated = {}, {}
local startJoin

function LA.ChannelId(name)
  local id = GetChannelName(name)
  if type(id) == "number" and id > 0 then return id end
end

local function hideChannel(name)
  local low = name:lower()
  for i = 1, MAX_WINDOWS do
    local frame = _G["ChatFrame" .. i]
    for _, listed in pairs(frame and frame.channelList or EMPTY) do
      if listed:lower() == low then
        pcall(frame.RemoveChannel, frame, name)
        break
      end
    end
  end
end

local function finishJoin(name, why)
  local job = joins[name]
  if not job then return end
  joins[name] = nil
  job.timer:Cancel()
  local id = not why and LA.ChannelId(name)
  if not id then
    why = why or "timeout"
    LA.db.channels[name] = nil
    LA.Log("channel-failed", name, why)
    return job.onDone(name, nil, why)
  end
  hideChannel(name)
  if id <= LOW_SLOTS and not relocated[name] then
    relocated[name] = true
    pcall(LeaveChannelByName, name)
    LA.After(RELOCATE_AFTER, startJoin, job)
    return
  end
  job.onDone(name, id)
end

startJoin = function(job)
  local name = job.name
  local id = LA.ChannelId(name)
  if id then return job.onDone(name, id) end
  if joins[name] then return end
  joins[name] = job
  LA.db.channels[name] = job.owner
  job.timer = LA.After(JOIN_TIMEOUT, finishJoin, name)
  local ok, err = pcall(JoinTemporaryChannel or JoinChannelByName or JoinPermanentChannel, name, job.pw)
  if not ok then finishJoin(name, err) end
end

function LA.JoinChannel(owner, name, pw, onDone)
  startJoin({ owner = owner, name = name, pw = pw, onDone = onDone })
end

function LA.LeaveChannels(owner, keep)
  local channels = LA.db.channels
  for name, by in pairs(channels) do
    if by == owner and not keep[name] then
      if LA.ChannelId(name) then pcall(LeaveChannelByName, name) end
      channels[name] = nil
    end
  end
end

local function onChannelNotice(_, kind, _, _, _, _, _, _, _, base)
  kind, base = LA.Safe(kind), LA.Safe(base)
  if not (base and joins[base]) then return end
  if JOINED[kind] then
    finishJoin(base)
  elseif REFUSED[kind] then
    finishJoin(base, kind)
  end
end

local function onPasswordRequest(_, name)
  name = LA.Safe(name)
  if not (name and joins[name]) then return end
  LA.After(0, StaticPopup_Hide, "CHAT_CHANNEL_PASSWORD", name)
  finishJoin(name, "password")
end

local function isOurNotice(_, _, _, _, _, _, _, _, _, _, base)
  base = LA.Safe(base)
  return base ~= nil and LA.db.channels[base] ~= nil
end

local gates, gateCount = {}, 0

local function pruneGates(now)
  gateCount = 0
  for _, byKey in pairs(gates) do
    for key, at in pairs(byKey) do
      if now - at > GATE_AGE then byKey[key] = nil else gateCount = gateCount + 1 end
    end
  end
end

function LA.Gate(kind, key, gap, peek)
  if not key then return false end
  local byKey = gates[kind] or {}
  gates[kind] = byKey
  local now, last = GetTime(), byKey[key]
  if last and now - last < gap then return false end
  if peek then return true end
  byKey[key] = now
  if last then return true end
  gateCount = gateCount + 1
  if gateCount > GATE_MAX then pruneGates(now) end
  return true
end

local Book = {}
Book.__index = Book

local function pruneBook(entries, now)
  local cutoff, keys = now - BOOK_DAYS * DAY, {}
  for key, e in pairs(entries) do
    if type(e) ~= "table" or (e.at or 0) < cutoff then entries[key] = nil else keys[#keys + 1] = key end
  end
  if #keys <= BOOK_MAX then return #keys end
  table.sort(keys, function(x, y) return entries[x].at > entries[y].at end)
  for i = BOOK_MAX + 1, #keys do entries[keys[i]] = nil end
  return BOOK_MAX
end

function LA.Book(netId)
  local store = LA.db.nets[netId]
  store.book = store.book or {}
  return setmetatable({ entries = store.book, size = pruneBook(store.book, time()) }, Book)
end

function Book:Remember(name, fields)
  local key = LA.NameKey(name)
  if not key then return end
  local e = self.entries[key]
  if not e then
    e = {}
    self.entries[key] = e
    self.size = self.size + 1
  end
  e.name, e.at = name, time()
  for field, value in pairs(fields or EMPTY) do e[field] = value end
  if self.size > BOOK_MAX then self.size = pruneBook(self.entries, e.at) end
end

function Book:List(keep)
  local out = {}
  for key, e in pairs(self.entries) do
    if keep(e, key) then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return a.at > b.at end)
  return out
end

local party, partyStale, leader = {}, true, nil

local function scanParty()
  wipe(party)
  leader, partyStale = nil, false
  local raid, me = IsInRaid(), LA.MyKey()
  for i = 1, raid and RAID_SIZE or PARTY_SIZE do
    local unit = (raid and "raid" or "party") .. i
    if UnitExists(unit) then
      local name = LA.Safe(GetUnitName(unit, true))
      if not name or name == UNKNOWNOBJECT then partyStale = true end
      local key = LA.NameKey(name)
      if key ~= me then
        party[key or unit] = unit
        if UnitIsGroupLeader(unit) then leader = unit end
      end
    end
  end
end

function LA.Party()
  if partyStale then scanParty() end
  return party
end

function LA.UnitFor(key) return LA.Party()[key] end

function LA.LeaderUnit()
  LA.Party()
  return leader
end

function LA.PhaseOf(unit)
  local ok, phase = pcall(UnitPhaseReason, unit)
  if not ok or secret(phase) then return false end
  return phase
end

function LA.LeaveGroup(why)
  LA.Log("leave", why)
  LA.Quiet()
  pcall(C_PartyInfo.LeaveParty)
end

local function partyChanged() partyStale = true end

LA.On("GROUP_ROSTER_UPDATE", partyChanged)
LA.On("PARTY_LEADER_CHANGED", partyChanged)

local nets, netById, byPrefix = {}, {}, {}

function LA.RegisterNetwork(net)
  nets[#nets + 1] = net
  netById[net.id] = net
end

function LA.Net(id) return netById[id] end

function LA.Call(net, method, ...)
  local fn = net and net[method]
  if fn then return LA.Try(net.id, fn, net, ...) end
end

function LA.Each(method, ...)
  local result
  for i = 1, #nets do result = LA.Call(nets[i], method, ...) or result end
  return result
end

local router = CreateFrame("Frame")

router:SetScript("OnEvent", function(_, _, prefix, text, chatType, sender)
  if secret(prefix) then return end
  local net = byPrefix[prefix]
  if not net then return end
  sender = LA.Safe(sender)
  local key = LA.NameKey(sender)
  if not key or key == LA.MyKey() then return end
  offlineAt[key] = nil
  LA.Stats.Heard(net.id, key)
  LA.Call(net, "OnAddon", prefix, LA.Safe(text), LA.Safe(chatType), sender, key)
end)

local tokens = {}
local labelEpoch, label

function LA.LayerEpoch() return LA.char and LA.char.epoch or 0 end

function LA.LayerToken(netId)
  local epoch, token = LA.LayerEpoch(), tokens[netId]
  if not token or token.epoch ~= epoch then
    token = { epoch = epoch, value = math.random(TOKEN_MIN, TOKEN_MAX) }
    tokens[netId] = token
  end
  return token.value
end

function LA.Label()
  local epoch = LA.LayerEpoch()
  if epoch ~= labelEpoch then
    local i = epoch % #LETTERS + 1
    labelEpoch, label = epoch, "Layer " .. LETTERS:sub(i, i)
  end
  return label
end

function LA.Moved(why)
  LA.char.epoch = LA.LayerEpoch() + 1
  LA.Log("moved", why, LA.Label())
  if LA.Setting("sound") then pcall(PlaySound, SOUNDKIT.READY_CHECK) end
  LA.Refresh()
end

local Limit = {}
LA.Limit = Limit

local function movesWithin(c, now, span)
  local n = 0
  for i = #c.moves, 1, -1 do
    if now - c.moves[i] > span then break end
    n = n + 1
  end
  return n
end

function Limit.Moved()
  local c, now = LA.char, time()
  local hold = c.hold
  if hold then
    local lockout = c.lockouts[#c.lockouts]
    if lockout and not lockout.resumedAt then lockout.resumedAt = now end
    if now < hold.untilAt and hold.lastMove then c.learned.window = math.max(MIN_WINDOW, now - hold.lastMove) end
    c.hold = nil
  end
  c.moves[#c.moves + 1] = now
  if #c.moves > MOVES_MAX then table.remove(c.moves, 1) end
end

function Limit.Refused()
  local c, now = LA.char, time()
  local n, lastMove = movesWithin(c, now, HOUR), c.moves[#c.moves]
  if n > 0 then c.learned.count = n end
  c.hold = { untilAt = (lastMove or now) + (c.learned.window or HOUR), lastMove = lastMove, count = n }
  c.lockouts[#c.lockouts + 1] = { at = now, count = n, lastMove = lastMove, window = c.learned.window }
  if #c.lockouts > LOCKOUTS_MAX then table.remove(c.lockouts, 1) end
  LA.Log("refused", n, "learned", c.learned.count, "window", c.learned.window)
  return n
end

function Limit.Likely()
  local count = LA.char.learned.count
  return count ~= nil and movesWithin(LA.char, time(), HOUR) >= count
end

function Limit.ThisHour()
  local c = LA.char
  return movesWithin(c, time(), HOUR), c.learned.count
end

function Limit.Left()
  local c = LA.char
  if not c.hold then return nil end
  local left = c.hold.untilAt - time()
  if left > 0 then return left end
  c.hold = nil
end

function LA.Countdown(sec)
  if sec <= SECONDS_SHOWN then
    local shown = math.max(1, math.ceil(sec))
    return shown .. "s", sec - (shown - 1)
  end
  local below = SECONDS_SHOWN
  for _, minutes in ipairs(COUNTDOWN_MINUTES) do
    if sec <= minutes * 60 then return "~" .. minutes .. "m", sec - below end
    below = minutes * 60
  end
  return "~1hr", sec - below
end

local pendingRefresh = false
local wakeAt, wakeTimer

local function flush()
  pendingRefresh = false
  LA.Try("ui", LA.UI.Refresh)
end

function LA.Refresh()
  if pendingRefresh then return end
  pendingRefresh = true
  C_Timer.After(0, flush)
end

local function wake()
  wakeAt, wakeTimer = nil, nil
  LA.Refresh()
end

function LA.WakeIn(sec)
  local at = GetTime() + sec
  if wakeAt and wakeAt <= at then return end
  if wakeTimer then wakeTimer:Cancel() end
  wakeAt, wakeTimer = at, C_Timer.NewTimer(sec + WAKE_SLACK, wake)
end

local flash = { untilAt = 0 }
local refreshAt, offBy

function LA.Flash(text, notice, seconds)
  flash.text, flash.untilAt = text, GetTime() + (seconds or FLASH_FOR)
  flash.notice = notice and { text = notice, tone = "warn" } or nil
  LA.Refresh()
end

function LA.ClearFlash() flash.untilAt = 0 end

local function confirmRefresh() pcall(C_PlayerInteractionManager.ShardTransferConfirm) end

local REFRESH_NOTICE = { text = "", tone = "warn", button = { text = "Refresh now", onClick = confirmRefresh } }

local function clock(sec)
  sec = math.max(0, math.floor(sec + 0.5))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local view = {}

local function resetView(v)
  v.label, v.help = LA.Label(), LA.Setting("help") and true or false
  v.status, v.tone, v.border, v.notice = nil, "idle", "neutral", nil
  v.swapText, v.swapEnabled = "Swap", true
end

local function idleView(v, now)
  if now < flash.untilAt then
    v.status, v.tone, v.border, v.notice = flash.text, "fail", "fail", flash.notice
    return LA.WakeIn(flash.untilAt - now)
  end
  local left = LA.Limit.Left()
  if left then
    local text, nextIn = LA.Countdown(left)
    v.status, v.tone = "Reset in " .. text, "warn"
    return LA.WakeIn(nextIn)
  end
  if refreshAt and refreshAt > now then
    local remaining = refreshAt - now
    v.status, v.tone, v.border, v.notice = "Refresh in " .. clock(remaining), "warn", "fail", REFRESH_NOTICE
    return LA.WakeIn((remaining + 0.5) % 1)
  end
  refreshAt = nil
  LA.Host.View(v)
end

function LA.View()
  local v = view
  resetView(v)
  if LA.Debug.Fill(v) then return v end
  if LA.disabled then
    v.status, v.tone, v.swapEnabled, v.help = "Off – " .. offBy .. " loaded", "off", false, false
  elseif not LA.Swap.View(v) then
    idleView(v, GetTime())
  end
  return v
end

local lastZoneAt = 0

local function zoneChanged()
  lastZoneAt = GetTime()
  LA.Refresh()
end

LA.On("ZONE_CHANGED_NEW_AREA", zoneChanged)
LA.On("PLAYER_ENTERING_WORLD", zoneChanged)

local function evictionLeft() return tonumber(LA.Safe(GetEvictionTimeRemaining())) or 0 end

local function onTransferImminent()
  refreshAt = GetTime() + evictionLeft()
  LA.Refresh()
end

local function readEviction()
  local left = evictionLeft()
  if left <= 0 then return end
  refreshAt = GetTime() + left
  LA.Refresh()
end

local function onTransferCancelled()
  refreshAt = nil
  LA.Refresh()
end

function LA.BorderAt(at)
  local sinceZone = at - lastZoneAt
  return (sinceZone >= 0 and sinceZone <= BORDER_BEFORE) or (sinceZone < 0 and -sinceZone <= BORDER_AFTER)
end

local function judgeTransfer(at, wasRefresh)
  if LA.BorderAt(at) and not wasRefresh then return end
  LA.Moved(wasRefresh and "world refresh" or "transfer")
end

local function onTransfer()
  local wasRefresh = refreshAt ~= nil
  refreshAt = nil
  if LA.Swap.ClaimsTransfer() then return end
  -- the zone change of a border crossing can arrive after its transfer
  LA.After(TRANSFER_SETTLE, judgeTransfer, GetTime(), wasRefresh)
end

local function otherLoaded()
  local found = {}
  for _, name in ipairs(OTHERS) do
    if C_AddOns.IsAddOnLoaded(name) then found[#found + 1] = name end
  end
  if #found == 0 then return nil end
  return table.concat(found, ", "), #found == 1 and found[1] or (#found .. " layer addons")
end

local function startNetwork(net)
  LA.db.nets[net.id] = LA.db.nets[net.id] or {}
  net.db = LA.db.nets[net.id]
  for _, prefix in ipairs(net.prefixes or EMPTY) do
    byPrefix[prefix] = net
    C_ChatInfo.RegisterAddonMessagePrefix(prefix)
  end
  LA.Call(net, "Init")
end

local function openChannels() LA.Each("OnChannels") end

local function watchChat()
  notFoundPattern = linePattern(ERR_CHAT_PLAYER_NOT_FOUND_S)
  if notFoundPattern then ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_SYSTEM", hideNotFound) end
  buildGroupLines()
  ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_SYSTEM", hideGroupLine)
  for _, event in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER" }) do
    ChatFrameUtil.AddMessageEventFilter(event, isOurNotice)
    LA.On(event, onChannelNotice)
  end
  LA.On("CHANNEL_PASSWORD_REQUEST", onPasswordRequest)
  router:RegisterEvent("CHAT_MSG_ADDON")
  router:RegisterEvent("CHAT_MSG_ADDON_LOGGED")
end

local function watchTransfers()
  LA.On("SHARD_TRANSFER_IMMINENT", onTransferImminent)
  LA.On("SHARD_TRANSFER_CANCELLED", onTransferCancelled)
  LA.On("SHARD_TRANSFER", onTransfer)
  LA.On("PLAYER_ENTERING_WORLD", readEviction)
end

local function start()
  LA.disabled, offBy = otherLoaded()
  if LA.disabled then
    print(TITLE .. " off: " .. LA.disabled .. " loaded.")
  else
    for _, net in ipairs(nets) do startNetwork(net) end
    watchChat()
    watchTransfers()
    LA.Host.Init()
    LA.Swap.Init()
    LA.After(CHANNEL_DELAY, openChannels)
  end
  LA.Try("ui", LA.UI.Init)
  LA.Refresh()
end

local MIGRATE = {
  function(db)
    for owner, store in pairs(db.nets) do
      for name in pairs(store.mine or EMPTY) do db.channels[name] = owner end
      store.mine = nil
    end
    local voidnet = db.nets.voidnet
    for _, e in pairs(voidnet and voidnet.book or EMPTY) do e.at, e.t = e.at or e.t, nil end
    local flh = db.nets.flh
    if flh and flh.peers then
      flh.book = {}
      for key, p in pairs(flh.peers) do
        if p.a and p.n then flh.book[key] = { name = p.n, at = p.a } end
      end
      flh.peers = nil
    end
    db.chars["?"] = nil
  end,
}

local function sweepSettings(settings)
  for key, value in pairs(settings) do
    if value == DEFAULTS[key] or (DEFAULTS[key] == nil and not UNDEFAULTED[key]) then settings[key] = nil end
  end
end

local function onAddonLoaded(_, name)
  if name ~= ADDON then return end
  LA.Off("ADDON_LOADED", onAddonLoaded)
  LayerAnarchyDB = LayerAnarchyDB or {}
  local db = LayerAnarchyDB
  db.settings, db.nets, db.chars = db.settings or {}, db.nets or {}, db.chars or {}
  db.channels, db.log, db.tallies = db.channels or {}, db.log or {}, db.tallies or {}
  for version = (db.version or 0) + 1, #MIGRATE do MIGRATE[version](db) end
  db.version = #MIGRATE
  sweepSettings(db.settings)
  LA.db = db
end

local function charRecord(guid, name)
  local chars = LA.db.chars
  local c = chars[guid] or (name and chars[name]) or { epoch = math.random(0, #LETTERS - 1) }
  chars[guid] = c
  if name then chars[name] = nil end
  c.moves, c.lockouts, c.learned = c.moves or {}, c.lockouts or {}, c.learned or { window = HOUR }
  return c
end

LA.On("ADDON_LOADED", onAddonLoaded)
LA.On("PLAYER_LOGIN", function()
  LA.char = charRecord(UnitGUID("player"), LA.Me())
  start()
end)

BINDING_HEADER_LAYERANARCHY = "Layer Anarchy"
BINDING_NAME_LAYERANARCHY_SWAP = "Swap layer"
BINDING_NAME_LAYERANARCHY_TOGGLE = "Show or hide"
BINDING_NAME_LAYERANARCHY_FOCUS = "Controller focus"

function LayerAnarchy_Swap() LA.SwapClick() end

function LayerAnarchy_Toggle() LA.SetSetting("hidden", not LA.Setting("hidden")) end

function LayerAnarchy_Focus() LA.UI.Focus() end

local function missingApis()
  local missing = {}
  for _, path in ipairs(API_CHECKS) do
    local v = _G
    for part in path:gmatch("[^.]+") do v = type(v) == "table" and v[part] or nil end
    if v == nil then missing[#missing + 1] = path end
  end
  return #missing > 0 and table.concat(missing, ", ") or "none"
end

local function countsText()
  local keys = {}
  for key in pairs(counts) do keys[#keys + 1] = key end
  table.sort(keys)
  for i, key in ipairs(keys) do keys[i] = key .. "=" .. counts[key] end
  return table.concat(keys, ", ")
end

local function printLog(n)
  local log = LA.db.log
  local at = logIndex(LA.db)
  for back = n, 1, -1 do
    local line = log[(at - 1 - back) % LOG_MAX + 1]
    if line then print(line) end
  end
end

local function printDiag()
  local v, c = LA.View(), LA.char
  print(string.format("|cffe8cc6aLayer Anarchy %s|r %s · %s · restricted=%s", LA.VERSION, v.label, tostring(v.status),
    tostring(LA.ChatRestricted())))
  print(string.format("moves=%d learned=%s window=%s lockouts=%d", #c.moves, tostring(c.learned.count),
    tostring(c.learned.window), #c.lockouts))
  print("missing APIs: " .. missingApis())
  local counted = countsText()
  if counted ~= "" then print("counts: " .. counted) end
  local t = LA.db.tallies
  print(string.format("hosted: moved %d, stuck %d, same %d, no-show %d · flying: moved %d, stuck %d, same %d, no-show %d",
    t["host.moved"] or 0, t["host.stuck"] or 0, t["host.same"] or 0, t["host.noshow"] or 0,
    t["fly.moved"] or 0, t["fly.stuck"] or 0, t["fly.same"] or 0, t["fly.noshow"] or 0))
  printLog(LOG_SHOWN)
end

local function cpuShare(metric)
  local P = C_AddOnProfiler
  local mine = P.GetAddOnMetric(ADDON, metric)
  local whole = P.GetApplicationMetric(metric) - P.GetOverallMetric(metric) + mine
  return mine, whole > 0 and (mine / whole * 100) or 0
end

local function printPerf()
  local M = Enum.AddOnProfilerMetric
  local recent, recentShare = cpuShare(M.RecentAverageTime)
  local average, averageShare = cpuShare(M.SessionAverageTime)
  print(string.format("%s cpu: now %.3f ms (%.2f%%), avg %.3f ms (%.2f%%), peak %.2f ms, ticks >1ms %d", TITLE,
    recent, recentShare, average, averageShare, C_AddOnProfiler.GetAddOnMetric(ADDON, M.PeakTime),
    C_AddOnProfiler.GetAddOnMetric(ADDON, M.CountTimeOver1Ms)))
  UpdateAddOnMemoryUsage()
  print(string.format("memory: %.0f KB", GetAddOnMemoryUsage(ADDON)))
end

local function setHelp(on) return function() LA.SetSetting("help", on) end end

local COMMANDS = {
  swap = LayerAnarchy_Swap, focus = LayerAnarchy_Focus,
  ["host on"] = setHelp(true), ["host off"] = setHelp(false),
  ["help on"] = setHelp(true), ["help off"] = setHelp(false),
  diag = printDiag, ["diag perf"] = printPerf,
}

function LA.Command(text, fn) COMMANDS[text] = fn end

local function printCommands()
  local names = {}
  for name in pairs(COMMANDS) do names[#names + 1] = name end
  table.sort(names)
  LA.Print("/la, /la " .. table.concat(names, ", /la "))
end

SLASH_LAYERANARCHY1 = "/la"
SLASH_LAYERANARCHY2 = "/layeranarchy"
SlashCmdList.LAYERANARCHY = function(msg)
  local text = (msg or ""):lower():match("^%s*(.-)%s*$")
  if text ~= "" then return (COMMANDS[text] or printCommands)() end
  LayerAnarchy_Toggle()
  if LA.Setting("hidden") then LA.Print("hidden – /la to show") end
end

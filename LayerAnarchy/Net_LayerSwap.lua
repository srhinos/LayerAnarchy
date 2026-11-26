local _, LA = ...

local NET = { id = "layerswap", name = "LayerSwap", prefixes = { "LayerSwap" } }
local PREFIX = NET.prefixes[1]
local RULES_TAG = "r3"
local BURST, ROUND_GAP, MAX_ASK = 8, 1, 49
local HEARD_GAP = 10
local WHO_WAIT, WHO_LATE_FOR, WHO_REUSE, WHO_MAX = 5, 30, 10, 50
local LAYER_ID_MAX = 24
local THROTTLED = Enum.SendAddonMessageResult.AddonMessageThrottle
local WHO_ORIGIN = Enum.SocialWhoOrigin.Social
local BLOCKED_PREFIXES = { "^%[nwb%]", "^%[autolayer%]" }
local BLOCKED_PHRASES = { "what layer", "which layer", "how many layer", "auto inv", "pst for" }
local BLOCKED_WORDS = {}
for word in ("wts wtb wtt lfm lfg guild raid enchant enchanting recruiting selling buying worldbuffs autoinv"):gmatch("%a+") do
  BLOCKED_WORDS[word] = true
end
local LAYER_WORDS = { layer = true, layers = true }
local WHO_LISTS = { "LFGWhoListFrame", "FriendsFrame" }

local who = { round = 0, muted = {} }
local classes
local onWhoList

local function muteWhoLists()
  for _, name in ipairs(WHO_LISTS) do
    local frame = _G[name]
    if frame and not who.muted[frame] and frame:IsEventRegistered("WHO_LIST_UPDATE") and not frame:IsVisible() then
      if not pcall(frame.UnregisterEvent, frame, "WHO_LIST_UPDATE") then return false end
      who.muted[frame] = true
    end
  end
  return true
end

local function unmuteWhoLists()
  for frame in pairs(who.muted) do
    pcall(frame.RegisterEvent, frame, "WHO_LIST_UPDATE")
    who.muted[frame] = nil
  end
end

local function classIDs()
  classes = classes or C_SpecializationInfo.GetAllClassIDs()
  return classes
end

local function whoFilters(zone, round)
  local filters = { classIDs = {}, raceIDs = {}, uiMapIDs = { zone } }
  if round == 0 then return filters end
  local ids = classIDs()
  local keep = ids[(round - 1) % #ids + 1]
  -- the filter lists classes to leave out
  for _, id in ipairs(ids) do
    if id ~= keep then filters.classIDs[#filters.classIDs + 1] = id end
  end
  return filters
end

local function closeWho(p)
  if who.pending ~= p then return end
  who.pending = nil
  LA.Off("WHO_LIST_UPDATE", onWhoList)
  C_FriendList.SetWhoToUi(p.panelWasOpen)
  unmuteWhoLists()
end

local function answer(p, names, why)
  local callbacks = p.callbacks
  p.callbacks = {}
  if names then who.last = { zone = p.zone, at = GetTime(), names = names } end
  for _, callback in ipairs(callbacks) do LA.Try("who", callback, names, why) end
end

local function whoDone(p, names, why)
  closeWho(p)
  answer(p, names, why)
end

local function whoTimeout(p)
  if who.pending ~= p or p.late then return end
  p.late = true
  answer(p, nil, "timeout")
  LA.After(WHO_LATE_FOR, closeWho, p)
end

local function advanceRound(num, total)
  who.capped = total > num or num >= WHO_MAX
  if total > num or who.round > 0 then who.round = (who.round + 1) % (#classIDs() + 1) end
end

local function whoNames(num, zoneName)
  local me, here, elsewhere, seen = LA.MyKey(), {}, {}, {}
  for i = 1, math.min(num, WHO_MAX) do
    local info = C_FriendList.GetWhoInfo(i)
    local name = info and LA.Safe(info.fullName)
    local key = LA.NameKey(name)
    if key and key ~= me and not seen[key] then
      seen[key] = true
      local list = LA.Safe(info.area) == zoneName and here or elsewhere
      list[#list + 1] = name
    end
  end
  for _, name in ipairs(elsewhere) do here[#here + 1] = name end
  return here
end

onWhoList = function()
  local p = who.pending
  if not p then return end
  if p.late then return closeWho(p) end
  local num, total = C_FriendList.GetNumWhoResults()
  num = tonumber(LA.Safe(num)) or 0
  advanceRound(num, tonumber(LA.Safe(total)) or num)
  whoDone(p, whoNames(num, p.zoneName))
end

local function replyLater(callback, names, why) LA.After(0, callback, names, why) end

function LA.Who(zone, callback)
  zone = tonumber(zone)
  if not zone then return replyLater(callback, nil, "error") end
  local last = who.last
  if last and last.zone == zone and GetTime() - last.at < WHO_REUSE then return replyLater(callback, last.names) end
  local p = who.pending
  if p and p.late then
    closeWho(p)
    p = nil
  end
  if p then
    if p.zone ~= zone then return replyLater(callback, nil, "busy") end
    p.callbacks[#p.callbacks + 1] = callback
    return
  end
  local info = C_Map.GetMapInfo(zone)
  local zoneName = info and LA.Safe(info.name)
  if type(zoneName) ~= "string" or zoneName == "" then return replyLater(callback, nil, "nozone") end
  local query = WHO_TAG_ZONE .. '"' .. zoneName .. '"'
  if who.roundZone ~= zone then who.round, who.roundZone = 0, zone end
  if not muteWhoLists() and InCombatLockdown() then
    unmuteWhoLists()
    return replyLater(callback, nil, "combat")
  end
  -- IsVisible: the Who list keeps its shown flag after its panel closes
  p = { zone = zone, zoneName = zoneName, callbacks = { callback },
    panelWasOpen = LFGParentFrame ~= nil and LFGParentFrame:IsVisible() }
  who.pending = p
  LA.On("WHO_LIST_UPDATE", onWhoList)
  C_FriendList.SetWhoToUi(true)
  local ok, err = pcall(C_FriendList.SendWho, query, WHO_ORIGIN, whoFilters(zone, who.round))
  if not ok then
    LA.Log("error", "who", err)
    return whoDone(p, nil, "error")
  end
  LA.After(WHO_WAIT, whoTimeout, p)
end

local book
local adopted
local cur

local function ourId()
  local epoch = LA.LayerEpoch()
  if adopted and adopted.epoch == epoch then return adopted.id end
  return LA.LayerToken(NET.id) .. "-" .. (epoch % 100)
end

local function whisper(text, target) return LA.SendAddon(PREFIX, text, "WHISPER", target) end

local function parseTag(text)
  local body = text:match("<LS([^<>]*)>")
  if not body then return nil end
  local tag = { nots = {} }
  tag.zone = tonumber(body:match("^%s*(%d+)%s") or body:match("^%s*(%d+)%s*$"))
  tag.want = body:match("want%s+(%d+%-%d+)")
  for id in body:gmatch("not%s+(%d+%-%d+)") do tag.nots[#tag.nots + 1] = id end
  tag.rules = (" " .. body .. " "):match("%sr(%d+)%s")
  return tag
end

local function remember(sender, zone, isHost)
  book:Remember(sender, { zone = zone, host = isHost })
end

local function hostsFirst(names)
  local first, rest, seen = {}, {}, {}
  for _, name in ipairs(names) do
    local key = LA.NameKey(name)
    if key and not seen[key] then
      seen[key] = true
      local e = book.entries[key]
      local list = (e and e.host) and first or rest
      list[#list + 1] = name
    end
  end
  for _, name in ipairs(rest) do first[#first + 1] = name end
  for i = #first, MAX_ASK + 1, -1 do first[i] = nil end
  return first
end

local function bookHosts(zone)
  local names = {}
  local hosts = book:List(function(e) return e.host and e.zone == zone end)
  for i = 1, math.min(#hosts, MAX_ASK) do names[i] = hosts[i].name end
  return names
end

local function position(zone)
  local pos = C_Map.GetPlayerMapPosition(zone, "player")
  if not pos then return nil end
  local x, y = LA.Safe(pos.x), LA.Safe(pos.y)
  if type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
  if x == 0 and y == 0 then return nil end
  return string.format("%.1f,%.1f", x * 100, y * 100)
end

local function request(zone, notId)
  local pos = position(zone)
  return "inv layer <LS " .. zone .. " not " .. notId .. " " .. RULES_TAG .. (pos and (" " .. pos) or "") .. ">"
end

local function live(st) return st ~= nil and cur == st and not st.stopped and st.ask.active end

local function progress(st) st.ask.Progress(NET.id, st.i - 1, #st.queue, st.more) end

local function round(st)
  if not live(st) then return end
  if IsInGroup() then
    st.held = true
    return
  end
  local sent = 0
  while sent < BURST and st.i <= #st.queue do
    local name = st.queue[st.i]
    st.ask.Asked(name)
    if whisper(st.line, name) == THROTTLED then break end
    st.i, sent = st.i + 1, sent + 1
  end
  progress(st)
  if st.i <= #st.queue then LA.After(ROUND_GAP, round, st) end
end

local function resume()
  local st = cur
  if not (st and st.held) then return end
  st.held = nil
  round(st)
end

local function markSeen(st, names)
  for _, name in ipairs(names) do st.seen[LA.NameKey(name)] = true end
end

local function enqueue(st, names)
  local added = 0
  for _, name in ipairs(names) do
    local key = LA.NameKey(name)
    if key and not st.seen[key] then
      st.seen[key] = true
      st.queue[#st.queue + 1] = name
      added = added + 1
    end
  end
  return added
end

function NET.Ask(_, ask)
  local zone = tonumber(ask.zone)
  if not zone then return end
  local st = { ask = ask, zone = zone, notId = ourId(), queue = {}, seen = {}, i = 1, replies = {} }
  st.line = request(zone, st.notId)
  cur = st
  LA.Who(zone, function(names)
    if not live(st) then return end
    st.queue = hostsFirst(names or bookHosts(zone))
    st.more = who.capped == true
    markSeen(st, st.queue)
    round(st)
  end)
end

function NET.More(_, ask)
  local st = cur
  if not (live(st) and st.ask == ask) then return end
  who.last = nil
  st.more = false
  progress(st)
  LA.Who(st.zone, function(names)
    if not live(st) then return end
    local added = names and enqueue(st, names) or 0
    st.more = who.capped and added > 0
    if added > 0 then round(st) else progress(st) end
  end)
end

function NET.StopAsk(_, ask) if cur and cur.ask == ask then cur.stopped = true end end

function NET.OnSwapResult(_, ask, result, hostName)
  local st = cur
  if result ~= "moved" or not st or st.ask ~= ask then return end
  local reply = st.replies[LA.NameKey(hostName) or ""]
  if reply and reply.zone == st.zone and reply.layer ~= st.notId then
    adopted = { id = reply.layer, epoch = LA.LayerEpoch() }
  end
end

local function onHeard(sender, key, asker, layer, zone, flag)
  if not LA.IsMe(asker) then return end
  zone = tonumber(zone)
  remember(sender, zone, flag == "h" or flag == "s")
  local st = cur
  if not live(st) then return end
  if layer:match("^%d+%-%d+$") and #layer <= LAYER_ID_MAX then st.replies[key] = { layer = layer, zone = zone } end
  if flag == "h" then st.ask.Offer(sender, NET.id) end
end

local function onSame(sender)
  remember(sender, nil, true)
  local st = cur
  if live(st) then st.ask.Refuse(sender) end
end

local function heard(asker, key, flag, force)
  if not LA.Gate("layerswap heard", key, force and 0 or HEARD_GAP) then return end
  whisper("heard " .. LA.Bare(asker) .. "|" .. ourId() .. "|" .. (LA.ZoneMapID() or "-") .. "|" .. flag, asker)
end

local function skipsUs(tag)
  local me = ourId()
  if tag.want and tag.want ~= me then return true end
  for _, id in ipairs(tag.nots) do
    if id == me then return true end
  end
  return false
end

local function hostAsk(text, sender, key)
  local tag = parseTag(text)
  if not (tag and tag.zone) then return end
  if not LA.Host.Can(sender, tag.zone) then return heard(sender, key, "-") end
  if skipsUs(tag) then
    if tag.nots[1] == ourId() then whisper("same", sender) end
    return heard(sender, key, "s")
  end
  heard(sender, key, "h", true)
  if not LA.Host.Invite(sender, NET.id) then heard(sender, key, "-", true) end
end

function LA.LayerAsk(text)
  local low = text:lower()
  for _, pattern in ipairs(BLOCKED_PREFIXES) do
    if low:find(pattern) then return false end
  end
  for _, phrase in ipairs(BLOCKED_PHRASES) do
    if low:find(phrase, 1, true) then return false end
  end
  local hit = false
  for word in low:gmatch("%a+") do
    if BLOCKED_WORDS[word] then return false end
    if LAYER_WORDS[word] then hit = true end
  end
  return hit
end

local function onWhisper(_, text, sender)
  text, sender = LA.Safe(text), LA.Safe(sender)
  if type(text) ~= "string" or type(sender) ~= "string" or not LA.LayerAsk(text) then return end
  local tag = parseTag(text)
  if LA.Host.Can(sender, tag and tag.zone, true) then LA.Host.Invite(sender, NET.id) end
end

function NET.OnAddon(_, _, text, chatType, sender, key)
  if type(text) ~= "string" then return end
  local whispered = chatType == "WHISPER"
  if whispered and text:find("^[Ii][Nn][Vv] [Ll][Aa][Yy][Ee][Rr]") then return hostAsk(text, sender, key) end
  local asker, layer, zone, flag = text:match("^heard (.-)|([^|]*)|([^|]*)|([^|]*)$")
  if asker then return onHeard(sender, key, asker, layer, zone, flag) end
  if whispered and text == "same" then onSame(sender) end
end

function NET.Init(net)
  book = LA.Book(net.id)
  LA.On("CHAT_MSG_WHISPER", onWhisper)
  LA.On("GROUP_LEFT", resume)
end

LA.RegisterNetwork(NET)

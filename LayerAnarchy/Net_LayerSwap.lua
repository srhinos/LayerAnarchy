local _, LA = ...

local NET = { id = "layerswap", name = "LayerSwap", prefixes = { "LayerSwap" } }
local PREFIX = NET.prefixes[1]
local RULES_TAG = "r3"
local BURST, BURST_GAP, MAX_ASK, REPLY_WINDOW, HOST_RECENT = 8, 1, 49, 4, 3600
local HEARD_GAP, LAYER_ID_MAX, EPOCH_MOD = 10, 24, 100
local WHO_WAIT, WHO_LATE_FOR, WHO_REUSE, WHO_MAX, WHO_GAP = 5, 30, 10, 50, 2.5
local THROTTLED = Enum.SendAddonMessageResult.AddonMessageThrottle
local WHO_ORIGIN = Enum.SocialWhoOrigin.Social
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
  local full = total > num or num >= WHO_MAX
  if full or who.round > 0 then who.round = (who.round + 1) % (#classIDs() + 1) end
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
  num, total = LA.Safe(num) or 0, LA.Safe(total) or 0
  LA.Log("who-result", num, total)
  advanceRound(num, total)
  whoDone(p, whoNames(num, p.zoneName))
end

local function replyLater(callback, names, why) LA.After(0, callback, names, why) end

local function sendWho(p)
  if who.pending ~= p then return end
  if not muteWhoLists() and InCombatLockdown() then return whoDone(p, nil, "combat") end
  -- IsVisible: the Who list keeps its shown flag after its panel closes
  p.panelWasOpen = LFGParentFrame ~= nil and LFGParentFrame:IsVisible()
  LA.On("WHO_LIST_UPDATE", onWhoList)
  C_FriendList.SetWhoToUi(true)
  who.sentAt = GetTime()
  local ok, err = pcall(C_FriendList.SendWho, WHO_TAG_ZONE .. '"' .. p.zoneName .. '"', WHO_ORIGIN, whoFilters(p.zone, who.round))
  if not ok then
    LA.Log("error", "who", err)
    return whoDone(p, nil, "error")
  end
  LA.Log("who", p.zone, who.round)
  LA.After(WHO_WAIT, whoTimeout, p)
end

function LA.Who(zone, callback)
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
  if not zoneName or zoneName == "" then return replyLater(callback, nil, "nozone") end
  if who.sentAt and GetTime() - who.sentAt < WHO_GAP then return replyLater(callback, nil, "cooldown") end
  if who.roundZone ~= zone then who.round, who.roundZone = 0, zone end
  p = { zone = zone, zoneName = zoneName, callbacks = { callback } }
  who.pending = p
  -- SendWho only works inside the click or key press that asked for it, so it can't wait for a timer
  sendWho(p)
end

local book, adopted, cur

local function ourId()
  local epoch = LA.LayerEpoch()
  if adopted and adopted.epoch == epoch then return adopted.id end
  return LA.LayerToken(NET.id) .. "-" .. (epoch % EPOCH_MOD)
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

local function knownHosts(zone)
  local now = time()
  local hosts = book:List(function(e, key)
    return e.host and e.zone == zone and now - e.at < HOST_RECENT and not LA.Offline(key)
  end)
  local names = {}
  for i, e in ipairs(hosts) do names[i] = e.name end
  return names
end

local function position(zone)
  local pos = C_Map.GetPlayerMapPosition(zone, "player")
  if not pos then return nil end
  local x, y = LA.Safe(pos.x), LA.Safe(pos.y)
  if not (x and y) or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
  if x == 0 and y == 0 then return nil end
  return string.format("%.1f,%.1f", x * 100, y * 100)
end

local function request(zone, notId)
  local pos = position(zone)
  return "inv layer <LS " .. zone .. " not " .. notId .. " " .. RULES_TAG .. (pos and (" " .. pos) or "") .. ">"
end

local function live(st) return st ~= nil and cur == st and not st.stopped and st.ask.active end

local function cooldownLeft() return who.sentAt and who.sentAt + WHO_GAP - GetTime() or 0 end

local function batchFailed(st)
  local b = st.batch
  if not (st.more and b) or st.i <= b.to then return false end
  for i = b.from, b.to do
    if st.ask.Offered(st.queue[i]) then return false end
  end
  local wait = math.max(b.at + REPLY_WINDOW - GetTime(), cooldownLeft())
  return wait <= 0, wait
end

local function progress(st)
  if not live(st) then return end
  local failed, wait = batchFailed(st)
  if st.judge then st.judge:Cancel() end
  st.judge = wait and wait > 0 and LA.After(wait, progress, st) or nil
  st.ask.Progress(NET.id, #st.queue - st.i + 1, failed)
end

local function burst(st)
  st.next = nil
  if not live(st) then return end
  if IsInGroup() then
    st.held = true
    return
  end
  local b, sent = st.batch, 0
  while sent < BURST and st.i <= #st.queue do
    local name = st.queue[st.i]
    if whisper(st.line, name) == THROTTLED then break end
    st.ask.Asked(name)
    if b and st.i <= b.to then b.at = GetTime() end
    st.i, sent = st.i + 1, sent + 1
  end
  progress(st)
  if st.i <= #st.queue then st.next = LA.After(BURST_GAP, burst, st) end
end

local function pump(st)
  if st.next or st.held then return progress(st) end
  burst(st)
end

local function resume()
  local st = cur
  if not (st and st.held) then return end
  st.held = nil
  burst(st)
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

local function newBatch(st, names)
  local b = { from = #st.queue + 1, at = GetTime() }
  enqueue(st, names)
  b.to = #st.queue
  st.batch = b
  pump(st)
end

local function searched(st, names)
  if not live(st) then return end
  st.searching = false
  st.more = names ~= nil and who.round ~= 0
  newBatch(st, names and hostsFirst(names) or knownHosts(st.zone))
end

local function onHeard(sender, key, asker, layer, zone, flag)
  if not LA.IsMe(asker) then return end
  zone = tonumber(zone)
  local real = #layer <= LAYER_ID_MAX and layer:match("^%d+%-%d+$") ~= nil
  book:Remember(sender, { zone = zone, host = real and (flag == "h" or flag == "s") })
  local st = cur
  if not (real and live(st)) then return end
  st.replies[key] = { layer = layer, zone = zone }
  if flag == "h" and layer ~= st.notId then
    st.ask.Offer(sender, NET.id)
    progress(st)
  end
end

local function onSame(sender)
  book:Remember(sender, { host = true })
  local st = cur
  if not live(st) then return end
  st.ask.Refuse(sender)
  progress(st)
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

local function onWhisper(_, text, sender)
  text, sender = LA.Safe(text), LA.Safe(sender)
  if not (text and sender and LA.LayerAsk(text)) then return end
  local tag = parseTag(text)
  if LA.Host.Can(sender, tag and tag.zone, true) then LA.Host.Invite(sender, NET.id) end
end

function NET.Init(net)
  book = LA.Book(net.id)
  LA.On("CHAT_MSG_WHISPER", onWhisper)
  LA.On("GROUP_LEFT", resume)
end

function NET.OnAddon(_, _, text, chatType, sender, key)
  if not text then return end
  local whispered = chatType == "WHISPER"
  if whispered and text:find("^[Ii][Nn][Vv] [Ll][Aa][Yy][Ee][Rr]") then return hostAsk(text, sender, key) end
  local asker, layer, zone, flag = text:match("^heard (.-)|([^|]*)|([^|]*)|([^|]*)$")
  if asker then return onHeard(sender, key, asker, layer, zone, flag) end
  if whispered and text == "same" then onSame(sender) end
end

function NET.Ask(_, ask)
  local zone = ask.zone
  if not zone then return end
  local st = { ask = ask, zone = zone, notId = ourId(), queue = {}, seen = {}, i = 1, replies = {}, searching = true }
  st.line = request(zone, st.notId)
  cur = st
  LA.Who(zone, function(names) searched(st, names) end)
end

function NET.Round(_, ask)
  local st = cur
  if not (live(st) and st.ask == ask) then return false end
  if enqueue(st, knownHosts(st.zone)) > 0 then pump(st) end
  return st.searching or st.i <= #st.queue
end

function NET.Search(_, ask)
  local st = cur
  if not (live(st) and st.ask == ask and st.more) then return end
  st.more, st.searching = false, true
  progress(st)
  who.last = nil
  LA.Who(st.zone, function(names)
    if names then return searched(st, names) end
    if not live(st) then return end
    st.more, st.searching = true, false
    progress(st)
  end)
end

function NET.StopAsk(_, ask) if cur and cur.ask == ask then cur.stopped = true end end

function NET.OnSwapResult(_, ask, result, hostName)
  local st = cur
  if result ~= "moved" or not st or st.ask ~= ask then return end
  local reply = st.replies[LA.NameKey(hostName)]
  if reply and reply.zone == st.zone and reply.layer ~= st.notId then
    adopted = { id = reply.layer, epoch = LA.LayerEpoch() }
  end
end

function NET.OnHostFailed(_, ask)
  local st = cur
  if live(st) and st.ask == ask then progress(st) end
end

LA.RegisterNetwork(NET)

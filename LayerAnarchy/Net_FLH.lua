local _, LA = ...

local NET = { id = "flh", name = "Forever Layer Hop", prefixes = { "FLHNET2" } }
local PREFIX = NET.prefixes[1]
local WIRE = "0.1.3"
-- never above FLH's own release, or its users are told they're out of date
local VERSION = "0.2.1"
local LIVE, PEERS_MAX, LOAD_WINDOW, GUILD_HI_GAP = 180, 300, 60, 120
local OFFER_WINDOW, OFFER_TTL, OFFER_KEEP = 2.5, 25, 30
local REPLY_WAIT, INVITE_WAIT, MAX_TRIES, LQ_MAX = 5, 25, 3, 8
local WP_GAP, GQ_GAP, CQ_GAP, DISCOVER_GAP, DR_GAP = 2, 3, 10, 20, 3
local MSG_MAX, CID_TAG, ID_MIN, ID_MAX = 255, "|CID=", 10000, 99999
local LANGS = { en = true, pt = true, es = true, de = true, fr = true, ko = true, zh = true, ja = true, ru = true }
local REASONS = { off = "hosting disabled", instance = "inside an instance" }
local GROUP_CHATS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }
local HOP_REPLIES = { "LW", "HQ", "LI", "LD", "LA", "LN" }

local peers, peerCount = {}, 0
local book
local cur
local avoid, offersMade = {}, {}
local lastOfferAt, lastGuildHI = -math.huge, -math.huge
local cid, realm, lang, tail

local function split(s)
  local fields, pos = {}, 1
  while true do
    local at = s:find("[|:]", pos)
    if not at then
      fields[#fields + 1] = s:sub(pos)
      return fields
    end
    fields[#fields + 1] = s:sub(pos, at - 1)
    pos = at + 1
  end
end

local function isNum(v) return type(v) == "string" and v:match("^%d+$") ~= nil end
local function isKey(v) return isNum(v) and tonumber(v) > 0 end
local function newId() return tostring(math.random(ID_MIN, ID_MAX)) end
local function layerKey() return tostring(LA.LayerToken(NET.id)) end
local function myMap() return LA.RawMapID() or 0 end
local function hostFlag() return LA.Host.Can() and 1 or 0 end

local function send(msg, chatType, target)
  if cid and #msg + #CID_TAG + #cid <= MSG_MAX then msg = msg .. CID_TAG .. cid end
  return LA.SendAddon(PREFIX, msg, chatType, target)
end

local function whisper(msg, target) return send(msg, "WHISPER", target) end

local function here(map)
  map = tonumber(map)
  if not map then return false end
  if map == LA.RawMapID() then return true end
  local zone = LA.ZoneOf(map)
  return zone ~= nil and zone == LA.ZoneMapID()
end

local function prunePeers()
  local t = GetTime()
  peerCount = 0
  for who, p in pairs(peers) do
    if t - p.t > LIVE then peers[who] = nil else peerCount = peerCount + 1 end
  end
end

local function see(who, name, map, key, host)
  local p = peers[who]
  if not p then
    p = {}
    peers[who] = p
    peerCount = peerCount + 1
    if peerCount > PEERS_MAX then prunePeers() end
  end
  p.n, p.t = name, GetTime()
  map = tonumber(map)
  if map and map > 0 then p.m = map end
  if isKey(key) then p.k = key end
  if host ~= nil then p.h = tonumber(host) == 1 and 1 or 0 end
end

local function hiMsg()
  return ("HI|%d|%s|%d|%s|%s|%s"):format(myMap(), layerKey(), hostFlag(), VERSION, realm, tail)
end

local function guildHI()
  local t = GetTime()
  if t - lastGuildHI < GUILD_HI_GAP or not LA.Host.Can() then return end
  lastGuildHI = t
  send(hiMsg(), "GUILD")
end

local nextStep

local function fire(st, gen)
  if cur == st and st.gen == gen and st.ask.active then st.armed(st) end
end

local function arm(st, secs, fn)
  st.gen = st.gen + 1
  st.armed = fn
  LA.After(secs, fire, st, st.gen)
end

local function dropRequest(st)
  st.req = nil
  nextStep(st)
end

local function endOfferWindow(st)
  st.waiting = false
  nextStep(st)
end

local function offer(st, name)
  local who = LA.NameKey(name)
  if who and not st.offered[who] then
    st.offered[who] = true
    st.ask.Offer(name, NET.id)
  end
end

local function avoided(who) return avoid[who] == LA.LayerEpoch() end

local function candidate(st, who, p, t, hostsOnly)
  return p.n and p.m and p.k and t - p.t <= LIVE and not st.tried[who] and (not hostsOnly or p.h == 1)
    and not avoided(who) and LA.ZoneOf(p.m) == st.zone
end

local function pick(st, hostsOnly)
  local list, t = {}, GetTime()
  for who, p in pairs(peers) do
    if candidate(st, who, p, t, hostsOnly) then list[#list + 1] = who end
  end
  table.sort(list, function(a, b)
    local bookA, bookB = book.entries[a] ~= nil, book.entries[b] ~= nil
    if bookA ~= bookB then return bookA end
    return peers[a].t > peers[b].t
  end)
  return list
end

local function tryHost(st, who, o)
  local p = peers[who]
  st.tried[who], st.tries = true, st.tries + 1
  local id
  if o then
    id = st.lqId
    whisper(("LR|%s|%d|%s|%s"):format(id, o.m, o.k, WIRE), p.n)
  else
    id = newId()
    whisper(("DR|%s|%d|%s|%s"):format(id, p.m, p.k, layerKey()), p.n)
  end
  st.req = { id = id, who = who, name = p.n }
  st.ask.Asked(p.n)
  arm(st, REPLY_WAIT, dropRequest)
end

local function bestOffer(st)
  local best, bo, t = nil, nil, GetTime()
  for who, o in pairs(st.offers) do
    if not st.tried[who] and peers[who] and t - o.t < OFFER_TTL
      and (not bo or o.size < bo.size or (o.size == bo.size and o.load < bo.load)) then
      best, bo = who, o
    end
  end
  return best, bo
end

local function broadcastLQ(st)
  local list = pick(st, false)
  if not list[1] then return end
  st.lqId = newId()
  local key = layerKey()
  for i = 1, math.min(#list, LQ_MAX) do
    local p = peers[list[i]]
    st.lqTo[list[i]] = true
    whisper(("LQ|%s|%d|*|%s|%s|LANG=%s"):format(st.lqId, p.m, key, key, lang), p.n)
    st.ask.Asked(p.n)
  end
  st.waiting = true
  arm(st, OFFER_WINDOW, endOfferWindow)
end

nextStep = function(st)
  if cur ~= st or not st.ask.active or not st.zone or st.req or st.waiting or st.tries >= MAX_TRIES then return end
  local best, bo = bestOffer(st)
  if best then return tryHost(st, best, bo) end
  local hosts = pick(st, true)
  if hosts[1] then return tryHost(st, hosts[1]) end
  if not st.lqId then broadcastLQ(st) end
end

local function poke() if cur then nextStep(cur) end end

local function onOffer(f, who, sender)
  local st = cur
  if not st or not st.ask.active or f[2] ~= st.lqId or not st.lqTo[who] then return end
  local map = tonumber(f[3])
  if not map or not isKey(f[4]) then return end
  see(who, sender, map, f[4], 1)
  st.offers[who] = { m = map, k = f[4], size = tonumber(f[5]) or 0, load = tonumber(f[6]) or 0, t = GetTime() }
  offer(st, sender)
  nextStep(st)
end

local function onHop(cmd, f, who)
  local st = cur
  local r = st and st.req
  if not r or r.done or f[2] ~= r.id or who ~= r.who or not st.ask.active then return end
  if cmd == "LW" or cmd == "HQ" then
    if r.ack then return end
    r.ack = true
    arm(st, INVITE_WAIT, dropRequest)
  elseif cmd == "LI" then
    r.done = true
    arm(st, INVITE_WAIT, dropRequest)
    book:Remember(r.name)
    local leader = f[3] == "S" and f[4] ~= "" and f[4]
    if leader then
      st.ask.Asked(leader)
      offer(st, leader)
    end
    offer(st, r.name)
  else
    if cmd == "LN" and f[3] == "layer changed" and peers[who] then peers[who].k = nil end
    st.ask.Refuse(r.name)
    st.req = nil
    st.gen = st.gen + 1
    nextStep(st)
  end
end

local function serve(id, sender, zone)
  local ok, why = LA.Host.Can(sender, zone)
  if not ok then return whisper(("LN|%s|%s"):format(id, REASONS[why] or "busy"), sender) end
  whisper("LW|" .. id, sender)
  if LA.Host.Invite(sender, NET.id) then
    whisper("LI|" .. id, sender)
  else
    whisper(("LN|%s|invite failed"):format(id), sender)
  end
end

local function direct(f, ct, who, sender, gap)
  local id = f[2]
  if ct ~= "WHISPER" or not isNum(id) or not isKey(f[4]) then return end
  if gap and not LA.Gate("flh dr", who, gap) then return end
  if not here(f[3]) or f[4] ~= layerKey() then return whisper(("LN|%s|layer changed"):format(id), sender) end
  serve(id, sender, nil)
end

local function rememberOffer(who, id, zone)
  local t = GetTime()
  if t - lastOfferAt > OFFER_KEEP then wipe(offersMade) end
  lastOfferAt = t
  local o = offersMade[who] or {}
  o.id, o.t, o.zone = id, t, zone
  offersMade[who] = o
end

local H = {}

H.WP = function(f, ct, who, sender)
  if ct ~= "WHISPER" or not isNum(f[2]) then return end
  see(who, sender, f[5], f[6], f[7])
  if LA.Gate("flh wp", who, WP_GAP) then
    whisper(("WR|%s|%s|%s|%d|%s|%d|%s"):format(f[2], realm, WIRE, myMap(), layerKey(), hostFlag(), tail), sender)
  end
  poke()
end

H.WR = function(f, ct, who, sender)
  if ct ~= "WHISPER" then return end
  see(who, sender, f[5], f[6], f[7])
  poke()
end

H.HI = function(f, ct, who, sender)
  see(who, sender, f[2], f[3], f[4])
  if ct == "GUILD" then guildHI() end
  poke()
end

H.GQ = function(_, ct, who)
  if GROUP_CHATS[ct] and LA.Gate("flh gq", who, GQ_GAP) then send(hiMsg(), ct) end
end

H.CQ = function(f, ct, who, sender)
  if (ct ~= "WHISPER" and ct ~= "CHANNEL") or not isNum(f[2]) then return end
  see(who, sender, f[3], f[4], f[5])
  if (ct == "WHISPER" or here(f[3])) and LA.Gate("flh cq", who, CQ_GAP) then
    whisper(("CA|%s|%d|%s|%d|%s|%s|%s"):format(f[2], myMap(), layerKey(), hostFlag(), WIRE, realm, tail), sender)
  end
  poke()
end

H.CA = function(f, ct, who, sender)
  if ct ~= "WHISPER" then return end
  see(who, sender, f[3], f[4], f[5])
  poke()
end

H.DISCOVER = function(f, ct, who, sender)
  see(who, sender, f[2], f[3])
  if here(f[2]) and LA.Gate("flh discover", who, DISCOVER_GAP) then
    local key = layerKey()
    whisper(("P|%d|%s|%s|%s|%s"):format(myMap(), key, WIRE, key, tail), sender)
  end
  if ct == "GUILD" then guildHI() end
end

H.LQ = function(f, ct, who, sender)
  if (ct ~= "WHISPER" and ct ~= "CHANNEL") or not isNum(f[2]) then return end
  see(who, sender, f[3], f[5])
  local key = layerKey()
  if not here(f[3]) or (f[4] ~= "*" and f[4] ~= key) or f[5] == key then return end
  local zone = LA.ZoneOf(f[3])
  if not LA.Host.Can(sender, zone) then return end
  rememberOffer(who, f[2], zone)
  whisper(("LO|%s|%d|%s|%d|%d|ACT=0|LANG=%s"):format(f[2], myMap(), key, GetNumGroupMembers(),
    LA.Host.Recent(LOAD_WINDOW), lang), sender)
end

H.LR = function(f, _, who, sender)
  local id = f[2]
  if not isNum(id) then return end
  local o = offersMade[who]
  offersMade[who] = nil
  if not o or o.id ~= id or GetTime() - o.t > OFFER_KEEP then
    return whisper(("LN|%s|host unavailable"):format(id), sender)
  end
  if not here(f[3]) or f[4] ~= layerKey() then return whisper(("LN|%s|layer changed"):format(id), sender) end
  serve(id, sender, o.zone)
end

H.DR = function(f, ct, who, sender) direct(f, ct, who, sender, DR_GAP) end
H.ZI = function(f, ct, who, sender) direct(f, ct, who, sender) end
H.LO = function(f, _, who, sender) onOffer(f, who, sender) end
for _, cmd in ipairs(HOP_REPLIES) do
  H[cmd] = function(f, _, who) onHop(cmd, f, who) end
end

local function localeLang()
  local l = GetLocale():sub(1, 2)
  return LANGS[l] and l or "other"
end

local function realmTag()
  local r = tostring(LA.Safe(GetNormalizedRealmName() or GetRealmName()) or ""):gsub("[|:%s]", "")
  return r ~= "" and r or "?"
end

function NET.Init(net)
  book = LA.Book(net.id)
  lang, realm = localeLang(), realmTag()
  tail = ("LANG=%s|POP=0|BUILD=%s"):format(lang, VERSION)
  local guid = LA.Safe(UnitGUID("player"))
  cid = guid and (tostring(guid):gsub("[|:]", "_"))
end

function NET.OnAddon(_, _, text, chatType, sender, who)
  if type(text) ~= "string" then return end
  local handler = H[text:match("^[^|:]+")]
  if handler then handler(split(text), chatType, who, sender) end
end

function NET.Ask(_, ask)
  if cur then cur.gen = cur.gen + 1 end
  cur = { ask = ask, zone = ask.zone, gen = 0, tries = 0, tried = {}, offers = {}, offered = {}, lqTo = {} }
  nextStep(cur)
end

function NET.StopAsk(_, ask)
  if cur and cur.ask == ask then
    cur.gen = cur.gen + 1
    cur = nil
  end
end

function NET.OnHostFailed(_, ask, why, hostName)
  local who = LA.NameKey(hostName)
  if who and why == "same" then avoid[who] = LA.LayerEpoch() end
  if cur and cur.ask == ask then
    cur.req = nil
    cur.gen = cur.gen + 1
    nextStep(cur)
  end
end

function NET.OnSwapResult(_, ask, result, hostName)
  local who = LA.NameKey(hostName)
  if who and (result == "same" or result == "moved") then avoid[who] = LA.LayerEpoch() end
  if cur and cur.ask == ask then
    cur.gen = cur.gen + 1
    cur = nil
  end
end

LA.RegisterNetwork(NET)

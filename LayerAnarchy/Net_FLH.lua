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
local LAYER_CHANGED = "layer changed"
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

local function isNum(v) return v ~= nil and v:find("^%d+$") ~= nil end

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

local function refuse(id, target, reason) return whisper(("LN|%s|%s"):format(id, reason), target) end

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
  for key, p in pairs(peers) do
    if t - p.t > LIVE then peers[key] = nil else peerCount = peerCount + 1 end
  end
end

local function see(key, name, map, layer, host)
  local p = peers[key]
  if not p then
    p = {}
    peers[key] = p
    peerCount = peerCount + 1
    if peerCount > PEERS_MAX then prunePeers() end
  end
  p.n, p.t = name, GetTime()
  map = tonumber(map)
  if map and map > 0 then p.m = map end
  if isKey(layer) then p.k = layer end
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

local function live(st) return st ~= nil and st == cur and st.ask.active end

local function fire(st, gen)
  if live(st) and st.gen == gen then st.armed(st) end
end

local function arm(st, secs, fn)
  st.gen = st.gen + 1
  st.armed = fn
  LA.After(secs, fire, st, st.gen)
end

local function dropRequest(st)
  st.req = nil
  st.gen = st.gen + 1
  nextStep(st)
end

local function endOfferWindow(st)
  st.waiting = false
  nextStep(st)
end

local function offer(st, name)
  local key = LA.NameKey(name)
  if key and not st.offered[key] then
    st.offered[key] = true
    st.ask.Offer(name, NET.id)
  end
end

local function avoided(key) return avoid[key] == LA.LayerEpoch() end

local function candidate(st, key, p, t, hostsOnly)
  return p.n and p.m and p.k and t - p.t <= LIVE and not st.tried[key] and (not hostsOnly or p.h == 1)
    and not avoided(key) and LA.ZoneOf(p.m) == st.zone and (not st.only or st.only[key])
end

local function pick(st, hostsOnly)
  local list, t = {}, GetTime()
  for key, p in pairs(peers) do
    if candidate(st, key, p, t, hostsOnly) then list[#list + 1] = key end
  end
  table.sort(list, function(a, b)
    local bookA, bookB = book.entries[a] ~= nil, book.entries[b] ~= nil
    if bookA ~= bookB then return bookA end
    return peers[a].t > peers[b].t
  end)
  return list
end

local function tryHost(st, key, o)
  local p = peers[key]
  st.tried[key], st.tries = true, st.tries + 1
  local id
  if o then
    id = st.lqId
    whisper(("LR|%s|%d|%s|%s"):format(id, o.m, o.k, WIRE), p.n)
  else
    id = newId()
    whisper(("DR|%s|%d|%s|%s"):format(id, p.m, p.k, layerKey()), p.n)
  end
  st.req = { id = id, key = key, name = p.n }
  st.ask.Asked(p.n)
  arm(st, REPLY_WAIT, dropRequest)
end

local function bestOffer(st)
  local best, bo, t = nil, nil, GetTime()
  for key, o in pairs(st.offers) do
    if not st.tried[key] and peers[key] and t - o.t < OFFER_TTL
      and (not bo or o.size < bo.size or (o.size == bo.size and o.load < bo.load)) then
      best, bo = key, o
    end
  end
  return best, bo
end

local function broadcastLQ(st)
  local list = pick(st, false)
  if not list[1] then return end
  st.lqId = newId()
  local layer = layerKey()
  for i = 1, math.min(#list, LQ_MAX) do
    local p = peers[list[i]]
    st.lqTo[list[i]] = true
    whisper(("LQ|%s|%d|*|%s|%s|LANG=%s"):format(st.lqId, p.m, layer, layer, lang), p.n)
    st.ask.Asked(p.n)
  end
  st.waiting = true
  arm(st, OFFER_WINDOW, endOfferWindow)
end

nextStep = function(st)
  if not live(st) or st.req or st.waiting or st.tries >= MAX_TRIES then return end
  local best, bo = bestOffer(st)
  if best then return tryHost(st, best, bo) end
  local hosts = pick(st, not st.only)
  if hosts[1] then return tryHost(st, hosts[1]) end
  if not (st.lqId or st.only) then broadcastLQ(st) end
end

local function poke() if cur then nextStep(cur) end end

local function onOffer(f, key, sender)
  local st = cur
  if not live(st) or f[2] ~= st.lqId or not st.lqTo[key] then return end
  local map = tonumber(f[3])
  if not map or not isKey(f[4]) then return end
  see(key, sender, map, f[4], 1)
  st.offers[key] = { m = map, k = f[4], size = tonumber(f[5]) or 0, load = tonumber(f[6]) or 0, t = GetTime() }
  offer(st, sender)
  nextStep(st)
end

local function onHop(cmd, f, key)
  local st = cur
  local r = live(st) and st.req
  if not r or r.done or f[2] ~= r.id or key ~= r.key then return end
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
    if cmd == "LN" and f[3] == LAYER_CHANGED and peers[key] then peers[key].k = nil end
    st.ask.Refuse(r.name)
    dropRequest(st)
  end
end

local function hostAsk(id, sender, zone)
  local ok, why = LA.Host.Can(sender, zone)
  if not ok then return refuse(id, sender, REASONS[why] or "busy") end
  whisper("LW|" .. id, sender)
  if LA.Host.Invite(sender, NET.id) then
    whisper("LI|" .. id, sender)
  else
    refuse(id, sender, "invite failed")
  end
end

local function direct(f, ct, key, sender, gap)
  local id = f[2]
  if ct ~= "WHISPER" or not isNum(id) or not isKey(f[4]) then return end
  if gap and not LA.Gate("flh dr", key, gap) then return end
  if not here(f[3]) or f[4] ~= layerKey() then return refuse(id, sender, LAYER_CHANGED) end
  hostAsk(id, sender)
end

local function rememberOffer(key, id, zone)
  local t = GetTime()
  if t - lastOfferAt > OFFER_KEEP then wipe(offersMade) end
  lastOfferAt = t
  local o = offersMade[key] or {}
  o.id, o.t, o.zone = id, t, zone
  offersMade[key] = o
end

local HANDLERS = {}

function HANDLERS.WP(f, ct, key, sender)
  if ct ~= "WHISPER" or not isNum(f[2]) then return end
  see(key, sender, f[5], f[6], f[7])
  if LA.Gate("flh wp", key, WP_GAP) then
    whisper(("WR|%s|%s|%s|%d|%s|%d|%s"):format(f[2], realm, WIRE, myMap(), layerKey(), hostFlag(), tail), sender)
  end
  poke()
end

function HANDLERS.WR(f, ct, key, sender)
  if ct ~= "WHISPER" then return end
  see(key, sender, f[5], f[6], f[7])
  poke()
end

function HANDLERS.HI(f, ct, key, sender)
  see(key, sender, f[2], f[3], f[4])
  if ct == "GUILD" then guildHI() end
  poke()
end

function HANDLERS.GQ(_, ct, key)
  if GROUP_CHATS[ct] and LA.Gate("flh gq", key, GQ_GAP) then send(hiMsg(), ct) end
end

function HANDLERS.CQ(f, ct, key, sender)
  if (ct ~= "WHISPER" and ct ~= "CHANNEL") or not isNum(f[2]) then return end
  see(key, sender, f[3], f[4], f[5])
  if (ct == "WHISPER" or here(f[3])) and LA.Gate("flh cq", key, CQ_GAP) then
    whisper(("CA|%s|%d|%s|%d|%s|%s|%s"):format(f[2], myMap(), layerKey(), hostFlag(), WIRE, realm, tail), sender)
  end
  poke()
end

function HANDLERS.CA(f, ct, key, sender)
  if ct ~= "WHISPER" then return end
  see(key, sender, f[3], f[4], f[5])
  poke()
end

function HANDLERS.DISCOVER(f, ct, key, sender)
  see(key, sender, f[2], f[3])
  if here(f[2]) and LA.Gate("flh discover", key, DISCOVER_GAP) then
    local layer = layerKey()
    whisper(("P|%d|%s|%s|%s|%s"):format(myMap(), layer, WIRE, layer, tail), sender)
  end
  if ct == "GUILD" then guildHI() end
end

function HANDLERS.LQ(f, ct, key, sender)
  if (ct ~= "WHISPER" and ct ~= "CHANNEL") or not isNum(f[2]) then return end
  see(key, sender, f[3], f[5])
  local layer = layerKey()
  if not here(f[3]) or (f[4] ~= "*" and f[4] ~= layer) or f[5] == layer then return end
  local zone = LA.ZoneOf(f[3])
  if not LA.Host.Can(sender, zone) then return end
  rememberOffer(key, f[2], zone)
  whisper(("LO|%s|%d|%s|%d|%d|ACT=0|LANG=%s"):format(f[2], myMap(), layer, GetNumGroupMembers(),
    LA.Host.Recent(LOAD_WINDOW), lang), sender)
end

function HANDLERS.LR(f, _, key, sender)
  local id = f[2]
  if not isNum(id) then return end
  local o = offersMade[key]
  offersMade[key] = nil
  if not o or o.id ~= id or GetTime() - o.t > OFFER_KEEP then return refuse(id, sender, "host unavailable") end
  if not here(f[3]) or f[4] ~= layerKey() then return refuse(id, sender, LAYER_CHANGED) end
  hostAsk(id, sender, o.zone)
end

function HANDLERS.DR(f, ct, key, sender) direct(f, ct, key, sender, DR_GAP) end

function HANDLERS.ZI(f, ct, key, sender) direct(f, ct, key, sender) end

function HANDLERS.LO(f, _, key, sender) onOffer(f, key, sender) end

for _, cmd in ipairs(HOP_REPLIES) do
  HANDLERS[cmd] = function(f, _, key) onHop(cmd, f, key) end
end

local function localeLang()
  local l = GetLocale():sub(1, 2)
  return LANGS[l] and l or "other"
end

local function realmTag()
  local r = (LA.Safe(GetNormalizedRealmName() or GetRealmName()) or ""):gsub("[|:%s]", "")
  return r ~= "" and r or "?"
end

function NET.Init(net)
  book = LA.Book(net.id)
  lang, realm = localeLang(), realmTag()
  tail = ("LANG=%s|POP=0|BUILD=%s"):format(lang, VERSION)
  local guid = LA.Safe(UnitGUID("player"))
  cid = guid and guid:gsub("[|:]", "_")
end

function NET.OnAddon(_, _, text, chatType, sender, key)
  if not text then return end
  local handler = HANDLERS[text:match("^[^|:]+")]
  if handler then handler(split(text), chatType, key, sender) end
end

local function newState(ask)
  cur = { ask = ask, zone = ask.zone, gen = 0, tries = 0, tried = {}, offers = {}, offered = {}, lqTo = {} }
  return cur
end

function NET.Ask(_, ask)
  if not ask.zone then return end
  nextStep(newState(ask))
end

function NET.Target(_, ask, names)
  if not ask.zone then return 0 end
  local st = newState(ask)
  st.only = {}
  for _, name in ipairs(names) do
    local key = LA.NameKey(name)
    if key then st.only[key] = true end
  end
  local n = #pick(st, false)
  nextStep(st)
  return n
end

function NET.StopAsk(_, ask) if cur and cur.ask == ask then cur = nil end end

function NET.OnSwapResult(_, _, result, hostName)
  local key = LA.NameKey(hostName)
  if key and (result == "same" or result == "moved") then avoid[key] = LA.LayerEpoch() end
end

function NET.OnHostFailed(_, ask, why, hostName)
  local key = LA.NameKey(hostName)
  if key and why == "same" then avoid[key] = LA.LayerEpoch() end
  if cur and cur.ask == ask then dropRequest(cur) end
end

LA.RegisterNetwork(NET)

local _, LA = ...

local byte, char, find, format, gsub, lower, match = string.byte, string.char, string.find, string.format, string.gsub, string.lower, string.match
local floor = math.floor

local NET = { id = "autolayer", name = "AutoLayer", offers = false }
local LIST_ROOT = "layer"
local SEG_ROOT = { [947] = "AZ", [1945] = "OL", [2521] = "ZI", [2665] = "ZI", [2524] = "DI" }
local SEG_FIXED = { [1941] = "OL", [1942] = "OL", [1943] = "OL", [1947] = "OL", [1950] = "OL", [1954] = "OL", [1957] = "OL", [908] = "AZ" }
local ZONE_FIXED = { [2521] = 2521, [2524] = 2524, [2665] = 2521 }
local ZONE, MICRO = Enum.UIMapType.Zone, Enum.UIMapType.Micro
local ADLER_MOD, MAP_CLIMB, HEADERS = 65521, 32, 2
local CODE_LETTERS, CODE_BASE, CODE_MAX = 4, 26, 456975
local ALLOW_ANY_FOR, DUPLICATE_FOR = 45, 3
local DAY, HOUR, MINUTE, DAY_SLACK = 86400, 3600, 60, 60

local names, lists, failed, zoneOfRaw = {}, {}, {}, {}
local ready, joined = false, false
local askText, askAt, lastAskAt = {}, {}, -math.huge
local asking

local function adlerHex(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + byte(s, i)) % ADLER_MOD
    b = (b + a) % ADLER_MOD
  end
  return format("%04x%04x", b, a)
end

local function addList(name)
  names[#names + 1] = name
  lists[name] = { seen = "autolayer " .. name, first = "autolayer " .. name .. " first" }
end

local function buildNames()
  names, lists = {}, {}
  local t, realm = C_DateAndTime.GetCurrentCalendarTime(), GetRealmName()
  if t and t.monthDay and realm then
    local d, m, y = t.monthDay, t.month, t.year
    for _, date in ipairs({ format("%02d-%02d-%04d", d, m, y), format("%04d-%02d-%02d", y, m, d), format("%02d-%02d-%04d", m, d, y) }) do
      addList(LIST_ROOT .. adlerHex(realm .. "-" .. date))
    end
  end
  addList(LIST_ROOT)
end

local function segment()
  local id = LA.RawMapID()
  for _ = 1, MAP_CLIMB do
    if not id or id == 0 then return nil end
    local s = SEG_FIXED[id] or SEG_ROOT[id]
    if s then return s end
    local info = C_Map.GetMapInfo(id)
    id = info and info.parentMapID
  end
end

local function climbMicros(id)
  for _ = 1, MAP_CLIMB do
    if ZONE_FIXED[id] then return ZONE_FIXED[id] end
    local info = id and C_Map.GetMapInfo(id)
    if not info or (info.mapType ~= ZONE and info.mapType ~= MICRO) then return nil end
    if info.mapType == ZONE then return id end
    id = info.parentMapID
  end
end

local function alZone()
  local raw = LA.RawMapID()
  if not raw then return nil end
  if zoneOfRaw[raw] == nil then zoneOfRaw[raw] = climbMicros(raw) or false end
  return zoneOfRaw[raw] or nil
end

local function encode(v)
  if not v or v < 1 or v > CODE_MAX then return nil end
  local t = {}
  for i = CODE_LETTERS, 1, -1 do
    t[i] = char(65 + v % CODE_BASE)
    v = floor(v / CODE_BASE)
  end
  return table.concat(t)
end

local function decode(code)
  local v = 0
  for i = 1, CODE_LETTERS do
    local d = byte(code, i) - 97
    if d < 0 or d >= CODE_BASE then return nil end
    v = v * CODE_BASE + d
  end
  if v >= 1 then return v end
end

local function onJoined(name, id) if not id then failed[name] = true end end

local function joinAll()
  if not ready or joined or not (LA.Setting("help") or LA.Setting("askAutoLayer")) then return end
  joined = true
  for _, name in ipairs(names) do
    if not failed[name] then LA.JoinChannel(NET.id, name, nil, onJoined) end
  end
end

local scheduleDay

local function newDay()
  local before = names[1]
  buildNames()
  if ready and names[1] ~= before then
    LA.LeaveChannels(NET.id, lists)
    joined = false
    joinAll()
  end
  scheduleDay()
end

scheduleDay = function()
  local t = C_DateAndTime.GetCurrentCalendarTime()
  if t and t.hour and t.minute then LA.After(DAY - (t.hour * HOUR + t.minute * MINUTE) + DAY_SLACK, newDay) end
end

local function postChannel()
  for _, name in ipairs(names) do
    local id = LA.ChannelId(name)
    if id then return id end
  end
end

local function parse(text)
  local s = lower(gsub(gsub(text, "|c%x%x%x%x%x%x%x%x", ""), "|r", ""))
  s = gsub(s, "^%s+", "")
  if find(s, "^%[nwb%]") or find(s, "^%[autolayer%]") then return nil end
  local zone
  for _ = 1, HEADERS do
    local token, rest = match(s, "^<(%w+)>%s*(.*)$")
    if not token then break end
    local code = match(token, "^alz(%a%a%a%a)$")
    if code then zone = decode(code) end
    s = rest
  end
  if find(s, "%d") then return nil end
  if not find(s, "%f[%w]layer%f[%W]") then return nil end
  return zone, s
end

local function hostAsk(text, sender, needsZone)
  local zone, body = parse(text)
  if not body or (needsZone and not zone) then return end
  if not zone and not LA.LayerAsk(body) then return end
  local here
  if zone then
    here = LA.ZoneMapID()
    if zone ~= here and zone ~= alZone() then return end
  end
  if LA.Host.Can(sender, here, true) then LA.Host.Invite(sender, NET.id) end
end

local function repeated(sender, text)
  local now = GetTime()
  if now - lastAskAt > DUPLICATE_FOR then
    wipe(askText)
    wipe(askAt)
  end
  lastAskAt = now
  if askText[sender] == text and now - askAt[sender] < DUPLICATE_FOR then return true end
  askText[sender], askAt[sender] = text, now
  return false
end

local function ourAskSent()
  if asking and asking.active then asking.AllowAny(ALLOW_ANY_FOR) end
  asking = nil
end

local function onChannel(_, text, sender, _, _, _, _, _, _, base)
  base = LA.Safe(base)
  local list = type(base) == "string" and lists[lower(base)]
  sender = LA.Safe(sender)
  if not list or type(sender) ~= "string" or sender == "" then return end
  if LA.IsMe(sender) then return ourAskSent() end
  text = LA.Safe(text)
  if type(text) ~= "string" or not find(text, "<[Aa][Ll][Zz]%a%a%a%a>") then return end
  LA.Stats.Heard(NET.id, LA.NameKey(sender))
  LA.Count(list.seen)
  if repeated(sender, text) then return end
  LA.Count(list.first)
  hostAsk(text, sender, true)
end

local function onGuild(_, text, sender)
  text, sender = LA.Safe(text), LA.Safe(sender)
  if type(text) ~= "string" or type(sender) ~= "string" or sender == "" then return end
  if find(text, "[Ll][Aa][Yy][Ee][Rr]") then hostAsk(text, sender, false) end
end

local function requestLine()
  local seg = segment()
  if not seg then return "inv layer " end
  local code = encode(alZone() or LA.ZoneMapID())
  return "<" .. seg .. "> " .. (code and ("<ALZ" .. code .. "> ") or "") .. "inv layer "
end

function NET.Init()
  buildNames()
  scheduleDay()
  LA.On("CHAT_MSG_CHANNEL", onChannel)
  LA.On("CHAT_MSG_GUILD", onGuild)
end

function NET.OnChannels()
  ready = true
  LA.LeaveChannels(NET.id, lists)
  joinAll()
end

function NET.Seen()
  local most
  for i = 1, GetNumDisplayChannels() do
    local name, header, _, _, count = GetChannelDisplayInfo(i)
    name, count = LA.Safe(name), tonumber(LA.Safe(count))
    -- count stays unset until the channel's roster is requested (SetSelectedDisplayChannel)
    if not header and type(name) == "string" and lists[lower(name)] and count and count > 0 then
      most = math.max(most or 0, count - 1)
    end
  end
  return most
end

function NET.Ask() joinAll() end

function NET.Fallback()
  if LA.ChatLocked() then return nil end
  if postChannel() then return true end
  joinAll()
end

function NET.Prefill(_, ask, onEnd)
  local id = not LA.ChatLocked() and postChannel()
  if not id then return nil end
  local how = LA.PrefillChat(requestLine(), "CHANNEL", id, onEnd)
  if how then asking = ask end
  return how
end

LA.RegisterNetwork(NET)

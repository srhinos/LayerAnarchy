local _, LA = ...

local Layers = {}
LA.Layers = Layers

local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local GUIDS_KEPT, GUIDS_SLACK, SETTLE_AFTER, SWEEP_AFTER = 300, 60, 12, 3
local FORGET_AFTER, TRUST_FOR, SKIP_FOR, READING_FRESH = 7200, 1200, 75, 60
local MINUTE, HOUR = 60, 3600
local SHOW = {
  nameplateShowAll = "1", nameplateShowEnemies = "1", nameplateShowFriendlyNPCs = "1", nameplateShowFriendlyPlayers = "0",
}
local CROWD_CVAR, CROWD, REVEAL_WAIT, BLINK_AFTER = "nameplateShowFriendlyPlayers", 20, 0.5, 0.5
local UNLOCK_EVENTS = { "PLAYER_REGEN_ENABLED", "ADDON_RESTRICTION_STATE_CHANGED" }
local KINDS = { Creature = true, Vehicle = true }
local GUID_FIELDS = "^(%a+)%-%d+%-(%d+)%-%d+%-(%d+)%-"
local UNIT_EVENTS = {
  UPDATE_MOUSEOVER_UNIT = "mouseover", PLAYER_TARGET_CHANGED = "target", PLAYER_SOFT_ENEMY_CHANGED = "softenemy",
  PLAYER_SOFT_INTERACT_CHANGED = "softinteract", PLAYER_SOFT_FRIEND_CHANGED = "softfriend",
  PLAYER_FOCUS_CHANGED = "focus", PLAYER_INTERACTION_MANAGER_FRAME_SHOW = "npc",
}
local NO_LAYER = "Layer –"
local EMPTY = {}

local realm, here, last, holdUntil, sweepTimer, revealer
local reach, readings, rows = {}, {}, {}

local function readingOf(guid)
  local kind, server, zone = guid:match(GUID_FIELDS)
  if KINDS[kind] then return server .. "-" .. zone end
end

local function span(sec)
  if sec < MINUTE then return math.floor(sec + 0.5) .. "s" end
  if sec < HOUR then return math.floor(sec / MINUTE + 0.5) .. "m" end
  return math.floor(sec / HOUR + 0.5) .. "h"
end

local function labelOf(rec) return "Layer " .. rec.letter .. (rec.provisional and "?" or "") end

local function trusted(e, now) return e ~= nil and not e.stale and now - e.at < TRUST_FOR end

local function older(a, b) return a.born < b.born or (a.born == b.born and a.letter < b.letter) end

local function skipLeft(key, now)
  local at = realm.invited[key]
  return at and math.max(0, at + SKIP_FOR - now) or 0
end

local function hostsOn(rec, now, out)
  local n, wait = 0, nil
  for key, e in pairs(rec.hosts) do
    if trusted(e, now) then
      n = n + 1
      local left = skipLeft(key, now)
      wait = math.min(wait or left, left)
      if out then out[n] = { name = e.name, key = key, net = e.net } end
    end
  end
  return n, wait or 0
end

local function alive(z, rec)
  while rec and rec.into do rec = rec.into end
  if rec and z.store.records[rec.letter] == rec then return rec end
end

local function own(z, guid, rec)
  z.byGuid[guid] = rec
  local reading = readingOf(guid)
  if reading then z.byReading[reading] = rec end
end

local function unown(z, guid, rec)
  if z.byGuid[guid] == rec then z.byGuid[guid] = nil end
  local reading = readingOf(guid)
  if reading and z.byReading[reading] == rec then z.byReading[reading] = nil end
end

local function drop(z, rec)
  for guid in pairs(rec.guids) do unown(z, guid, rec) end
  for key in pairs(rec.hosts) do
    if z.byHost[key] == rec then z.byHost[key] = nil end
  end
  z.store.records[rec.letter] = nil
end

local function forget(z)
  local now = time()
  for _, rec in pairs(z.store.records) do
    if rec ~= z.rec and rec ~= z.expect and now - rec.lastSeenAt > FORGET_AFTER then drop(z, rec) end
  end
end

local function prune(z, rec)
  if rec.size <= GUIDS_KEPT + GUIDS_SLACK then return end
  local list, seqs = {}, rec.guids
  for guid in pairs(seqs) do list[#list + 1] = guid end
  table.sort(list, function(a, b) return seqs[a] > seqs[b] end)
  for i = GUIDS_KEPT + 1, #list do
    unown(z, list[i], rec)
    seqs[list[i]] = nil
  end
  rec.size = GUIDS_KEPT
end

local function index(z, rec)
  for guid in pairs(rec.guids) do own(z, guid, rec) end
  for key, e in pairs(rec.hosts) do
    local other = z.byHost[key]
    if not e.stale and not (other and other.hosts[key].at > e.at) then z.byHost[key] = rec end
  end
end

local function syncStore(z)
  z.store.current, z.store.expect = z.rec and z.rec.letter, z.expect and z.expect.letter
end

local function merge(z, a, b)
  local keep, gone = a, b
  if older(b, a) then keep, gone = b, a end
  for guid, seq in pairs(gone.guids) do
    if not keep.guids[guid] then keep.size = keep.size + 1 end
    keep.guids[guid] = math.max(keep.guids[guid] or 0, seq)
    own(z, guid, keep)
  end
  for key, e in pairs(gone.hosts) do
    local mine = keep.hosts[key]
    if not mine or mine.at < e.at then keep.hosts[key] = e end
    local at = z.byHost[key]
    if at == gone or at == keep then z.byHost[key] = not keep.hosts[key].stale and keep or nil end
  end
  keep.provisional = keep.provisional and gone.provisional and keep.size < SETTLE_AFTER
  keep.lastSeenAt = math.max(keep.lastSeenAt, gone.lastSeenAt)
  keep.leftAt = keep.leftAt and gone.leftAt and math.max(keep.leftAt, gone.leftAt)
  z.store.records[gone.letter] = nil
  gone.into = keep
  if z.rec == gone then z.rec = keep end
  if z.expect == gone then z.expect = keep end
  if z.expect == z.rec then z.expect = nil end
  syncStore(z)
  prune(z, keep)
  return keep, gone
end

local function notify(letter, from)
  local text = from and ("Layer " .. from .. " was " .. letter) or ("Landed on Layer " .. letter)
  LA.Log("layer", text)
  LA.Flash(text, nil, nil, from and "idle")
end

local function leave(z, live)
  local rec = z.rec
  if not rec then return nil end
  -- an unconfirmed landing keeps the host evidence it arrived with
  if z.expect then rec = merge(z, rec, z.expect) end
  if live then rec.lastSeenAt = time() end
  rec.leftAt = rec.lastSeenAt
  z.rec, z.expect, z.store.back = nil, nil, nil
  syncStore(z)
  if rec.size == 0 and next(rec.hosts) == nil then
    drop(z, rec)
    return nil
  end
  return rec
end

local function arrive(z, rec, back)
  local now = time()
  z.rec, z.expect = rec, nil
  z.store.back = back or (rec.leftAt and now - rec.leftAt)
  rec.leftAt, rec.lastSeenAt = nil, now
  syncStore(z)
  LA.Refresh()
end

local function newRecord(z)
  forget(z)
  local records, letter = z.store.records, nil
  for i = 1, #LETTERS do
    letter = LETTERS:sub(i, i)
    if not records[letter] then break end
    letter = nil
  end
  if not letter then
    local oldest
    for _, rec in pairs(records) do
      if not oldest or rec.lastSeenAt < oldest.lastSeenAt then oldest = rec end
    end
    drop(z, oldest)
    letter = oldest.letter
  end
  local now = time()
  local rec = { letter = letter, provisional = true, born = now, lastSeenAt = now, size = 0, guids = {}, hosts = {} }
  records[letter] = rec
  return rec
end

local function expect(z, rec, quiet)
  local expected = z.expect
  z.expect, z.store.back = rec, rec.leftAt and time() - rec.leftAt
  syncStore(z)
  if quiet then return LA.Refresh() end
  if expected then return notify(rec.letter) end
  notify(rec.letter, z.rec.letter)
end

local function sameAs(z, rec, byHost, quiet)
  local cur, wanted = z.rec, z.expect
  if rec == cur or (byHost and rec == wanted) then return end
  if byHost and cur.provisional then return expect(z, rec, quiet) end
  local back = rec.leftAt and time() - rec.leftAt
  local keep, gone = merge(z, cur, rec)
  arrive(z, keep, back)
  if quiet or rec == wanted then return end
  if wanted then return notify(keep.letter) end
  notify(keep.letter, gone.letter)
end

local function sameRecords(z, a, b, quiet)
  if a == z.rec then return sameAs(z, b, true, quiet) end
  if b == z.rec then return sameAs(z, a, true, quiet) end
  local keep, gone = merge(z, a, b)
  if not quiet then notify(keep.letter, gone.letter) end
end

local function freshReading(key)
  local r = readings[key]
  if r and GetTime() - r.at < READING_FRESH then return r.value end
end

local function confirm(z, rec, name, key, quiet)
  local now, reading = time(), freshReading(key)
  local other = z.byHost[key]
  local e = other ~= rec and other and other.hosts[key]
  local proof = e and trusted(e, now) and reading ~= nil and e.reading == reading
  if e then e.stale = true end
  rec.hosts[key] = { name = name, reading = reading, at = now, net = reach[key] }
  z.byHost[key] = rec
  if proof then sameRecords(z, rec, other, quiet) end
  LA.Refresh()
end

local function add(z, rec, guid, reading)
  local store = z.store
  store.seq = store.seq + 1
  rec.guids[guid], rec.size, rec.lastSeenAt = store.seq, rec.size + 1, time()
  z.byGuid[guid], z.byReading[reading] = rec, rec
  prune(z, rec)
  if not rec.provisional or rec.size < SETTLE_AFTER then return end
  if z.expect then return sameAs(z, z.expect) end
  rec.provisional = false
  LA.Refresh()
end

local function see(unit)
  local z = here
  if not (z and z.rec) then return end
  if holdUntil then
    if GetTime() < holdUntil then return end
    holdUntil = nil
  end
  local guid = unit and LA.Safe(UnitGUID(unit))
  if not guid then return end
  local owner = z.byGuid[guid]
  if owner == z.rec then return end
  if owner then return sameAs(z, owner) end
  local reading = readingOf(guid)
  if reading then add(z, z.rec, guid, reading) end
end

local function unsettled()
  local z = here
  return z ~= nil and z.rec ~= nil and z.rec.provisional
end

local function seePlates()
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or EMPTY) do see(plate.namePlateUnitToken) end
end

local function setCVar(name, value)
  local ok, done = pcall(C_CVar.SetCVar, name, value)
  return ok and done
end

local function restorePlates()
  local back = LA.db.platesBack
  if not back then return end
  for name, was in pairs(back) do
    if C_CVar.GetCVar(name) ~= SHOW[name] or setCVar(name, was) then back[name] = nil end
  end
  if not next(back) then LA.db.platesBack = nil end
end

local function waitPlates(frame, elapsed)
  frame.left = frame.left - elapsed
  if frame.left > 0 and unsettled() and not frame.shown then return end
  frame:Hide()
  LA.Try("layers", seePlates)
  restorePlates()
end

-- in a town the players' plates can fill the game's 40 before any creature's shows
local function crowded()
  local n = 0
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or EMPTY) do
    local unit = plate.namePlateUnitToken
    local guid = unit and LA.Safe(UnitGUID(unit))
    if guid and guid:find("^Player%-") then n = n + 1 end
  end
  return n >= CROWD
end

local function reveal()
  local back, crowd = {}, crowded()
  LA.db.platesBack, revealer.shown = back, false
  for name, want in pairs(SHOW) do
    local was = C_CVar.GetCVar(name)
    if was and was ~= want and (name ~= CROWD_CVAR or crowd) and setCVar(name, want) then back[name] = was end
  end
  if not next(back) then
    LA.db.platesBack = nil
    return false
  end
  revealer.left = REVEAL_WAIT
  revealer:Show()
  return true
end

local function sweep()
  sweepTimer = nil
  if unsettled() and reveal() then return end
  seePlates()
end


local function sweepSoon(after)
  if sweepTimer then sweepTimer:Cancel() end
  sweepTimer = LA.After(after or SWEEP_AFTER, sweep)
end

local function load(id, adopt)
  local store = realm.zones[id] or { records = {} }
  realm.zones[id], store.seq = store, store.seq or 0
  local z = { id = id, store = store, byGuid = {}, byReading = {}, byHost = {} }
  forget(z)
  for _, rec in pairs(store.records) do index(z, rec) end
  z.rec, z.expect = store.records[store.current], store.records[store.expect]
  if not adopt then leave(z, false) end
  return z
end

local function focus(id, fresh)
  local z = here
  if z and z.id ~= id then
    leave(z, true)
    z = nil
  end
  here = id and (z or load(id, not fresh)) or nil
  if not here then return LA.Refresh() end
  if fresh or not here.rec then
    leave(here, true)
    arrive(here, newRecord(here))
  end
  sweepSoon()
end

local function zoneNow()
  if IsInInstance() then return nil end
  return LA.ZoneMapID()
end

local function onEnteringWorld(_, _, isReloadingUi) focus(zoneNow(), not LA.Safe(isReloadingUi)) end

local function onZoneChanged()
  local id = zoneNow()
  if not (here and here.id == id) then focus(id, true) end
end

local function forgetInvites(invited, now)
  for key, at in pairs(invited) do
    if now - at >= SKIP_FOR then invited[key] = nil end
  end
end

local function forgetStores(now)
  for _, r in pairs(LA.db.layers) do
    for id, store in pairs(r.zones) do
      for letter, rec in pairs(store.records) do
        if now - rec.lastSeenAt > FORGET_AFTER then store.records[letter] = nil end
      end
      if not next(store.records) then r.zones[id] = nil end
    end
    forgetInvites(r.invited, now)
  end
end

function Layers.Hold(seconds)
  holdUntil = GetTime() + seconds
  sweepSoon(seconds)
end

function Layers.Moved(epochBefore)
  holdUntil = nil
  local z = here
  if not z then return end
  last = { epoch = epochBefore, rec = leave(z, true) }
  arrive(z, newRecord(z))
  sweepSoon(BLINK_AFTER)
end

function Layers.MovedBack(epoch)
  holdUntil = nil
  local z = here
  if not z then return end
  leave(z, true)
  local back = last and last.epoch == epoch and alive(z, last.rec)
  arrive(z, back or newRecord(z))
  sweepSoon(BLINK_AFTER)
end

function Layers.Landed(name, target)
  local z = here
  if not (z and z.rec) then return end
  target = alive(z, target)
  if target and target ~= z.rec then expect(z, target, true) end
  local key = LA.NameKey(name)
  if key then confirm(z, z.rec, name, key, true) end
end

function Layers.Reach(key, netId) reach[key] = netId end

function Layers.Reading(name, reading, zone)
  local key = LA.NameKey(name)
  if not (key and reading) then return end
  readings[key] = { value = reading, at = GetTime() }
  local z = here
  if not z then return end
  local rec = z.byHost[key]
  local e = rec and rec.hosts[key]
  if e and e.reading and e.reading ~= reading then
    e.stale, z.byHost[key] = true, nil
    LA.Refresh()
  end
  local match = zone == z.id and z.byReading[reading]
  if match then confirm(z, match, name, key) end
end

function Layers.Invited(name, sameLayer)
  local key = LA.NameKey(name)
  if not key then return end
  local now = time()
  forgetInvites(realm.invited, now)
  realm.invited[key] = now
  local z = here
  if sameLayer and z and z.rec then confirm(z, z.rec, name, key) end
end

function Layers.SkipLeft(key) return skipLeft(key, time()) end

function Layers.Hosts(rec)
  rec = here and alive(here, rec)
  if not rec then return EMPTY end
  local out = {}
  hostsOn(rec, time(), out)
  return out, rec.letter
end

function Layers.Trusted(rec, key)
  rec = here and alive(here, rec)
  return rec ~= nil and trusted(rec.hosts[key], time())
end

function Layers.Label()
  local z = here
  local rec = z and (z.expect or z.rec)
  if not rec then return NO_LAYER end
  local back = z.store.back
  return labelOf(rec), back and ("· back after " .. span(back)) or nil
end

local function byRecency(a, b)
  if a.here ~= b.here then return a.here end
  return a.rec.leftAt > b.rec.leftAt
end

function Layers.List()
  local z, n = here, 0
  if z and z.rec then
    forget(z)
    local now, shown, swapping = time(), z.expect or z.rec, LA.Swap.Busy()
    local busy = alive(z, LA.Swap.Target())
    for _, rec in pairs(z.store.records) do
      if rec ~= z.rec or rec == shown then
        n = n + 1
        local row = rows[n] or {}
        rows[n] = row
        local hosts, wait = hostsOn(rec, now)
        row.rec, row.here, row.busy, row.name = rec, rec == shown, rec == busy, labelOf(rec)
        row.when = row.here and "now" or (span(now - rec.leftAt) .. " ago")
        row.enabled = not row.here and hosts > 0 and not swapping
        row.state, row.ready = nil, nil
        if row.here then
          row.hosts = "you are here"
        elseif hosts == 0 then
          row.hosts = "no hosts known"
        else
          row.hosts = hosts .. (hosts == 1 and " host · " or " hosts · ")
          row.state, row.ready = wait > 0 and LA.Clock(wait) or "ready", wait <= 0
        end
      end
    end
  end
  for i = #rows, n + 1, -1 do rows[i] = nil end
  table.sort(rows, byRecency)
  return rows
end

local function printLayers()
  local z = here
  if not z then return LA.Print("layers: no open-world zone") end
  LA.Print(("layers: zone %d, %s%s"):format(z.id, Layers.Label(), z.expect and (" (on " .. z.rec.letter .. ")") or ""))
  local now = time()
  for i = 1, #LETTERS do
    local rec = z.store.records[LETTERS:sub(i, i)]
    if rec then
      local all, n = 0, hostsOn(rec, now)
      for _ in pairs(rec.hosts) do all = all + 1 end
      print(("  %s creatures %d, hosts %d/%d, %s"):format(labelOf(rec), rec.size, n, all,
        rec.leftAt and ("left " .. span(now - rec.leftAt) .. " ago") or "current"))
    end
  end
end

function Layers.Init()
  local db = LA.db
  db.layers = db.layers or {}
  local name = LA.Safe(GetRealmName()) or "?"
  realm = db.layers[name] or { zones = {}, invited = {} }
  db.layers[name] = realm
  forgetStores(time())
  restorePlates()
  revealer = CreateFrame("Frame")
  revealer:Hide()
  revealer:SetScript("OnUpdate", LA.Guard("layers", waitPlates))
  for _, event in ipairs(UNLOCK_EVENTS) do LA.On(event, restorePlates) end
  LA.On("PLAYER_ENTERING_WORLD", onEnteringWorld)
  LA.On("ZONE_CHANGED_NEW_AREA", onZoneChanged)
  LA.On("NAME_PLATE_UNIT_ADDED", function(_, unit)
    revealer.shown = true
    see(LA.Safe(unit))
  end)
  for event, unit in pairs(UNIT_EVENTS) do LA.On(event, function() see(unit) end) end
  LA.Command("diag layers", printLayers)
end

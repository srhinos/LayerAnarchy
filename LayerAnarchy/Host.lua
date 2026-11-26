local _, LA = ...

local Host = { guests = {}, sent = {} }
LA.Host = Host

local RECENT, INVITE_WAIT, SAME_WAIT, MOVE_WAIT, RELEASE_AFTER, BACKOFF, LINES_FOR = 60, 60, 10, 60, 30, 300, 150
local LIMIT_WINDOW, GROUP_MAX = 3600, 5
local TAXI_RECHECKS = { 1, 3 }
local SHARDING = Enum.PhaseReason.Sharding
local NO_SHOW = { ERR_DECLINE_GROUP_S = true, ERR_ALREADY_IN_GROUP_S = true, ERR_BAD_PLAYER_NAME_S = true }

local wakeTimer, wakeDue, releaseRequestedAt
local playerInvites = {}
local dropped, droppedAt = {}, -math.huge

function Host.Recent(sec)
  local sent, now, n = Host.sent, time(), 0
  for i = #sent, 1, -1 do
    if now - sent[i] >= sec then break end
    n = n + 1
  end
  return n
end

local function pruneSent(now)
  local sent, kept = Host.sent, 0
  for i = 1, #sent do
    if now - sent[i] < LIMIT_WINDOW then
      kept = kept + 1
      sent[kept] = sent[i]
    end
  end
  for i = #sent, kept + 1, -1 do sent[i] = nil end
end

local function limitReached()
  local limit = LA.Setting("invitesPerHour")
  return limit > 0 and Host.Recent(LIMIT_WINDOW) >= limit
end

local function limitLiftsAt()
  local at = Host.sent[#Host.sent - LA.Setting("invitesPerHour") + 1]
  return at and at + LIMIT_WINDOW
end

local function playerInvitesUntil()
  local now, last = time(), nil
  for key, at in pairs(playerInvites) do
    if now - at < INVITE_WAIT then last = math.max(last or 0, at + INVITE_WAIT) else playerInvites[key] = nil end
  end
  return last
end

local function groupIsOurs()
  local invitedUntil = playerInvitesUntil()
  if invitedUntil then return false, invitedUntil end
  if not IsInGroup() then return true end
  if IsInRaid() or not UnitIsGroupLeader("player") then return false end
  for key in pairs(LA.Party()) do
    if not Host.guests[key] then return false end
  end
  return true
end

local function lastMove()
  local last
  for key, g in pairs(Host.guests) do
    if LA.UnitFor(key) then
      if not g.movedAt then return nil end
      last = math.max(last or 0, g.movedAt)
    end
  end
  return last
end

local function invitesOut()
  for _, g in pairs(Host.guests) do
    if not g.joinedAt then return true end
  end
  return false
end

local function releasable()
  if not groupIsOurs() or IsInInstance() or invitesOut() then return nil end
  return lastMove()
end

local function blocked()
  if LA.disabled or not LA.Setting("help") then return "off" end
  if IsInInstance() then return "instance" end
  if UnitOnTaxi("player") and not LA.Setting("hostWhileFlying") then return "flying" end
  if LA.Swap.Busy() then return "swapping" end
  local ours, liftsAt = groupIsOurs()
  if not ours then return "in group", liftsAt end
  if limitReached() then return "invite limit", limitLiftsAt() end
end

local function groupFull() return IsInGroup() and GetNumGroupMembers() >= GROUP_MAX end

local function blindKind() return "blind " .. LA.LayerEpoch() end

local function check(asker, askerZone, blind)
  local why = blocked()
  if why then return false, why end
  if asker == nil then return true end
  local key = LA.NameKey(asker)
  if not key or key == LA.MyKey() then return false, "self" end
  local zone = LA.ZoneMapID()
  if askerZone and zone and askerZone ~= zone then return false, "zone" end
  if not LA.Gate("invite", key, RECENT, true) or (blind and not LA.Gate(blindKind(), key, BACKOFF, true)) then
    return false, "recent"
  end
  if groupFull() and not lastMove() then return false, "full" end
  return true
end

function Host.Can(asker, askerZone, blind)
  local ok, why = check(asker, askerZone, blind)
  LA.Stats.Asked(asker, why)
  return ok, why
end

local function woke()
  wakeTimer, wakeDue = nil, nil
  Host.Check()
end

local function wakeAt(at)
  if at == wakeDue then return end
  if wakeTimer then wakeTimer:Cancel() end
  wakeDue = at
  wakeTimer = at and LA.After(math.max(0, at - time()), woke)
end

local function notify(g, method) LA.Call(LA.Net(g.net), method, g.name) end

local function tallyKey(g, event) return (g.flying and "fly." or "host.") .. event end

local function settle(key, outcome)
  local tally = tallyKey(Host.guests[key], outcome)
  LA.Tally(tally)
  LA.Stats.Note(tally)
  LA.Gate(blindKind(), key, 0)
end

local function drop(key, outcome)
  if outcome then settle(key, outcome) end
  Host.guests[key] = nil
  local now = time()
  if now - droppedAt >= LINES_FOR then wipe(dropped) end
  dropped[key], droppedAt = now, now
end

function Host.Owns(key)
  local now = time()
  if not key then return next(Host.guests) ~= nil or now - droppedAt < LINES_FOR end
  local at = dropped[key]
  return Host.guests[key] ~= nil or (at ~= nil and now - at < LINES_FOR)
end

local function track(key, g, now)
  local unit = LA.UnitFor(key)
  if not unit then
    if not g.joinedAt and now - g.invitedAt < INVITE_WAIT then return g.invitedAt + INVITE_WAIT end
    drop(key, not g.joinedAt and "noshow" or nil)
    return nil
  end
  if not g.joinedAt then
    g.joinedAt = now
    notify(g, "OnGuestJoined")
  end
  if g.movedAt then return nil end
  local phase = LA.PhaseOf(unit)
  g.apart = g.apart or phase == SHARDING
  if not g.apart then
    if now - g.joinedAt < SAME_WAIT then return g.joinedAt + SAME_WAIT end
    drop(key, "same")
  elseif phase == nil then
    g.movedAt = now
    settle(key, "moved")
    notify(g, "OnGuestMoved")
  elseif now - g.joinedAt >= MOVE_WAIT then
    g.movedAt = now
    settle(key, "stuck")
  else
    return g.joinedAt + MOVE_WAIT
  end
end

local function earliest(a, b) return (a and b) and math.min(a, b) or a or b end

function Host.Check()
  local now, due = time(), nil
  for key, g in pairs(Host.guests) do due = earliest(due, track(key, g, now)) end
  local last, released = releasable(), false
  if last then
    local releaseAt = releaseRequestedAt or last + RELEASE_AFTER
    released = now >= releaseAt
    if released then LA.LeaveGroup("released") else due = earliest(due, releaseAt) end
  end
  releaseRequestedAt = nil
  wakeAt(due)
  LA.Refresh()
  return released
end

function Host.Release()
  releaseRequestedAt = time()
  return Host.Check()
end

function Host.Invite(name, netId)
  local ok, why = check(name)
  if not ok then
    LA.Log("host-skip", netId, name, why)
    return false
  end
  if groupFull() then
    LA.LeaveGroup("full")
    wipe(Host.guests)
  end
  local now, key = time(), LA.NameKey(name)
  local g = { name = name, net = netId, invitedAt = now, flying = UnitOnTaxi("player") }
  Host.guests[key] = g
  LA.ExpectGroupLines()
  local sent, err = pcall(C_PartyInfo.InviteUnit, name)
  if not sent then
    Host.guests[key] = nil
    LA.Log("error", "invite", name, err)
    return false
  end
  LA.Gate("invite", key, 0)
  pruneSent(now)
  Host.sent[#Host.sent + 1] = now
  LA.Stats.Note(tallyKey(g, "invited"))
  LA.Log("invite", netId, name)
  Host.Check()
  return true
end

function Host.View(v)
  local why, liftsAt = blocked()
  if why == "off" then
    v.status, v.tone = "Host off", "off"
    return
  end
  for _, g in pairs(Host.guests) do
    if not g.movedAt then
      v.status, v.tone, v.border = "Inviting " .. g.name, "host", "host"
      return
    end
  end
  if liftsAt then LA.WakeIn(liftsAt - time()) end
  if why then
    v.status, v.tone = "Paused (" .. why .. ")", "warn"
  else
    v.status = "Hosting"
  end
end

local function onRoster() if next(Host.guests) then Host.Check() else LA.Refresh() end end

local function onUnitPhase() if next(Host.guests) then Host.Check() end end

local function onGroupLeft()
  for key, g in pairs(Host.guests) do
    if g.joinedAt then drop(key) end
  end
  Host.Check()
end

local function onSystem(_, text)
  if not (next(playerInvites) or invitesOut()) then return end
  local kind, key = LA.GroupLine(LA.Safe(text))
  if not NO_SHOW[kind] then return end
  local g = Host.guests[key]
  if g and not g.joinedAt then
    drop(key, "noshow")
  elseif not playerInvites[key] then
    return
  end
  playerInvites[key] = nil
  Host.Check()
end

local function onInviteUnit(name)
  local key = LA.NameKey(name)
  if not key or Host.guests[key] then return end
  local opens = playerInvitesUntil() == nil
  playerInvites[key] = time()
  if opens then Host.Check() end
end

local function onControlGained()
  LA.Refresh()
  -- the taxi flag clears a moment after control returns
  for _, sec in ipairs(TAXI_RECHECKS) do LA.After(sec, LA.Refresh) end
end

local function restore()
  local saved = LA.char.host or {}
  LA.char.host = saved
  saved.guests, saved.sent = saved.guests or {}, saved.sent or {}
  Host.guests, Host.sent = saved.guests, saved.sent
  local now = time()
  for key, g in pairs(Host.guests) do
    if not g.joinedAt and now - g.invitedAt >= INVITE_WAIT then Host.guests[key] = nil end
  end
  pruneSent(now)
end

function Host.Init()
  restore()
  hooksecurefunc(C_PartyInfo, "InviteUnit", onInviteUnit)
  LA.On("PLAYER_ENTERING_WORLD", onRoster)
  LA.On("GROUP_ROSTER_UPDATE", onRoster)
  LA.On("UNIT_PHASE", onUnitPhase)
  LA.On("GROUP_LEFT", onGroupLeft)
  LA.On("CHAT_MSG_SYSTEM", onSystem)
  LA.On("PLAYER_CONTROL_LOST", LA.Refresh)
  LA.On("PLAYER_CONTROL_GAINED", onControlGained)
end

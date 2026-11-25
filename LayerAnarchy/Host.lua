local _, LA = ...

local Host = { guests = {}, sent = {} }
LA.Host = Host

local RECENT, INVITE_WAIT, SAME_WAIT, MOVE_WAIT, RELEASE_AFTER, BACKOFF = 60, 60, 10, 60, 30, 300
local LIMIT_WINDOW, GROUP_MAX = 3600, 5
local TAXI_RECHECKS = { 1, 3 }
local SHARDING = Enum.PhaseReason.Sharding
local NO_SHOW = { ERR_DECLINE_GROUP_S = true, ERR_ALREADY_IN_GROUP_S = true, ERR_BAD_PLAYER_NAME_S = true }

local wakeTimer
local tried = {}
local inviting, ownInviteAt = false, -math.huge

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

local function inviteLimit() return tonumber(LA.Setting("invitesPerHour")) or 0 end

local function limitReached()
  local limit = inviteLimit()
  return limit > 0 and Host.Recent(LIMIT_WINDOW) >= limit
end

local function limitLiftsIn()
  local at = Host.sent[#Host.sent - inviteLimit() + 1]
  return at and at + LIMIT_WINDOW - time()
end

local function ownInviteOut() return time() - ownInviteAt < INVITE_WAIT end

local function groupIsOurs()
  if ownInviteOut() then return false end
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

local function blocked()
  if LA.disabled or not LA.Setting("help") then return "off" end
  if LA.InInstance() then return "instance" end
  if UnitOnTaxi("player") and not LA.Setting("hostWhileFlying") then return "flying" end
  if LA.Swap.Busy() then return "swapping" end
  if not groupIsOurs() then return "in group" end
  if limitReached() then return "invite limit" end
end

local function groupFull() return IsInGroup() and GetNumGroupMembers() >= GROUP_MAX end

local function triedRecently(key)
  local t = tried[key]
  return t ~= nil and t.epoch == LA.LayerEpoch() and time() - t.at < BACKOFF
end

local function check(asker, askerZone, blind)
  local why = blocked()
  if why then return false, why end
  if asker == nil then return true end
  local key = LA.NameKey(asker)
  if not key or key == LA.MyKey() then return false, "self" end
  local zone = LA.ZoneMapID()
  if askerZone and zone and tonumber(askerZone) ~= zone then return false, "zone" end
  if not LA.Gate("invite", key, RECENT, true) or (blind and triedRecently(key)) then return false, "recent" end
  if groupFull() and not lastMove() then return false, "full" end
  return true
end

function Host.Can(asker, askerZone, blind)
  local ok, why = check(asker, askerZone, blind)
  LA.Stats.Asked(asker, why)
  return ok, why
end

local function wakeAt(at)
  if wakeTimer then wakeTimer:Cancel() end
  wakeTimer = at and LA.After(math.max(0, at - time()), Host.Check)
end

local function notify(g, method) LA.Call(LA.Net(g.net), method, g.name) end

local function tallyKey(g, event) return (g.flying and "fly." or "host.") .. event end

local function settle(g, outcome)
  local key = tallyKey(g, outcome)
  LA.Tally(key)
  LA.Stats.Note(key)
  local now = time()
  for k, t in pairs(tried) do
    if now - t.at >= BACKOFF then tried[k] = nil end
  end
  tried[g.key] = { at = now, epoch = LA.LayerEpoch() }
end

local function track(key, g, now)
  local unit = LA.UnitFor(key)
  if not unit then
    if not g.joinedAt and now - g.invitedAt < INVITE_WAIT then return g.invitedAt + INVITE_WAIT end
    if not g.joinedAt then settle(g, "noshow") end
    Host.guests[key] = nil
    return nil
  end
  if not g.joinedAt then
    g.joinedAt = now
    LA.Quiet(g.name)
    notify(g, "OnGuestJoined")
  end
  if g.movedAt then return nil end
  local phase = LA.PhaseOf(unit)
  g.apart = g.apart or phase == SHARDING
  if not g.apart then
    if now - g.joinedAt < SAME_WAIT then return g.joinedAt + SAME_WAIT end
    settle(g, "same")
    Host.guests[key] = nil
  elseif phase == nil then
    g.movedAt = now
    settle(g, "moved")
    notify(g, "OnGuestMoved")
  elseif now - g.joinedAt >= MOVE_WAIT then
    g.movedAt = now
    settle(g, "stuck")
  else
    return g.joinedAt + MOVE_WAIT
  end
end

local function earliest(a, b) return (a and b) and math.min(a, b) or a or b end

function Host.Check()
  local now, due = time(), nil
  for key, g in pairs(Host.guests) do due = earliest(due, track(key, g, now)) end
  if ownInviteOut() then due = earliest(due, ownInviteAt + INVITE_WAIT) end
  local last = lastMove()
  if last and groupIsOurs() and not invitesOut() and not LA.InInstance() then
    local releaseAt = last + (LA.Swap.Busy() and 0 or RELEASE_AFTER)
    if now >= releaseAt then LA.LeaveGroup("released") else due = earliest(due, releaseAt) end
  end
  wakeAt(due)
  LA.Refresh()
end

function Host.Release()
  if not groupIsOurs() or LA.InInstance() then return false end
  for key, g in pairs(Host.guests) do
    if LA.UnitFor(key) and not g.movedAt then return false end
  end
  LA.LeaveGroup("released")
  return true
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
  LA.Quiet(name)
  inviting = true
  local sent, err = pcall(C_PartyInfo.InviteUnit, name)
  inviting = false
  if not sent then
    LA.Log("error", "invite", name, err)
    return false
  end
  local now, key = time(), LA.NameKey(name)
  LA.Gate("invite", key, 0)
  pruneSent(now)
  Host.sent[#Host.sent + 1] = now
  local g = { key = key, name = name, net = netId, invitedAt = now, flying = UnitOnTaxi("player") }
  Host.guests[key] = g
  LA.Stats.Note(tallyKey(g, "invited"))
  LA.Log("invite", netId, name)
  Host.Check()
  return true
end

function Host.View(v)
  local why = blocked()
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
  if why == "invite limit" then
    local lifts = limitLiftsIn()
    if lifts then LA.WakeIn(math.max(1, lifts)) end
  end
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
    if g.joinedAt then
      LA.Quiet(g.name)
      Host.guests[key] = nil
    end
  end
  Host.Check()
end

local function onSystem(_, text)
  local kind, key = LA.GroupLine(LA.Safe(text))
  local g = NO_SHOW[kind] and Host.guests[key]
  if not g or g.joinedAt then return end
  settle(g, "noshow")
  Host.guests[key] = nil
  Host.Check()
end

local function onOwnInvite()
  if inviting then return end
  ownInviteAt = time()
  Host.Check()
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
    if type(g) ~= "table" or not g.invitedAt or (not g.joinedAt and now - g.invitedAt >= INVITE_WAIT) then
      Host.guests[key] = nil
    else
      g.key = key
    end
  end
  pruneSent(now)
end

function Host.Init()
  restore()
  hooksecurefunc(C_PartyInfo, "InviteUnit", onOwnInvite)
  LA.On("PLAYER_ENTERING_WORLD", onRoster)
  LA.On("GROUP_ROSTER_UPDATE", onRoster)
  LA.On("UNIT_PHASE", onUnitPhase)
  LA.On("GROUP_LEFT", onGroupLeft)
  LA.On("CHAT_MSG_SYSTEM", onSystem)
  LA.On("PLAYER_CONTROL_LOST", LA.Refresh)
  LA.On("PLAYER_CONTROL_GAINED", onControlGained)
end

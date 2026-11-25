local _, LA = ...

local Host = { guests = {}, sent = {} }
LA.Host = Host

local RECENT, INVITE_WAIT, MOVE_WAIT, RELEASE_AFTER = 60, 60, 60, 30
local LIMIT_WINDOW, GROUP_MAX = 3600, 5
local TAXI_RECHECKS = { 1, 3 }

local wakeTimer

function Host.Recent(sec)
  local sent, now, n = Host.sent, GetTime(), 0
  for i = #sent, 1, -1 do
    if now - sent[i] >= sec then break end
    n = n + 1
  end
  return n
end

local function recordInvite(now)
  local sent, kept = Host.sent, 0
  for i = 1, #sent do
    if now - sent[i] < LIMIT_WINDOW then
      kept = kept + 1
      sent[kept] = sent[i]
    end
  end
  for i = #sent, kept + 1, -1 do sent[i] = nil end
  sent[kept + 1] = now
end

local function limitReached()
  local limit = tonumber(LA.Setting("invitesPerHour")) or 0
  return limit > 0 and Host.Recent(LIMIT_WINDOW) >= limit
end

local function groupIsOurs()
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

local function blocked()
  if LA.disabled or not LA.Setting("help") then return "off" end
  if LA.InInstance() then return "instance" end
  if UnitOnTaxi("player") and not LA.Setting("hostWhileFlying") then return "flying" end
  if LA.Swap.Busy() then return "swapping" end
  if not groupIsOurs() then return "in group" end
  if limitReached() then return "invite limit" end
end

local function groupFull() return IsInGroup() and GetNumGroupMembers() >= GROUP_MAX end

local function check(asker, askerZone)
  local why = blocked()
  if why then return false, why end
  if asker == nil then return true end
  local key = LA.NameKey(asker)
  if not key or key == LA.MyKey() then return false, "self" end
  local zone = LA.ZoneMapID()
  if askerZone and zone and tonumber(askerZone) ~= zone then return false, "zone" end
  if not LA.Gate("invite", key, RECENT, true) then return false, "recent" end
  if groupFull() and not lastMove() then return false, "full" end
  return true
end

function Host.Can(asker, askerZone)
  local ok, why = check(asker, askerZone)
  LA.Stats.Asked(asker, why)
  return ok, why
end

local function wakeAt(at)
  if wakeTimer then wakeTimer:Cancel() end
  wakeTimer = at and LA.After(math.max(0, at - GetTime()), Host.Check)
end

local function notify(g, method) LA.Call(LA.Net(g.net), method, g.name) end

local function tallyKey(g, event) return (g.flying and "fly." or "host.") .. event end

local function settle(g, outcome)
  local key = tallyKey(g, outcome)
  LA.Tally(key)
  LA.Stats.Note(key)
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
    notify(g, "OnGuestJoined")
  end
  if g.movedAt then return nil end
  if LA.PhaseOf(unit) == nil then
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

function Host.Check()
  local now, due = GetTime(), nil
  for key, g in pairs(Host.guests) do
    local at = track(key, g, now)
    if at and (not due or at < due) then due = at end
  end
  local last = lastMove()
  if last and groupIsOurs() then
    if now - last >= RELEASE_AFTER then
      LA.LeaveGroup("released")
    else
      due = math.min(due or math.huge, last + RELEASE_AFTER)
    end
  end
  wakeAt(due)
  LA.Refresh()
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
  local sent, err = pcall(C_PartyInfo.InviteUnit, name)
  if not sent then
    LA.Log("error", "invite", name, err)
    return false
  end
  local now, key = GetTime(), LA.NameKey(name)
  LA.Gate("invite", key, 0)
  recordInvite(now)
  local g = { name = name, net = netId, invitedAt = now, flying = UnitOnTaxi("player") }
  Host.guests[key] = g
  LA.Stats.Note(tallyKey(g, "invited"))
  LA.Log("invite", netId, name)
  Host.Check()
  return true
end

function Host.Pending()
  for _, g in pairs(Host.guests) do
    if not g.movedAt then return true end
  end
  return false
end

function Host.View(v)
  for _, g in pairs(Host.guests) do
    if not g.movedAt then
      v.status, v.tone, v.border = "Inviting " .. g.name, "host", "host"
      return
    end
  end
  local why = blocked()
  if why == "off" then
    v.status, v.tone = "Host off", "off"
  elseif why then
    v.status, v.tone = "Paused (" .. why .. ")", "warn"
  else
    v.status = "Hosting"
  end
end

local function onRoster() if next(Host.guests) then Host.Check() else LA.Refresh() end end

local function onUnitPhase() if next(Host.guests) then Host.Check() end end

local function onGroupLeft()
  for key, g in pairs(Host.guests) do
    if g.joinedAt then Host.guests[key] = nil end
  end
  Host.Check()
end

local function onControlGained()
  LA.Refresh()
  -- the taxi flag clears a moment after control returns
  for _, sec in ipairs(TAXI_RECHECKS) do LA.After(sec, LA.Refresh) end
end

function Host.Init()
  LA.On("GROUP_ROSTER_UPDATE", onRoster)
  LA.On("UNIT_PHASE", onUnitPhase)
  LA.On("GROUP_LEFT", onGroupLeft)
  LA.On("PLAYER_CONTROL_LOST", LA.Refresh)
  LA.On("PLAYER_CONTROL_GAINED", onControlGained)
end

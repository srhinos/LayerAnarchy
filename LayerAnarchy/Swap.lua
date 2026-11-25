local _, LA = ...

local Swap = {}
LA.Swap = Swap

local ASK_WINDOW, RETRY_WINDOW, MORE_WINDOW, FALLBACK_AFTER = 25, 10, 20, 8
local JOIN_WAIT, VERDICT_AFTER, LEAVE_AFTER, MOVED_BACK_WATCH = 10, 3, 3, 6
local NOTE_FOR, LATE_FOR, SYSTEM_FRESH, BLOCKED_FLASH = 6, 90, 3, 4
local HOUR = 3600
local SHARDING = Enum.PhaseReason.Sharding

local cur
local nextId = 0
local lastAsk, lateUntil = nil, 0
local abandonedAt
local systemText, systemAt

local function now() return GetTime() end

local function setPhase(s, phase) s.phase, s.phaseAt = phase, now() end

local function leave(s, why)
  s.leaving = true
  LA.LeaveGroup(why)
end

local function hidePopup(accepted)
  local dialog = StaticPopup_FindVisible("PARTY_INVITE")
  -- the popup declines on hide unless told the invite was accepted
  if dialog and accepted then dialog.inviteAccepted = 1 end
  StaticPopup_Hide("PARTY_INVITE")
end

local function decline(name, why)
  pcall(DeclineGroup)
  hidePopup(false)
  LA.Log("decline", name, why)
  LA.Stats.Note("declined " .. why)
end

local function noteShown(s) return s.note ~= nil and now() < s.noteUntil end

local function tally(s)
  local sent, total, more, busy = 0, 0, false, false
  for _, p in pairs(s.progress) do
    sent, total = sent + p.sent, total + p.total
    if p.sent < p.total then busy = true end
    if p.more then more = true end
  end
  return sent, total, more and not busy, busy
end

local function finish(result, flashText, notice)
  local s = cur
  if not s then return end
  s.active, cur = false, nil
  lastAsk, lateUntil = s, now() + LATE_FOR
  LA.Each("StopAsk", s)
  LA.Each("OnSwapResult", s, result, s.host)
  LA.ClearPrefill()
  LA.Log("swap", result, s.host)
  if result == "moved" then LA.Stats.Note("swap", s.phaseAt - s.started) end
  if flashText then LA.Flash(flashText, notice) else LA.Refresh() end
end

local armDeadline

local function checkDeadline(s)
  if cur ~= s or s.phase ~= "asking" then return end
  if s.deadline > now() then return armDeadline(s) end
  finish("timeout", "No host found")
end

armDeadline = function(s)
  if s.deadlineTimer then s.deadlineTimer:Cancel() end
  s.deadlineTimer = LA.After(s.deadline - now(), checkDeadline, s)
end

local function tryFallback(s, due)
  if cur ~= s or s.fallbackTried or s.phase ~= "asking" or s.found > 0 then return end
  if (not due and now() - s.started < FALLBACK_AFTER) or not LA.Setting("askAutoLayer") then return end
  s.fallbackTried = true
  if LA.Each("Fallback", s) == "prefilled" then
    s.prefilled = true
    LA.Refresh()
  end
end

local function retry(why, note)
  local s = cur
  if not s then return end
  if s.hostKey then
    s.refused[s.hostKey] = true
    LA.Each("OnHostFailed", s, why, s.host)
  end
  setPhase(s, "asking")
  s.host, s.hostKey, s.leaving = nil, nil, nil
  s.deadline = math.max(s.deadline, now() + RETRY_WINDOW)
  s.note, s.noteUntil = note, now() + NOTE_FOR
  armDeadline(s)
  tryFallback(s)
  LA.Refresh()
end

local function newAsk()
  nextId = nextId + 1
  local t = now()
  local s = {
    id = nextId, active = true, phase = "asking", started = t, deadline = t + ASK_WINDOW, phaseAt = t,
    zone = LA.ZoneMapID(), asked = {}, offers = {}, refused = {}, found = 0, joins = 0, progress = {},
  }
  function s.Asked(name)
    local key = LA.NameKey(name)
    if key then s.asked[key] = true end
  end
  function s.Offer(name, netId)
    local key = LA.NameKey(name)
    if not key or s.offers[key] or s.refused[key] then return end
    s.offers[key] = true
    s.found = s.found + 1
    LA.Stats.Offered(netId, key)
    LA.Refresh()
  end
  function s.Refuse(name)
    local key = LA.NameKey(name)
    if key then s.refused[key] = true end
  end
  function s.Progress(netId, sent, total, more)
    local p = s.progress[netId] or {}
    s.progress[netId] = p
    p.sent, p.total, p.more = sent, total, more and true or false
    LA.Refresh()
  end
  function s.AllowAny(seconds)
    s.anyUntil = now() + seconds
    s.deadline = math.max(s.deadline, s.anyUntil)
  end
  return s
end

function Swap.Start()
  local s = newAsk()
  cur = s
  LA.Each("Ask", s)
  armDeadline(s)
  LA.After(FALLBACK_AFTER, tryFallback, s, true)
  LA.Refresh()
end

function Swap.Stop()
  local s = cur
  if not s then return end
  local phase = s.phase
  if phase == "invited" then
    hidePopup(false)
  elseif phase == "joining" and not IsInGroup() then
    abandonedAt = now()
  elseif phase ~= "asking" and IsInGroup() then
    leave(s, "stopped")
  end
  finish(phase == "moved" and "moved" or "stopped")
end

function Swap.More()
  local s = cur
  s.deadline = math.max(s.deadline, now() + MORE_WINDOW)
  LA.Each("More", s)
  LA.Refresh()
end

local function canAskMore(s)
  return s.phase == "asking" and not noteShown(s) and select(3, tally(s))
end

function LA.SwapClick()
  if LA.disabled or LA.Debug.Previewing() then return end
  if cur then
    if canAskMore(cur) then return Swap.More() end
    return Swap.Stop()
  end
  if IsInGroup() then return LA.Flash("In a group", nil, BLOCKED_FLASH) end
  if LA.InInstance() then return LA.Flash("In an instance", nil, BLOCKED_FLASH) end
  if LA.Host.Pending() then return LA.Flash("Inviting a player", nil, BLOCKED_FLASH) end
  Swap.Start()
end

function Swap.Busy() return cur ~= nil end

function Swap.ClaimsTransfer()
  return cur ~= nil and (cur.phase == "joined" or cur.phase == "moved" or cur.leftAt ~= nil)
end

local function askingStatus(s, v)
  if noteShown(s) then
    v.status, v.tone, v.border = s.note, "fail", "fail"
    return LA.WakeIn(s.noteUntil - now())
  end
  if s.prefilled then
    v.status, v.tone, v.border = "Press Enter to ask AutoLayer", "warn", "fail"
    return
  end
  local sent, total, more, busy = tally(s)
  if busy then
    v.status = "Asking " .. sent .. "/" .. total .. " – " .. s.found .. " found"
    return
  end
  v.status = "Searching (" .. s.found .. " found)"
  if more then v.swapText = "Ask more" end
end

local function movedStatus(s)
  if not (LA.Setting("auto") and s.leaveAt and not s.leftAt) then return "Moved" end
  local wait = s.leaveAt - now()
  local shown = math.max(0, math.ceil(wait))
  if shown > 0 then LA.WakeIn(wait - (shown - 1)) end
  return "Moved – leaving in " .. shown .. "s"
end

function Swap.View(v)
  local s = cur
  if not s then return false end
  v.tone, v.border, v.swapText = "swap", "swap", "Stop"
  local phase = s.phase
  if phase == "asking" then
    askingStatus(s, v)
  elseif phase == "invited" then
    v.status = "Invite from " .. (s.host or "?")
  elseif phase == "joining" then
    v.status = "Joining " .. (s.host or "the host")
  elseif phase == "joined" then
    v.status, v.swapText = "In " .. (s.host or "the host") .. "'s group", "Leave"
  else
    v.status, v.swapText = movedStatus(s), "Leave"
  end
  return true
end

local function verdict(s, join)
  if cur ~= s or s.phase ~= "joined" or s.joins ~= join then return end
  local unit = LA.LeaderUnit()
  local phase = unit and LA.PhaseOf(unit)
  local hostMap = unit and LA.Safe(C_Map.GetBestMapForUnit(unit))
  local sameZone = not hostMap or hostMap == LA.RawMapID()
  leave(s, "verdict")
  if (phase == SHARDING and sameZone) or LA.Limit.Likely() then
    local n = LA.Limit.Refused()
    finish("refused", "Refused – " .. n .. " this hour", "Reset in " .. LA.Countdown(LA.Limit.Left() or HOUR))
  else
    retry("same", "Same layer – retrying")
  end
end

local function checkJoin(s, phaseAt)
  if cur ~= s or s.phaseAt ~= phaseAt then return end
  if s.phase == "joining" or s.phase == "invited" then retry("ended") end
end

local function isLate(key)
  return now() < lateUntil and (lastAsk.asked[key] or lastAsk.offers[key])
end

local function wanted(s, key)
  return s.offers[key] or s.asked[key] or (s.anyUntil and now() < s.anyUntil)
end

local function onInvite(_, name, _, _, _, _, isCrossShard)
  name = LA.Safe(name)
  local key = LA.NameKey(name)
  if not key then return end
  local s = cur
  if not s or s.phase ~= "asking" then
    if (s and (s.asked[key] or s.offers[key])) or isLate(key) then decline(name, "late") end
    return
  end
  if not wanted(s, key) then return end
  if LA.Safe(isCrossShard) == false or s.refused[key] then
    decline(name, "same shard")
    s.refused[key] = true
    LA.Each("OnHostFailed", s, "same", name)
    return
  end
  s.host, s.hostKey = name, key
  LA.Stats.Note("invite")
  if LA.Setting("auto") then
    pcall(AcceptGroup)
    hidePopup(true)
    setPhase(s, "joining")
  else
    setPhase(s, "invited")
  end
  LA.After(JOIN_WAIT, checkJoin, s, s.phaseAt)
  LA.Refresh()
end

local function onJoined()
  local s = cur
  if not s then
    if abandonedAt and now() - abandonedAt < JOIN_WAIT then LA.LeaveGroup("stopped") end
    abandonedAt = nil
    return
  end
  if not (s.phase == "joining" or s.phase == "invited") or not IsInGroup() then return end
  setPhase(s, "joined")
  s.leaving = false
  s.joins = s.joins + 1
  LA.After(VERDICT_AFTER, verdict, s, s.joins)
  LA.Refresh()
end

local function finishMoved(s) if cur == s then finish("moved") end end

local function leaveAfterMove(s)
  if cur ~= s or s.phase ~= "moved" or s.leftAt or not IsInGroup() then return end
  s.leftAt = now()
  leave(s, "moved")
  LA.After(MOVED_BACK_WATCH, finishMoved, s)
end

local function onTransfer()
  local s = cur
  if not s then return end
  if s.phase == "joined" then
    setPhase(s, "moved")
    LA.Limit.Moved()
    LA.Moved("swap")
    if LA.Setting("auto") then
      s.leaveAt = now() + LEAVE_AFTER
      LA.After(LEAVE_AFTER, leaveAfterMove, s)
    end
    LA.Refresh()
  elseif s.leftAt and now() - s.leftAt <= MOVED_BACK_WATCH then
    LA.Moved("moved back")
    finish("moved back", "Moved back – try again")
  end
end

local function removedByHost()
  return systemAt ~= nil and now() - systemAt < SYSTEM_FRESH and systemText == ERR_UNINVITE_YOU
end

local function onLeft()
  local s = cur
  if not s then return end
  if s.phase == "moved" then
    if s.leftAt then return end
    s.leftAt = now()
    LA.After(MOVED_BACK_WATCH, finishMoved, s)
    return
  end
  if s.phase ~= "joined" or s.leaving then return end
  if removedByHost() then
    retry("removed", "Removed by " .. (s.host or "host") .. " – retrying")
  else
    retry("ended", "Group ended – retrying")
  end
end

local function onRoster()
  if cur and (cur.phase == "joining" or cur.phase == "invited") and IsInGroup() then onJoined() end
end

local function onSystem(_, text) if cur then systemText, systemAt = LA.Safe(text), now() end end

function Swap.Init()
  LA.On("PARTY_INVITE_REQUEST", onInvite)
  LA.On("GROUP_JOINED", onJoined)
  LA.On("GROUP_ROSTER_UPDATE", onRoster)
  LA.On("SHARD_TRANSFER", onTransfer)
  LA.On("GROUP_LEFT", onLeft)
  LA.On("CHAT_MSG_SYSTEM", onSystem)
end

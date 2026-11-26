local _, LA = ...

local Swap = {}
LA.Swap = Swap

local ASK_WINDOW, RETRY_WINDOW, MORE_WINDOW, FALLBACK_AFTER = 25, 10, 20, 8
local JOIN_WAIT, VERDICT_AFTER, LEAVE_AFTER, MOVED_BACK_WATCH, SETTLE_MARGIN = 10, 3, 3, 6, 3
local NOTE_FOR, LATE_FOR, SYSTEM_FRESH, BLOCKED_FLASH, STALE_SWAP = 6, 90, 3, 4, 120
local HOUR = 3600
local INVITE_SOUND_FILE = 567451
local SHARDING = Enum.PhaseReason.Sharding

local cur
local nextId = 0
local lastAsk, lateUntil = nil, 0
local abandonedAt, removedAt, leftToPlayer

local function now() return GetTime() end

local function setPhase(s, phase) s.phase, s.phaseAt = phase, now() end

local function leave(s, why)
  s.leaving = true
  LA.LeaveGroup(why)
end

local function muteInvites(on)
  on = on or nil
  if on == LA.db.invitesMuted then return end
  if pcall(on and MuteSoundFile or UnmuteSoundFile, INVITE_SOUND_FILE) then LA.db.invitesMuted = on end
end

local function releaseInvites()
  if not cur and now() >= lateUntil then muteInvites(false) end
end

local function ring()
  if LA.db.invitesMuted then pcall(PlaySound, SOUNDKIT.IG_PLAYER_INVITE) end
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

local function knows(fn, guid)
  local ok, yes = pcall(fn, guid)
  return ok and LA.Safe(yes) and true or false
end

local function social(guid)
  guid = LA.Safe(guid)
  if type(guid) ~= "string" or guid == "" then return false end
  return knows(C_FriendList.IsFriend, guid) or knows(IsGuildMember, guid)
    or knows(C_BattleNet.GetGameAccountInfoByGUID, guid)
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
  LA.After(LATE_FOR, releaseInvites)
  LA.char.swapHost = nil
  LA.Each("StopAsk", s)
  LA.Each("OnSwapResult", s, result, s.host)
  LA.ClearPrefill()
  LA.Log("swap", result, s.host)
  if result == "moved" then LA.Stats.Note("swap", s.phaseAt - s.started) end
  if flashText then LA.Flash(flashText, notice) else LA.Refresh() end
end

local armDeadline

local function checkDeadline(s)
  if cur ~= s or s.phase ~= "asking" or s.fallback == "prefilled" then return end
  if s.deadline > now() then return armDeadline(s) end
  finish("timeout", "No host found")
end

armDeadline = function(s)
  if s.deadlineTimer then s.deadlineTimer:Cancel() end
  s.deadlineTimer = LA.After(s.deadline - now(), checkDeadline, s)
end

local function extend(s, sec)
  s.deadline = math.max(s.deadline, now() + sec)
  armDeadline(s)
end

local function tryFallback(s, due)
  if cur ~= s or s.fallback or s.phase ~= "asking" or s.found > 0 then return end
  if (not due and now() - s.started < FALLBACK_AFTER) or not LA.Setting("askAutoLayer") then return end
  if LA.Each("Fallback", s) then
    s.fallback = "offered"
    LA.Refresh()
  end
end

local function prefillEnded(s, sent)
  if cur ~= s or s.fallback ~= "prefilled" then return end
  s.fallback = sent and "sent" or "offered"
  extend(s, RETRY_WINDOW)
  LA.Refresh()
end

local function askAutoLayer()
  local s = cur
  if not s or s.phase ~= "asking" or s.fallback ~= "offered" then return end
  if LA.Each("Prefill", s, function(sent) prefillEnded(s, sent) end) == "prefilled" then
    s.fallback = "prefilled"
    LA.Refresh()
  end
end

local ASK_NOTICE = { text = "", tone = "swap", button = { text = "Ask AutoLayer", onClick = askAutoLayer } }

local function retry(why, note)
  local s = cur
  if not s then return end
  if s.hostKey then
    s.refused[s.hostKey] = true
    LA.Each("OnHostFailed", s, why, s.host)
  end
  setPhase(s, "asking")
  s.host, s.hostKey, s.leaving = nil, nil, nil
  s.note, s.noteUntil = note, now() + NOTE_FOR
  extend(s, RETRY_WINDOW)
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
    if not key then return end
    s.asked[key] = true
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
  muteInvites(true)
  LA.ClearFlash()
  LA.Each("Ask", s)
  armDeadline(s)
  LA.After(FALLBACK_AFTER, tryFallback, s, true)
  LA.Refresh()
end

function Swap.Stop()
  local s = cur
  if not s then return end
  local phase = s.phase
  finish(phase == "moved" and "moved" or "stopped")
  if phase == "invited" then
    hidePopup(false)
  elseif phase == "joining" and not IsInGroup() then
    abandonedAt = now()
  elseif phase ~= "asking" and IsInGroup() then
    leave(s, "stopped")
  end
end

function Swap.More()
  local s = cur
  extend(s, MORE_WINDOW)
  LA.Each("More", s)
  LA.Refresh()
end

local function canAskMore(s)
  return s.phase == "asking" and not noteShown(s) and s.fallback ~= "prefilled" and select(3, tally(s))
end

function LA.SwapClick()
  if LA.disabled or LA.Debug.Previewing() then return end
  if cur then
    if canAskMore(cur) then return Swap.More() end
    return Swap.Stop()
  end
  if LA.InInstance() then return LA.Flash("In an instance", nil, BLOCKED_FLASH) end
  if IsInGroup() and not LA.Host.Release() then return LA.Flash("In a group", nil, BLOCKED_FLASH) end
  Swap.Start()
end

function Swap.Busy() return cur ~= nil end

function Swap.ClaimsTransfer() return cur ~= nil and cur.phase == "joined" end

local function involves(s, key) return s.asked[key] or s.offers[key] or s.refused[key] or s.hostKey == key end

function Swap.Owns(key)
  local late = now() < lateUntil and lastAsk or nil
  if not key then return cur ~= nil or late ~= nil end
  if key == leftToPlayer then return false end
  return (cur and involves(cur, key)) or (late and involves(late, key)) or false
end

local function askingStatus(s, v)
  if s.fallback == "offered" and s.found == 0 then v.notice = ASK_NOTICE end
  if noteShown(s) then
    v.status, v.tone, v.border = s.note, "fail", "fail"
    return LA.WakeIn(s.noteUntil - now())
  end
  if s.fallback == "prefilled" then
    v.status, v.tone, v.border = "Press " .. LA.UI.SendKey() .. " to send", "warn", "fail"
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
  local apart = unit ~= nil and LA.PhaseOf(unit) == SHARDING
  local hostZone = unit and LA.ZoneOf(LA.Safe(C_Map.GetBestMapForUnit(unit)))
  leave(s, "verdict")
  if hostZone and hostZone ~= LA.ZoneMapID() then return retry("zone", "Other zone – retrying") end
  if LA.Limit.Likely(apart) then
    local n = LA.Limit.Refused()
    return finish("refused", "Refused – " .. n .. " this hour", "Reset in " .. LA.Countdown(LA.Limit.Left() or HOUR))
  end
  if apart then return retry("ended", "Not moved – retrying") end
  retry("same", "Same layer – retrying")
end

local function checkJoin(s, phaseAt)
  if cur == s and s.phaseAt == phaseAt then retry("ended") end
end

local function isLate(key)
  return now() < lateUntil and (lastAsk.asked[key] or lastAsk.offers[key])
end

local function wanted(s, key, friend)
  if s.offers[key] then return true end
  return not friend and (s.asked[key] or (s.anyUntil and now() < s.anyUntil))
end

local function take(s, name, key)
  s.host, s.hostKey, leftToPlayer = name, key, nil
  LA.ExpectGroupLines()
  LA.Stats.Note("invite")
  local auto = LA.Setting("auto")
  if auto then
    pcall(AcceptGroup)
    hidePopup(true)
    setPhase(s, "joining")
    LA.After(JOIN_WAIT, checkJoin, s, s.phaseAt)
  else
    setPhase(s, "invited")
  end
  LA.ClearPrefill()
  LA.Refresh()
  return auto
end

local function handled(name, key, friend, sameShard)
  local s = cur
  if s and s.phase == "asking" and wanted(s, key, friend) then
    if sameShard or s.refused[key] then
      decline(name, "same shard")
      s.refused[key] = true
      LA.Each("OnHostFailed", s, "same", name)
      return true
    end
    return take(s, name, key)
  end
  if friend then
    leftToPlayer = key
  elseif (s and (s.asked[key] or s.offers[key])) or isLate(key) then
    decline(name, "late")
    return true
  end
  return false
end

local function onInvite(_, name, _, _, _, _, isCrossShard, _, inviterGUID)
  name = LA.Safe(name)
  local key = LA.NameKey(name)
  if key and not handled(name, key, social(inviterGUID), LA.Safe(isCrossShard) == false) then ring() end
end

local function onInviteCancelled() if cur and cur.phase == "invited" then retry("ended") end end

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
  LA.char.swapHost = { key = s.hostKey, at = time() }
  LA.After(VERDICT_AFTER, verdict, s, s.joins)
  LA.Refresh()
end

local function finishMoved(s)
  if cur ~= s then return end
  if LA.LayerEpoch() ~= s.movedEpoch then return finish("moved back", "Moved back – try again") end
  finish("moved")
end

local function watchMovedBack(s)
  s.leftAt = now()
  LA.After(MOVED_BACK_WATCH + SETTLE_MARGIN, finishMoved, s)
end

local function leaveAfterMove(s)
  if cur ~= s or s.phase ~= "moved" or s.leftAt or not IsInGroup() then return end
  watchMovedBack(s)
  leave(s, "moved")
end

local function onTransfer()
  local s = cur
  if not (s and s.phase == "joined") then return end
  setPhase(s, "moved")
  LA.Each("StopAsk", s)
  LA.Limit.Moved()
  LA.Moved("swap")
  s.movedEpoch = LA.LayerEpoch()
  if LA.Setting("auto") then
    s.leaveAt = now() + LEAVE_AFTER
    LA.After(LEAVE_AFTER, leaveAfterMove, s)
  end
  LA.Refresh()
end

local function removedByHost() return removedAt ~= nil and now() - removedAt < SYSTEM_FRESH end

local function onLeft()
  local s = cur
  if not s then return end
  if s.phase == "moved" then
    if not s.leftAt then watchMovedBack(s) end
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

local function onSystem(_, text)
  if cur and LA.GroupLine(LA.Safe(text)) == "ERR_UNINVITE_YOU" then removedAt = now() end
end

local function leaveStaleSwap()
  local r = LA.char.swapHost
  if cur or not r then return end
  LA.char.swapHost = nil
  if time() - r.at < STALE_SWAP and LA.Setting("auto") and LA.UnitFor(r.key) then LA.LeaveGroup("restored") end
end

function Swap.Init()
  LA.On("PARTY_INVITE_REQUEST", onInvite)
  LA.On("PARTY_INVITE_CANCEL", onInviteCancelled)
  LA.On("GROUP_JOINED", onJoined)
  LA.On("GROUP_ROSTER_UPDATE", onRoster)
  LA.On("SHARD_TRANSFER", onTransfer)
  LA.On("GROUP_LEFT", onLeft)
  LA.On("CHAT_MSG_SYSTEM", onSystem)
  LA.On("PLAYER_ENTERING_WORLD", leaveStaleSwap)
  releaseInvites()
end

local _, LA = ...

local Swap = {}
LA.Swap = Swap

local ROUND_EVERY, AUTOLAYER_AFTER, END_AFTER, TARGET_WAIT, SAFETY_CAP = 6, 12, 15, 8, 120
local JOIN_WAIT, VERDICT_AFTER, LEAVE_AFTER, MOVED_BACK_WATCH, SETTLE_MARGIN = 10, 3, 3, 6, 3
local NOTE_FOR, LATE_FOR, SYSTEM_FRESH, BLOCKED_FLASH, STALE_SWAP = 6, 90, 3, 4, 120
local HOUR = 3600
local INVITE_SOUND_FILE = 567451
local SHARDING = Enum.PhaseReason.Sharding

local cur
local lastAsk, lateUntil = nil, 0
local abandonedAt, removedAt, leftToPlayer

local function setPhase(s, phase) s.phase, s.phaseAt = phase, GetTime() end

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
  if not cur and GetTime() >= lateUntil then muteInvites(false) end
end

local function ring()
  if LA.db.invitesMuted then PlaySound(SOUNDKIT.IG_PLAYER_INVITE) end
end

local function hidePopup(accepted)
  local dialog = StaticPopup_FindVisible("PARTY_INVITE")
  -- the popup declines on hide unless told the invite was accepted
  if dialog and accepted then dialog.inviteAccepted = 1 end
  StaticPopup_Hide("PARTY_INVITE")
  return dialog ~= nil
end

local function decline(name, why)
  if not hidePopup(false) then pcall(DeclineGroup) end
  LA.Log("decline", name, why)
  LA.Stats.Note("declined " .. why)
end

local function knows(fn, guid) return LA.Safe(fn(guid)) end

local function social(guid)
  guid = LA.Safe(guid)
  if not guid or guid == "" then return false end
  return knows(C_FriendList.IsFriend, guid) or knows(IsGuildMember, guid)
    or knows(C_BattleNet.GetGameAccountInfoByGUID, guid)
end

local function noteShown(s) return s.note ~= nil and GetTime() < s.noteUntil end

local function progressOf(s)
  local waiting, search = 0, false
  for _, p in pairs(s.progress) do
    waiting, search = waiting + p.waiting, search or p.search
  end
  return s.askedCount, s.askedCount + waiting, search
end

local function finish(result, flashText, notice)
  local s = cur
  if not s then return end
  s.active, cur = false, nil
  lastAsk, lateUntil = s, GetTime() + LATE_FOR
  LA.After(LATE_FOR, releaseInvites)
  LA.char.swapHost = nil
  LA.Each("StopAsk", s)
  LA.Each("OnSwapResult", s, result, s.host)
  LA.ClearPrefill()
  LA.Log("swap", result, s.host)
  if result == "moved" then LA.Stats.Note("swap", s.phaseAt - s.started) end
  if flashText then LA.Flash(flashText, notice) else LA.Refresh() end
end

local armEnd

local function endAt(s)
  local cap = math.max(s.started + SAFETY_CAP, s.anyUntil or 0)
  if not s.exhausted then return cap end
  return math.min(cap, math.max(s.activeAt + s.endAfter, s.anyUntil or 0))
end

local function checkEnd(s)
  if cur ~= s or s.phase ~= "asking" or s.fallback == "prefilled" then return end
  if endAt(s) > GetTime() then return armEnd(s) end
  finish("timeout", s.noAnswer)
end

armEnd = function(s)
  if s.endTimer then s.endTimer:Cancel() end
  s.endTimer = LA.After(math.max(0, endAt(s) - GetTime()), checkEnd, s)
end

local function touch(s)
  s.activeAt = GetTime()
  armEnd(s)
end

local armRound

local function round(s)
  if cur ~= s or s.phase ~= "asking" then return end
  if LA.Each("Round", s) then return armRound(s) end
  s.exhausted = true
  checkEnd(s)
end

armRound = function(s)
  if s.target then return end
  if s.roundTimer then s.roundTimer:Cancel() end
  s.exhausted = false
  s.roundTimer = LA.After(ROUND_EVERY, round, s)
end

local function tryFallback(s, due)
  if cur ~= s or s.fallback or s.phase ~= "asking" or s.target then return end
  if (not due and GetTime() - s.started < AUTOLAYER_AFTER) or not LA.Setting("askAutoLayer") then return end
  if LA.Each("Fallback", s) then
    s.fallback = "offered"
    touch(s)
    LA.Refresh()
  end
end

local function refuse(s, key)
  if s.refused[key] then return end
  s.refused[key] = true
  if s.offers[key] then s.found = s.found - 1 end
end

local function prefillEnded(s, sent)
  if cur ~= s or s.fallback ~= "prefilled" then return end
  s.fallback = sent and "sent" or "offered"
  touch(s)
  LA.Refresh()
end

local function askAutoLayer()
  local s = cur
  if not s or s.phase ~= "asking" or s.fallback ~= "offered" then return end
  if LA.Each("Prefill", s, function(sent) prefillEnded(s, sent) end) == "prefilled" then
    s.fallback = "prefilled"
    touch(s)
    LA.Refresh()
  end
end

local function searchMore()
  local s = cur
  if not s or s.phase ~= "asking" then return end
  LA.Each("Search", s)
  armRound(s)
  touch(s)
  LA.Refresh()
end

local ASK_BUTTON = { text = "Ask AutoLayer", onClick = askAutoLayer }
local SEARCH_BUTTON = { text = "Search more", onClick = searchMore }
local NOTICE = { text = "", tone = "swap", buttons = {} }

local function retry(why, note)
  local s = cur
  if not s then return end
  if s.hostKey then
    refuse(s, s.hostKey)
    LA.Each("OnHostFailed", s, why, s.host)
  end
  setPhase(s, "asking")
  s.host, s.hostKey, s.leaving = nil, nil, nil
  s.note, s.noteUntil = note, GetTime() + NOTE_FOR
  armRound(s)
  touch(s)
  tryFallback(s)
  LA.Refresh()
end

local function skippedOut(s)
  local wait
  for key in pairs(s.skips) do
    local left = LA.Layers.SkipLeft(key)
    wait = math.min(wait or left, left)
  end
  finish("skipped", "Skipped by " .. s.skipped .. " – ready in " .. LA.Clock(wait))
end

local function newAsk(target)
  local t = GetTime()
  local s = {
    active = true, phase = "asking", started = t, activeAt = t, phaseAt = t, exhausted = target ~= nil, target = target,
    endAfter = target and TARGET_WAIT or END_AFTER,
    noAnswer = target and ("No Layer " .. target.letter .. " host answered") or "No hosts found",
    zone = LA.ZoneMapID(), asked = {}, askedCount = 0, offers = {}, refused = {}, found = 0, joins = 0, progress = {},
    skips = {}, skipped = 0,
  }
  function s.Asked(name)
    local key = LA.NameKey(name)
    if not key or s.asked[key] then return end
    s.asked[key] = true
    s.askedCount = s.askedCount + 1
    LA.Refresh()
  end
  function s.Offer(name, netId)
    local key = LA.NameKey(name)
    if not key or s.offers[key] or s.refused[key] then return end
    s.offers[key] = true
    s.found = s.found + 1
    LA.Stats.Offered(netId, key)
    touch(s)
    LA.Refresh()
  end
  function s.Refuse(name)
    local key = LA.NameKey(name)
    if key then refuse(s, key) end
  end
  function s.Offered(name)
    local key = LA.NameKey(name)
    return key ~= nil and s.offers[key] == true and not s.refused[key]
  end
  function s.Progress(netId, waiting, search)
    local p = s.progress[netId] or {}
    s.progress[netId] = p
    search = search and true or false
    if search and not p.search then touch(s) end
    p.waiting, p.search = waiting, search
    LA.Refresh()
  end
  function s.AllowAny(seconds)
    s.anyUntil = GetTime() + seconds
    armEnd(s)
  end
  function s.Skipped(name)
    local key = LA.NameKey(name)
    if not (s.target and key and s.target.keys[key]) or s.skips[key] then return end
    s.skips[key], s.skipped = true, s.skipped + 1
    if cur == s and s.phase == "asking" and s.skipped >= s.target.count then skippedOut(s) end
  end
  return s
end

local function begin(s)
  cur = s
  muteInvites(true)
  LA.ClearFlash()
end

function Swap.Start()
  local s = newAsk()
  begin(s)
  LA.Log("ask", s.zone, InCombatLockdown() and "combat" or "")
  LA.Each("Ask", s)
  armRound(s)
  armEnd(s)
  LA.After(AUTOLAYER_AFTER, tryFallback, s, true)
  LA.Refresh()
end

local function startTargeted(rec)
  local hosts, letter = LA.Layers.Hosts(rec)
  if not letter then return end
  local t = { record = rec, letter = letter, keys = {}, count = 0 }
  local s, byNet = newAsk(t), {}
  begin(s)
  LA.Log("ask", s.zone, "layer " .. letter, #hosts)
  for _, h in ipairs(hosts) do
    t.keys[h.key] = true
    if h.net then
      byNet[h.net] = byNet[h.net] or {}
      table.insert(byNet[h.net], h.name)
    end
  end
  for netId, names in pairs(byNet) do t.count = t.count + (LA.Call(LA.Net(netId), "Target", s, names) or 0) end
  if t.count == 0 then return finish("timeout", s.noAnswer) end
  armEnd(s)
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
    abandonedAt = GetTime()
  elseif phase ~= "asking" and IsInGroup() then
    leave(s, "stopped")
  end
end

local function blocked()
  local why = (IsInInstance() and "In an instance") or (IsInGroup() and not LA.Host.Release() and "In a group")
  if why then LA.Flash(why, nil, BLOCKED_FLASH) end
  return why
end

function LA.SwapClick()
  if LA.disabled then return end
  if cur then return Swap.Stop() end
  if not blocked() then Swap.Start() end
end

function LA.SwapTo(rec)
  if LA.disabled or cur or blocked() then return end
  startTargeted(rec)
end

function Swap.Busy() return cur ~= nil end

function Swap.Target() return cur and cur.target and cur.target.record end

function Swap.ClaimsTransfer() return cur ~= nil and cur.phase == "joined" end

local function lateAsk() return GetTime() < lateUntil and lastAsk or nil end

local function addressed(s, key) return s and (s.asked[key] or s.offers[key]) end

local function involves(s, key) return addressed(s, key) or s.refused[key] or s.hostKey == key end

function Swap.Owns(key)
  local late = lateAsk()
  if not key then return cur ~= nil or late ~= nil end
  if key == leftToPlayer then return false end
  return (cur and involves(cur, key)) or (late and involves(late, key)) or false
end

local function askingStatus(s, v)
  local asked, queued, search = progressOf(s)
  local buttons = NOTICE.buttons
  wipe(buttons)
  if s.fallback == "offered" then buttons[#buttons + 1] = ASK_BUTTON end
  if search and s.fallback ~= "prefilled" then buttons[#buttons + 1] = SEARCH_BUTTON end
  if buttons[1] then v.notice = NOTICE end
  if noteShown(s) then
    v.status, v.tone, v.border = s.note, "fail", "fail"
    return LA.WakeIn(s.noteUntil - GetTime())
  end
  if s.target then
    v.status = "Asking Layer " .. s.target.letter .. " – " .. asked .. "/" .. s.target.count
  elseif s.fallback == "prefilled" then
    v.status, v.tone, v.border = "Press " .. LA.UI.SendKey() .. " to send", "warn", "fail"
  elseif queued == 0 then
    v.status = "Searching (" .. s.found .. " found)"
  else
    v.status = "Asking " .. asked .. "/" .. queued .. " – " .. s.found .. " found"
  end
end

local function movedStatus(s)
  if not (LA.Setting("auto") and s.leaveAt) then return "Moved" end
  local wait = s.leaveAt - GetTime()
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
    v.status = "Invite from " .. s.host
  elseif phase == "joining" then
    v.status = "Joining " .. s.host
  elseif phase == "joined" then
    v.status, v.swapText = "In " .. s.host .. "'s group", "Leave"
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

local function wanted(s, key, friend)
  local t = s.target
  if t then return t.keys[key] and LA.Layers.Trusted(t.record, key) end
  if s.offers[key] then return true end
  return not friend and (s.asked[key] or (s.anyUntil and GetTime() < s.anyUntil))
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
      refuse(s, key)
      LA.Each("OnHostFailed", s, "same", name)
      return true
    end
    return take(s, name, key)
  end
  if friend then
    leftToPlayer = key
  elseif addressed(s, key) or addressed(lateAsk(), key) then
    decline(name, "late")
    return true
  end
  return false
end

local function onInvite(_, name, _, _, _, _, isCrossShard, _, inviterGUID)
  name = LA.Safe(name)
  local key = LA.NameKey(name)
  if not key then return end
  local sameShard = LA.Safe(isCrossShard) == false
  local ours = handled(name, key, social(inviterGUID), sameShard)
  LA.Layers.Invited(name, sameShard)
  if not ours then ring() end
end

local function onInviteCancelled() if cur and cur.phase == "invited" then retry("ended") end end

local function awaitingJoin(s) return s.phase == "joining" or s.phase == "invited" end

local function onJoined()
  local s = cur
  if not s then
    if abandonedAt and GetTime() - abandonedAt < JOIN_WAIT then LA.LeaveGroup("stopped") end
    abandonedAt = nil
    return
  end
  if not awaitingJoin(s) or not IsInGroup() then return end
  setPhase(s, "joined")
  s.leaving = false
  s.joins = s.joins + 1
  LA.char.swapHost = { key = s.hostKey, at = time() }
  LA.After(VERDICT_AFTER, verdict, s, s.joins)
  LA.Refresh()
end

local function leaveAfterMove(s)
  if cur ~= s or s.phase ~= "moved" or not IsInGroup() then return end
  leave(s, "moved")
end

local function finishMoved(s)
  if LA.LayerEpoch() ~= s.epochBefore then LA.WatchMoveBack(s.epochBefore, MOVED_BACK_WATCH + SETTLE_MARGIN) end
  finish("moved")
end

local function onTransfer()
  local s = cur
  if not (s and s.phase == "joined") then return end
  setPhase(s, "moved")
  LA.Each("StopAsk", s)
  LA.Limit.Moved()
  s.epochBefore = LA.LayerEpoch()
  LA.Moved("swap")
  LA.Layers.Landed(s.host, s.target and s.target.record)
  LA.WatchMoveBack(s.epochBefore, LEAVE_AFTER + MOVED_BACK_WATCH + SETTLE_MARGIN)
  if LA.Setting("auto") then
    s.leaveAt = GetTime() + LEAVE_AFTER
    LA.After(LEAVE_AFTER, leaveAfterMove, s)
  end
  LA.Refresh()
end

local function removedByHost() return removedAt ~= nil and GetTime() - removedAt < SYSTEM_FRESH end

local function onGroupLeft()
  local s = cur
  if not s then return end
  if s.phase == "moved" then return finishMoved(s) end
  if s.phase ~= "joined" or s.leaving then return end
  if removedByHost() then
    retry("removed", "Removed by " .. s.host .. " – retrying")
  else
    retry("ended", "Group ended – retrying")
  end
end

local function onRoster()
  if cur and awaitingJoin(cur) and IsInGroup() then onJoined() end
end

local function onSystem(_, text)
  if cur and LA.GroupLine(LA.Safe(text)) == "ERR_UNINVITE_YOU" then removedAt = GetTime() end
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
  LA.On("GROUP_LEFT", onGroupLeft)
  LA.On("CHAT_MSG_SYSTEM", onSystem)
  LA.On("PLAYER_ENTERING_WORLD", leaveStaleSwap)
  releaseInvites()
end

local _, LA = ...

local Debug = {}
LA.Debug = Debug

local STATE_EVERY = 2.5
local LABEL, MOVED_LABEL = "Layer C", "Layer H"
local HOST, GUEST = "Bram Holloway", "Ines Calder"
local RESET_NOTICE = { text = "Reset in ~45m", tone = "warn" }
local REFRESH_NOTICE = { text = "", tone = "warn", button = { text = "Refresh now" } }

local function waiting(status, border, notice)
  return { status = status, tone = "warn", border = border, notice = notice }
end

local function swapping(status, swapText, label)
  return { status = status, tone = "swap", border = "swap", swapText = swapText or "Stop", label = label }
end

local function failed(status, swapText, notice)
  return { status = status, tone = "fail", border = "fail", swapText = swapText, notice = notice }
end

local STATES = {
  { status = "Hosting" },
  { status = "Host off", tone = "off", help = false },
  waiting("Paused (flying)"),
  waiting("Paused (in group)"),
  waiting("Paused (instance)"),
  waiting("Paused (invite limit)"),
  swapping("Searching (0 found)"),
  swapping("Asking 6/14 – 0 found"),
  { status = "Press Enter to ask AutoLayer", tone = "warn", border = "fail", swapText = "Stop" },
  swapping("Searching (3 found)", "Ask more"),
  swapping("Invite from " .. HOST),
  swapping("Joining " .. HOST),
  swapping("In " .. HOST .. "'s group", "Leave"),
  swapping("Moved – leaving in 3s", "Leave", MOVED_LABEL),
  swapping("Moved", "Leave", MOVED_LABEL),
  failed("No host found"),
  failed("Same layer – retrying", "Stop"),
  failed("Removed by " .. HOST .. " – retrying", "Stop"),
  failed("Group ended – retrying", "Stop"),
  failed("Moved back – try again"),
  failed("Refused – 16 this hour", nil, RESET_NOTICE),
  failed("In a group"),
  failed("In an instance"),
  failed("Inviting a player"),
  waiting("Reset in ~45m"),
  waiting("Refresh in 0:47", "fail", REFRESH_NOTICE),
  { status = "Inviting " .. GUEST, tone = "host", border = "host" },
  { status = "Off – AutoLayer loaded", tone = "off", swapEnabled = false },
}

local FAKE = {
  hour = {
    nets = { layerswap = { 12, 12, 3 }, voidnet = { 58, 9, 2 }, autolayer = { 34, 18 }, flh = { 0, 0, 0 } },
    view = {
      swaps = 4, avg = 2.8, best = 1.9, thisHour = 9, limit = 16, taken = 5, same = 1, late = 0,
      ground = { asked = 12, invited = 7, moved = 5, failed = 2 }, flying = { invited = 3, moved = 3, failed = 0 },
    },
  },
  session = {
    nets = { layerswap = { 27, 27, 6 }, voidnet = { 58, 31, 5 }, autolayer = { 34, 26 }, flh = { 1, 1, 0 } },
    view = {
      swaps = 11, avg = 3.4, best = 1.6, thisHour = 9, limit = 16, taken = 13, same = 2, late = 1,
      ground = { asked = 41, invited = 23, moved = 18, failed = 4 }, flying = { invited = 9, moved = 7, failed = 1 },
    },
  },
}

local ticker, step, faking = nil, 1, false
local fakeStats = {}

local function window() return FAKE[LA.Setting("statsWindow")] or FAKE.hour end

function fakeStats.Net(netId) return unpack(window().nets[netId]) end

function fakeStats.View() return window().view end

local function announce(what, on) LA.Print(what .. " preview " .. (on and "on" or "off")) end

local function advance()
  step = step % #STATES + 1
  LA.Refresh()
end

function Debug.Previewing() return ticker ~= nil end

function Debug.Fill(v)
  if not ticker then return false end
  v.label, v.help = LABEL, true
  for key, value in pairs(STATES[step]) do v[key] = value end
  return true
end

function Debug.Stats() return faking and fakeStats or nil end

function Debug.ToggleStates()
  if ticker then
    ticker:Cancel()
    ticker = nil
  else
    step, ticker = 1, C_Timer.NewTicker(STATE_EVERY, advance)
  end
  announce("state", ticker ~= nil)
  LA.Refresh()
end

function Debug.ToggleStats()
  faking = not faking
  announce("stats", faking)
  LA.Refresh()
end

LA.Command("debug states", Debug.ToggleStates)
LA.Command("debug stats", Debug.ToggleStats)

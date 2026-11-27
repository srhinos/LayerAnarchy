local _, LA = ...

local Debug = {}


local STATE_EVERY = 2.5
local LABEL, MOVED_LABEL, NEW_LABEL, BACK = "Layer C", "Layer H", "Layer F?", "· back after 4m"
local HOST, GUEST = "Bram Holloway", "Ines Calder"
local ASK, SEARCH = { text = "Ask AutoLayer" }, { text = "Search more" }
local RESET_NOTICE = { text = "Reset in ~45m", tone = "warn" }
local REFRESH_NOTICE = { text = "", tone = "warn", buttons = { { text = "Refresh now" } } }
local ASK_NOTICE = { text = "", tone = "swap", buttons = { ASK } }
local SEARCH_NOTICE = { text = "", tone = "swap", buttons = { SEARCH } }
local BOTH_NOTICE = { text = "", tone = "swap", buttons = { ASK, SEARCH } }

local function waiting(status, border, notice)
  return { status = status, tone = "warn", border = border, notice = notice }
end

local function swapping(status, swapText, label)
  return { status = status, tone = "swap", border = "swap", swapText = swapText or "Stop", label = label }
end

local function offering(status, notice)
  return { status = status, tone = "swap", border = "swap", swapText = "Stop", notice = notice }
end

local function failed(status, swapText, notice)
  return { status = status, tone = "fail", border = "fail", swapText = swapText, notice = notice }
end

local STATES = {
  { status = "Hosting" },
  { status = "Hosting", label = NEW_LABEL },
  { status = "Layer F was B", label = "Layer B", back = BACK },
  { status = "Host off", tone = "off", help = false },
  waiting("Paused (flying)"),
  waiting("Paused (in group)"),
  waiting("Paused (instance)"),
  waiting("Paused (invite limit)"),
  swapping("Searching (0 found)"),
  swapping("Asking 6/14 – 0 found"),
  offering("Asking 49/49 – 0 found", SEARCH_NOTICE),
  offering("Asking 22/22 – 1 found", ASK_NOTICE),
  offering("Asking 71/71 – 0 found", BOTH_NOTICE),
  { status = "Press Enter to send", tone = "warn", border = "fail", swapText = "Stop" },
  swapping("Invite from " .. HOST),
  swapping("Joining " .. HOST),
  swapping("In " .. HOST .. "'s group", "Leave"),
  swapping("Moved – leaving in 3s", "Leave", MOVED_LABEL),
  swapping("Moved", "Leave", MOVED_LABEL),
  failed("No hosts found"),
  failed("Same layer – retrying", "Stop"),
  failed("Not moved – retrying", "Stop"),
  failed("Other zone – retrying", "Stop"),
  failed("Removed by " .. HOST .. " – retrying", "Stop"),
  failed("Group ended – retrying", "Stop"),
  failed("Moved back – try again"),
  swapping("Asking Layer B – 2/3"),
  failed("Skipped by 2 – ready in 0:41"),
  failed("No Layer D host answered"),
  failed("Landed on Layer C"),
  failed("Refused – 16 this hour", nil, RESET_NOTICE),
  failed("In a group"),
  failed("In an instance"),
  waiting("Reset in ~45m"),
  waiting("Refresh in 0:47", "fail", REFRESH_NOTICE),
  { status = "Inviting " .. GUEST, tone = "host", border = "host" },
  { status = "Off – AutoLayer loaded", tone = "off", swapEnabled = false, notice = { text = "", tone = "warn", buttons = { {
    text = "Disable AutoLayer", tip = "Both addons would answer the same invites and leave the same groups, undoing each other's swaps.",
  } } } },
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

local LAYERS = {
  { name = LABEL, when = "now", hosts = "you are here", here = true },
  { name = "Layer B", when = "4m ago", hosts = "3 hosts · ", state = "ready", ready = true, enabled = true },
  { name = "Layer A", when = "1m ago", hosts = "2 hosts · ", state = "0:41", enabled = true },
  { name = "Layer D", when = "12m ago", hosts = "1 host · ", state = "ready", ready = true, enabled = true },
  { name = "Layer E", when = "40m ago", hosts = "no hosts known" },
}

local ticker, step, faking = nil, 1, false
local fakeStats = {}
local realView, realList, realNet, realStatsView = LA.View, LA.Layers.List, LA.Stats.Net, LA.Stats.View

local function window() return FAKE[LA.Setting("statsWindow")] end

function fakeStats.Net(netId) return unpack(window().nets[netId]) end

function fakeStats.View() return window().view end

local function announce(what, on) LA.Print(what .. " preview " .. (on and "on" or "off")) end

local function advance()
  step = step % #STATES + 1
  LA.Refresh()
end

function LA.View()
  local v = realView()
  if not ticker then return v end
  v.label, v.back, v.help, v.status, v.tone, v.border, v.notice = LABEL, nil, true, nil, "idle", "neutral", nil
  v.swapText, v.swapEnabled = "Swap", true
  for key, value in pairs(STATES[step]) do v[key] = value end
  return v
end

function LA.Layers.List() return ticker and LAYERS or realList() end

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
  LA.Stats.Net = faking and fakeStats.Net or realNet
  LA.Stats.View = faking and fakeStats.View or realStatsView
  announce("stats", faking)
  LA.Refresh()
end

LA.Command("debug states", Debug.ToggleStates)
LA.Command("debug stats", Debug.ToggleStats)

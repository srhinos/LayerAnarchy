local _, LA = ...

local UI = {}
LA.UI = UI

local WHITE = "Interface\\Buttons\\WHITE8x8"
local MEDIA = "Interface\\AddOns\\LayerAnarchy\\Media\\"
local ICON = { layers = MEDIA .. "layers", cog = MEDIA .. "cog", minus = MEDIA .. "minus" }
local LATIN = { enUS = true, enGB = true, deDE = true, frFR = true, esES = true, esMX = true, ptBR = true, itIT = true }
local FONT = STANDARD_TEXT_FONT
local NARROW = LATIN[GetLocale()] and "Fonts\\ARIALN.TTF" or STANDARD_TEXT_FONT

local W, PAD, GAP, ROW, HOST_W, ANCHORED_W = 244, 8, 4, 22, 72, 10
local LINE1_TOP, LINE1_H, LINE_GAP, LINE2_H, ROW_GAP = 8, 18, 3, 15, 9
local BASE_H = LINE1_TOP + LINE1_H + LINE_GAP + LINE2_H + ROW_GAP + ROW + PAD
local GLYPH_BTN, GLYPH_INSET, GLYPH_TEXT_GAP, BUTTON_INSET, DEFAULT_Y = 18, 3, 2, 3, 200
local REST_ALPHA, SEP_H, SEP_GAP = 0.45, 14, 3
local CORNER_X, CORNER_Y = PAD - GLYPH_INSET, -7
local NOTE_TOP, NOTE_TEXT_TOP, NOTE_TEXT_H, NOTE_GAP = 8, 7, 14, 5
local OPT_H, PILL_W, PILL_H, HEAD_H, DRAWER_LEVEL = 22, 40, 18, 22, 5
local DRAWER_INSET, HEAD_TOP, LIST_TOP, DRAWER_BOTTOM, ROW_INSET = 6, 4, 6, 6, 4
local SLIDER_W, SLIDER_H, SLIDER_GAP, READOUT_W, TRACK_H, THUMB_W, THUMB_H = 56, 14, 4, 40, 3, 4, 10
local STEP_W, STEP_GLYPH, PAD_ICON, PAD_BADGE = 14, 9, 14, 12
local STAT_H, SECTION_H, SECTION_BASE, COL_W, GRID_COLUMNS, RECHECK = 15, 18, 2, 42, 4, 15
local SEG_H, SEG_GAP, SEG_INSET = 16, 4, 1
local BARS_W, BARS_GAP, BARS_H = 3, 2, { 5, 9, 13 }
local HUD_MIN_W, HUD_H, HUD_GLYPH, HUD_GLYPH_X, HUD_TEXT_GAP, HUD_PAD_R = 110, 40, 18, 9, 7, 10
local HUD_TEXT_X = HUD_GLYPH_X + HUD_GLYPH + HUD_TEXT_GAP
local HUD_TEXT_TOP, HUD_LINE_GAP, HUD_WIDTH_STEP = 7, 3, 8
local COG_SIZE, MINI_SIZE, CLOSE_SIZE = 13, 12, 13
local SIZE = { line1 = 16, line2 = 13, button = 11, title = 11, option = 10, note = 12, hud = 12, stat = 11, caption = 9, seg = 10 }
local CROSS, PLUS = { 45, -45 }, { 0, 90 }
local MAX_INVITES, SCALE_MIN, SCALE_MAX, SCALE_STEP = 100, 0.7, 1.5, 0.05
local REFERENCE_HEIGHT, BG_SUBLEVEL = 768, -8

local function rgb(hex, a)
  return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, a or 1 }
end

local C = {
  bg = rgb("1d1e22"), hudBg = rgb("121316", 0.86), btn = rgb("3a3c42"), btnEdge = rgb("5c5f66"),
  hover = { 1, 1, 1, 0.07 }, text = rgb("e6e6e6"), white = rgb("f2f2f2"), bright = rgb("ffffff"),
  note = rgb("d9d9d9"), dim = rgb("76787e"), value = rgb("cfcfcf"), muted = rgb("8d8f95"), faint = rgb("5c5f66"),
  gold = rgb("e8cc6a"), green = rgb("5fd88a"), amber = rgb("f0a64a"), grey = rgb("9a9a9a"), soft = rgb("b9b9b4"),
}
local TONE = { idle = C.soft, swap = C.green, fail = C.amber, host = C.gold, off = C.dim, warn = C.amber }
local BORDER = { neutral = rgb("4a4c52"), swap = rgb("3fbf6a"), fail = rgb("e0912e"), host = rgb("d8b84a") }
local GLYPH = { neutral = C.gold, swap = C.green, fail = C.amber, host = C.gold }
local NOTE_EDGE = { warn = BORDER.fail, fail = BORDER.fail, swap = BORDER.swap, host = BORDER.host }

local OPTIONS = {
  { "Host for others", "help" },
  { "Host while flying", "hostWhileFlying" },
  { "Accept and leave automatically", "auto" },
  { "Sound when moved", "sound" },
  { "Ask AutoLayer hosts too", "askAutoLayer" },
  { "Lock position", "locked" },
}
local NETWORKS = { { "layerswap", "LayerSwap" }, { "voidnet", "VoidNet" }, { "autolayer", "AutoLayer" }, { "flh", "Layer Hop" } }
local COLUMNS = { "Seen", "Talking", "Hosts" }
local WINDOWS = { { "1h", "hour", 22 }, { "Session", "session", 44 } }
local NONE = "–"

local root, box, hud, note, driver
local sliders, skinned, hairs, rows = {}, {}, {}, {}
local netRows, gridRows, segs = {}, {}, {}
local drawers, toggles, revealed, dimmed = {}, {}, {}, {}
local placed, pad = {}, { listed = false, focused = false }
local open, current

local function Text(parent, font, size, c)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(font, size, "")
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.8)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  fs:SetTextColor(c[1], c[2], c[3], c[4])
  fs.tint, fs.prefix = c, false
  return fs
end

local function Set(fs, s)
  fs.text = s
  if fs.prefix then s = fs.prefix .. s end
  if fs.cur == s then return false end
  fs.cur = s
  fs:SetText(s)
  return true
end

local function Tint(fs, c)
  if fs.tint == c then return end
  fs.tint = c
  fs:SetTextColor(c[1], c[2], c[3], c[4])
end

local function Solid(parent, layer, c, sub)
  local t = parent:CreateTexture(nil, layer, nil, sub)
  t:SetTexture(WHITE)
  t:SetVertexColor(c[1], c[2], c[3], c[4])
  return t
end

local function Skin(f, bg, edge)
  Solid(f, "BACKGROUND", bg, BG_SUBLEVEL):SetAllPoints()
  local e = {}
  for i = 1, 4 do e[i] = Solid(f, "BORDER", edge) end
  e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT")
  e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT")
  e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT")
  e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT")
  f.edges, f.edge = e, edge
  skinned[#skinned + 1] = f
end

local function Edge(f, c)
  if f.edge == c then return end
  f.edge = c
  for i = 1, 4 do f.edges[i]:SetVertexColor(c[1], c[2], c[3], c[4]) end
end

local function Pixel(f)
  local _, h = GetPhysicalScreenSize()
  return REFERENCE_HEIGHT / h / f:GetEffectiveScale()
end

local function Thin()
  for _, f in ipairs(skinned) do
    local p, e = Pixel(f), f.edges
    e[1]:SetHeight(p); e[2]:SetHeight(p); e[3]:SetWidth(p); e[4]:SetWidth(p)
  end
  for _, t in ipairs(hairs) do t:SetHeight(Pixel(box)) end
end

local function Paint(g, c)
  if g.c == c then return end
  g.c = c
  for _, t in ipairs(g.textures) do t:SetVertexColor(c[1], c[2], c[3], c[4]) end
end

local function Glyph(parent, size, file, c, angles)
  local g = CreateFrame("Frame", nil, parent)
  g:SetSize(size, size)
  g.textures = {}
  for i, angle in ipairs(angles or { 0 }) do
    local t = g:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints()
    t:SetTexture(file)
    t:SetSnapToPixelGrid(false)
    t:SetTexelSnappingBias(0)
    if angle ~= 0 then t:SetRotation(math.rad(angle)) end
    g.textures[i] = t
  end
  Paint(g, c)
  return g
end

local function Icon(size, file, angles)
  return function(parent) return Glyph(parent, size, file, C.grey, angles) end
end

local function Bars(parent)
  local g = CreateFrame("Frame", nil, parent)
  g:SetSize(#BARS_H * (BARS_W + BARS_GAP) - BARS_GAP, BARS_H[#BARS_H])
  g.textures = {}
  for i, h in ipairs(BARS_H) do
    local t = Solid(g, "ARTWORK", C.grey)
    t:SetSize(BARS_W, h)
    t:SetPoint("BOTTOMLEFT", (i - 1) * (BARS_W + BARS_GAP), 0)
    g.textures[i] = t
  end
  g.c = C.grey
  return g
end

local function Selectable(b, mark)
  b.mark, b.OnSmartNavSelect, b.OnSmartNavDeselect = mark, pad.Pick, pad.Unpick
  return b
end

local function Button(parent, w, h)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  Skin(b, C.btn, C.btnEdge)
  Solid(b, "HIGHLIGHT", C.hover):SetAllPoints()
  b.label = Text(b, FONT, SIZE.button, C.text)
  b.label:SetJustifyH("CENTER")
  b.label:SetPoint("LEFT", BUTTON_INSET, 0)
  b.label:SetPoint("RIGHT", -BUTTON_INSET, 0)
  return Selectable(b, pad.Label)
end

local function LayoutDrawer(d, below)
  local head, body = d.head, d.body
  head:ClearAllPoints()
  body:ClearAllPoints()
  if below then
    head:SetPoint("TOPLEFT", DRAWER_INSET, -HEAD_TOP); head:SetPoint("TOPRIGHT", -DRAWER_INSET, -HEAD_TOP)
    body:SetPoint("TOPLEFT", head, "BOTTOMLEFT"); body:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT")
  else
    body:SetPoint("TOPLEFT", DRAWER_INSET, -LIST_TOP); body:SetPoint("TOPRIGHT", -DRAWER_INSET, -LIST_TOP)
    head:SetPoint("TOPLEFT", body, "BOTTOMLEFT"); head:SetPoint("TOPRIGHT", body, "BOTTOMRIGHT")
  end
end

local function PlaceDrawer(d)
  local _, bottom, _, h = box:GetScaledRect()
  local above = select(4, UIParent:GetScaledRect()) - bottom - h
  local need = d:GetHeight() * box:GetEffectiveScale()
  local below = bottom >= need or (above < need and bottom >= above)
  local fit = math.min(1, (below and bottom or above) / need)
  if d:GetScale() ~= fit then
    d:SetScale(fit)
    Thin()
  end
  local p = Pixel(d)
  d:ClearAllPoints()
  if below then
    d:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, p)
    d:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, p)
  else
    d:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, -p)
    d:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", 0, -p)
  end
  if d.below ~= below then
    d.below = below
    LayoutDrawer(d, below)
  end
end

local function Place()
  local s = tonumber(LA.Setting("scale")) or 1
  if s <= 0 then s = 1 end
  local pt = LA.Setting("point")
  placed.s, placed.pt = LA.Setting("scale"), pt
  for _, f in ipairs({ box, hud }) do
    f:SetScale(s)
    f:ClearAllPoints()
    if type(pt) == "table" and tonumber(pt.x) and tonumber(pt.y) then
      f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pt.x / s, pt.y / s)
    else
      f:SetPoint("TOPLEFT", UIParent, "TOP", -W / 2, -DEFAULT_Y / s)
    end
  end
  Thin()
  if open then PlaceDrawer(open) end
end

local function DragStart(f)
  if LA.Setting("locked") then return end
  f.moved, f.dragging = true, true
  f:StartMoving()
end

local function DragStop(f)
  if not f.dragging then return end
  f.dragging = nil
  f:StopMovingOrSizing()
  local s = f:GetScale()
  LA.SetSetting("point", { x = f:GetLeft() * s, y = f:GetTop() * s })
end

local function Draggable(f)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:SetDontSavePosition(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", DragStart)
  f:SetScript("OnDragStop", DragStop)
  f:Hide()
end

local function PaintToggles()
  for _, b in pairs(toggles) do Paint(b.glyph, (b.held() or b:IsMouseOver() or pad.picked == b) and C.gold or C.grey) end
end

local function ApplyHover()
  local hot = box:IsMouseOver() or open ~= nil or pad.focused
  for _, f in ipairs(revealed) do f:SetShown(hot) end
  for _, f in ipairs(dimmed) do f:SetAlpha(hot and 1 or REST_ALPHA) end
end

local function Later() driver:Show() end

local function WatchHover(f)
  f:HookScript("OnEnter", ApplyHover)
  f:HookScript("OnLeave", Later)
end

local function CloseDrawer() if open then open:Hide() end end

local function OpenDrawer(d)
  if open and open ~= d then open:Hide() end
  open = d
  d.sync()
  PlaceDrawer(d)
  d:Show()
  PaintToggles()
  pad.Select(d.first)
end

local function ToggleDrawer(d) if open == d then CloseDrawer() else OpenDrawer(d) end end

local function DrawerHidden(d)
  d:Hide()
  if open ~= d then return end
  open = nil
  PaintToggles()
  Later()
end

local function SyncOptions()
  for _, r in ipairs(rows) do
    local on = LA.Setting(r.key) and true or false
    Set(r.pill.label, on and "On" or "Off")
    Tint(r.pill.label, on and C.bright or C.grey)
  end
  for _, sl in ipairs(sliders) do
    local v = tonumber(LA.Setting(sl.key))
    if not sl.held and sl.shown ~= v then
      sl.shown = v
      sl:SetValue(v)
      Set(sl.readout, sl.fmt(v))
    end
  end
end

local function Flip(key) LA.SetSetting(key, not LA.Setting(key)) end

local function TipShow(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText(self.tip, 1, 1, 1, 1, true)
  GameTooltip:Show()
end

local function TipHide() GameTooltip:Hide() end

local function Bare(parent, onClick, draw)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(GLYPH_BTN, GLYPH_BTN)
  b.glyph = draw(b)
  b.glyph:SetPoint("CENTER")
  b:SetScript("OnEnter", function(self) Paint(self.glyph, C.gold) end)
  b:SetScript("OnLeave", function(self) Paint(self.glyph, (self.held and self.held()) and C.gold or C.grey) end)
  b:SetScript("OnClick", onClick)
  return Selectable(b, pad.Badge)
end

local function DrawerButton(key, draw)
  local b = Bare(box, function() ToggleDrawer(drawers[key]) end, draw)
  b.held = function() return open ~= nil and open == drawers[key] end
  toggles[key] = b
  return b
end

local function Row(list, y, h, kind)
  local r = CreateFrame(kind or "Frame", nil, list)
  r:SetHeight(h)
  r:SetPoint("TOPLEFT", 0, -y)
  r:SetPoint("TOPRIGHT", 0, -y)
  return r
end

local function Label(r, text)
  local fs = Text(r, FONT, SIZE.option, C.text)
  fs:SetPoint("LEFT", ROW_INSET, 0)
  Set(fs, text)
  return fs
end

local function OptionRow(list, i, text, key)
  local r = Selectable(Row(list, (i - 1) * OPT_H, OPT_H, "Button"), pad.Label)
  Solid(r, "HIGHLIGHT", C.hover):SetAllPoints()
  r.label = Label(r, text)
  local pill = CreateFrame("Frame", nil, r)
  pill:SetSize(PILL_W, PILL_H)
  pill:SetPoint("RIGHT", -ROW_INSET, 0)
  Skin(pill, C.btn, C.btnEdge)
  pill.label = Text(pill, FONT, SIZE.option, C.grey)
  pill.label:SetPoint("CENTER")
  r.key, r.pill = key, pill
  r:SetScript("OnClick", function(self) Flip(self.key) end)
  rows[i] = r
end

local function Commit(sl, v)
  local lo, hi = sl:GetMinMaxValues()
  v = math.min(hi, math.max(lo, math.floor(v / sl.step + 0.5) * sl.step))
  if v ~= LA.Setting(sl.key) then LA.SetSetting(sl.key, v) end
end

local function Step(sl, dir) Commit(sl, sl:GetValue() + dir * sl.step) end

local function Stepper(sl, dir, angles)
  local b = CreateFrame("Button", nil, sl)
  b:SetSize(STEP_W, STEP_W)
  Skin(b, C.btn, C.btnEdge)
  Solid(b, "HIGHLIGHT", C.hover):SetAllPoints()
  Glyph(b, STEP_GLYPH, ICON.minus, C.text, angles):SetPoint("CENTER")
  b:SetScript("OnClick", function() Step(sl, dir) end)
  return b
end

local function SliderRow(list, i, label, key, lo, hi, step, fmt, tip)
  local r = Selectable(Row(list, (i - 1) * OPT_H, OPT_H), pad.Tint)
  r.tint = Solid(r, "BACKGROUND", C.hover)
  r.tint:SetAllPoints()
  r.tint:Hide()
  Label(r, label)
  local readout = Text(r, FONT, SIZE.option, C.value)
  readout:SetJustifyH("RIGHT")
  readout:SetWidth(READOUT_W)
  readout:SetPoint("RIGHT", -ROW_INSET, 0)
  local sl = CreateFrame("Slider", nil, r)
  sl:SetOrientation("HORIZONTAL")
  sl:SetSize(SLIDER_W, SLIDER_H)
  sl:SetPoint("RIGHT", readout, "LEFT", -(2 * SLIDER_GAP + STEP_W), 0)
  Stepper(sl, -1):SetPoint("RIGHT", sl, "LEFT", -SLIDER_GAP, 0)
  Stepper(sl, 1, PLUS):SetPoint("LEFT", sl, "RIGHT", SLIDER_GAP, 0)
  sl:EnableMouse(true)
  sl:SetMinMaxValues(lo, hi)
  sl:SetValueStep(step)
  sl:SetObeyStepOnDrag(true)
  local track = Solid(sl, "BACKGROUND", C.btnEdge)
  track:SetHeight(TRACK_H)
  track:SetPoint("LEFT"); track:SetPoint("RIGHT")
  sl:SetThumbTexture(WHITE)
  local thumb = sl:GetThumbTexture()
  thumb:SetDrawLayer("OVERLAY")
  thumb:SetSize(THUMB_W, THUMB_H)
  thumb:SetVertexColor(C.white[1], C.white[2], C.white[3], 1)
  local fill = Solid(sl, "ARTWORK", C.gold)
  fill:SetHeight(TRACK_H)
  fill:SetPoint("LEFT", track, "LEFT")
  fill:SetPoint("RIGHT", thumb, "CENTER")
  sl.key, sl.step, sl.fmt, sl.readout, sl.row = key, step, fmt, readout, r
  sl:SetScript("OnValueChanged", function(self, v) Set(self.readout, self.fmt(v)) end)
  sl:SetScript("OnMouseDown", function(self) self.held = true end)
  sl:SetScript("OnMouseUp", function(self)
    self.held = nil
    Commit(self, self:GetValue())
  end)
  if tip then
    r:EnableMouse(true)
    r.tip = tip
    r:SetScript("OnEnter", TipShow)
    r:SetScript("OnLeave", TipHide)
  end
  sliders[#sliders + 1] = sl
end

local function invitesText(v)
  v = math.floor(v + 0.5)
  return v == 0 and "No limit" or tostring(v)
end

local function scaleText(v) return math.floor(v * 100 + 0.5) .. "%" end

local function Drawer(key, name, title)
  local d = CreateFrame("Frame", name, box)
  d:EnableMouse(true)
  d:SetClampedToScreen(true)
  d:Hide()
  d:SetFrameLevel(box:GetFrameLevel() + DRAWER_LEVEL)
  Skin(d, C.bg, BORDER.neutral)
  tinsert(UISpecialFrames, name)
  d:SetScript("OnHide", DrawerHidden)
  d.head = CreateFrame("Frame", nil, d)
  d.head:SetHeight(HEAD_H)
  local t = Text(d.head, FONT, SIZE.title, C.value)
  t:SetPoint("LEFT", ROW_INSET, 0)
  Set(t, title)
  d.close = Bare(d.head, CloseDrawer, Icon(CLOSE_SIZE, ICON.minus, CROSS))
  d.close:SetPoint("RIGHT", 0, 0)
  d.body = CreateFrame("Frame", nil, d)
  d.back = toggles[key]
  drawers[key] = d
  return d
end

local function Fit(d, bodyH)
  d.body:SetHeight(bodyH)
  d:SetHeight(HEAD_TOP + HEAD_H + bodyH + DRAWER_BOTTOM)
end

local function BuildOptions()
  local d = Drawer("options", "LayerAnarchyOptions", "Options")
  local list = d.body
  for i, o in ipairs(OPTIONS) do OptionRow(list, i, o[1], o[2]) end
  SliderRow(list, #OPTIONS + 1, "Invites per hour", "invitesPerHour", 0, MAX_INVITES, 1, invitesText,
    "As host. Players report silences for invite spam; threshold unknown.")
  SliderRow(list, #OPTIONS + 2, "Scale", "scale", SCALE_MIN, SCALE_MAX, SCALE_STEP, scaleText)
  Fit(d, (#OPTIONS + 2) * OPT_H)
  d.sync, d.first = SyncOptions, rows[1]
end

local function Seconds(sec) return string.format("%.1fs", sec) end

local function DrawCell(fs, n, positive, text)
  Set(fs, n and (text or tostring(n)) or NONE)
  Tint(fs, (n or 0) == 0 and C.faint or positive or C.text)
end

local function DrawSeconds(fs, sec, positive) DrawCell(fs, sec, positive, sec and Seconds(sec)) end

local function DrawSwaps(cells, v)
  DrawCell(cells[1], v.swaps)
  DrawSeconds(cells[2], v.avg)
  DrawSeconds(cells[3], v.best, C.gold)
  DrawCell(cells[4], v.thisHour, nil, v.limit and v.thisHour .. "/" .. v.limit)
end

local function DrawInvites(cells, v)
  DrawCell(cells[1], v.taken)
  DrawCell(cells[2], v.same)
  DrawCell(cells[3], v.late)
end

local function DrawHosting(key)
  return function(cells, v)
    local h = v[key]
    DrawCell(cells[1], h.asked)
    DrawCell(cells[2], h.invited)
    DrawCell(cells[3], h.moved, C.green)
    DrawCell(cells[4], h.failed)
  end
end

local SWAPS = {
  { head = { "Count", "Avg", "Best", "Hour" } },
  { "Swaps", DrawSwaps },
  { head = { "Taken", "Same", "Late" } },
  { "Invites", DrawInvites },
}
local HOSTING = {
  { head = { "Asked", "Invited", "Moved", "Failed" } },
  { "Ground", DrawHosting("ground") },
  { "Flying", DrawHosting("flying") },
}

local function PickWindow(b) LA.SetSetting("statsWindow", b.value) end

local function Segment(head, right)
  local seg = CreateFrame("Frame", nil, head)
  Skin(seg, C.bg, BORDER.neutral)
  local x = SEG_INSET
  for i, w in ipairs(WINDOWS) do
    local b = Selectable(CreateFrame("Button", nil, seg), pad.Badge)
    b:SetSize(w[3], SEG_H - 2 * SEG_INSET)
    b:SetPoint("LEFT", x, 0)
    b.picked = Solid(b, "BACKGROUND", C.btn)
    b.picked:SetAllPoints()
    Solid(b, "HIGHLIGHT", C.hover):SetAllPoints()
    b.label = Text(b, NARROW, SIZE.seg, C.grey)
    b.label:SetPoint("CENTER")
    Set(b.label, w[1])
    b.value = w[2]
    b:SetScript("OnClick", PickWindow)
    segs[i] = b
    x = x + w[3]
  end
  seg:SetSize(x + SEG_INSET, SEG_H)
  seg:SetPoint("RIGHT", right, "LEFT", -SEG_GAP, 0)
end

local function Left(r, size, c, text)
  local fs = Text(r, NARROW, size, c)
  fs:SetPoint("LEFT", ROW_INSET, 0)
  Set(fs, text)
  return fs
end

local function Columns(r, size, c, n, wide)
  wide = wide or n
  local cells = {}
  for j = 1, n do
    local fs = Text(r, NARROW, size, c)
    fs:SetJustifyH("RIGHT")
    fs:SetWidth(COL_W)
    fs:SetPoint("RIGHT", -ROW_INSET - (wide - j) * COL_W, 0)
    cells[j] = fs
  end
  return cells
end

local function Header(body, y, names, wide, title)
  local r = Row(body, y, STAT_H)
  if title then Left(r, SIZE.caption, C.muted, title) end
  for j, fs in ipairs(Columns(r, SIZE.caption, C.muted, #names, wide)) do Set(fs, names[j]) end
end

local function BuildTable(body)
  Header(body, 0, COLUMNS, #COLUMNS, "Network")
  for i, n in ipairs(NETWORKS) do
    local r = Row(body, i * STAT_H, STAT_H)
    Left(r, SIZE.stat, C.note, n[2])
    r.id, r.cells = n[1], Columns(r, SIZE.stat, C.text, #COLUMNS)
    netRows[i] = r
  end
  return (#NETWORKS + 1) * STAT_H
end

local function GridRow(body, y, line, n)
  local r = Row(body, y, STAT_H)
  Left(r, SIZE.stat, C.note, line[1])
  r.cells, r.draw = Columns(r, SIZE.stat, C.text, n, GRID_COLUMNS), line[2]
  gridRows[#gridRows + 1] = r
end

local function Section(body, y, title, lines)
  local r = Row(body, y, SECTION_H)
  local fs = Text(r, NARROW, SIZE.caption, C.muted)
  fs:SetPoint("BOTTOMLEFT", ROW_INSET, SECTION_BASE)
  Set(fs, title)
  y = y + SECTION_H
  local n
  for _, line in ipairs(lines) do
    if line.head then
      n = #line.head
      Header(body, y, line.head, GRID_COLUMNS)
    else
      GridRow(body, y, line, n)
    end
    y = y + STAT_H
  end
  return y
end

local function SyncSegment()
  local window = LA.Setting("statsWindow")
  for _, b in ipairs(segs) do
    local on = b.value == window
    b.picked:SetShown(on)
    Tint(b.label, on and C.white or C.grey)
  end
end

local function SyncNetwork()
  SyncSegment()
  local stats = LA.Debug.Stats() or LA.Stats
  for _, r in ipairs(netRows) do
    local seen, talking, hosts = stats.Net(r.id)
    DrawCell(r.cells[1], seen)
    DrawCell(r.cells[2], talking)
    DrawCell(r.cells[3], hosts, C.gold)
  end
  local v = stats.View()
  for _, r in ipairs(gridRows) do r.draw(r.cells, v) end
  LA.WakeIn(RECHECK)
end

local function BuildNetwork()
  local d = Drawer("network", "LayerAnarchyNetwork", "Network")
  Segment(d.head, d.close)
  local y = BuildTable(d.body)
  y = Section(d.body, y, "YOUR SWAPS", SWAPS)
  Fit(d, Section(d.body, y, "HOSTING", HOSTING))
  d.sync, d.first = SyncNetwork, segs[1]
  d:SetScript("OnShow", function() LA.Stats.Watch(true) end)
  d:HookScript("OnHide", function() LA.Stats.Watch(false) end)
end

local function BuildNote()
  note = CreateFrame("Frame", nil, box)
  note:SetPoint("TOPLEFT", box.line2, "BOTTOMLEFT", 0, -NOTE_TOP)
  note:SetPoint("RIGHT", box, "RIGHT", -PAD, 0)
  note:SetHeight(1)
  note:Hide()
  note.back = box.swap
  local div = Solid(note, "ARTWORK", C.btn)
  div:SetPoint("TOPLEFT"); div:SetPoint("TOPRIGHT")
  hairs[#hairs + 1] = div
  note.text = Text(note, NARROW, SIZE.note, C.note)
  note.text:SetPoint("TOPLEFT", 0, -NOTE_TEXT_TOP)
  note.text:SetPoint("TOPRIGHT", 0, -NOTE_TEXT_TOP)
  note.text:SetHeight(NOTE_TEXT_H)
  note.button = Button(note, ANCHORED_W, ROW)
  note.button:SetScript("OnClick", function()
    local n = note.cur
    local onClick = n and n.button and n.button.onClick
    if onClick then onClick() end
  end)
end

local function BuildBox()
  box = CreateFrame("Frame", "LayerAnarchyBox", root)
  box:SetSize(W, BASE_H)
  Draggable(box)
  Skin(box, C.bg, BORDER.neutral)

  local mini = Bare(box, function()
    CloseDrawer()
    LA.SetSetting("minimized", true)
  end, Icon(MINI_SIZE, ICON.minus))
  mini:SetPoint("TOPRIGHT", -CORNER_X, CORNER_Y)
  local sep = Solid(box, "ARTWORK", BORDER.neutral)
  sep:SetSize(1, SEP_H)
  sep:SetPoint("RIGHT", mini, "LEFT", -SEP_GAP, 0)
  local cog = DrawerButton("options", Icon(COG_SIZE, ICON.cog))
  cog:SetPoint("RIGHT", sep, "LEFT", -SEP_GAP, 0)
  local bars = DrawerButton("network", Bars)
  bars:SetPoint("RIGHT", cog, "LEFT")
  revealed[1], revealed[2], revealed[3], dimmed[1] = bars, cog, sep, mini

  box.line1 = Text(box, FONT, SIZE.line1, C.gold)
  box.line1:SetPoint("TOPLEFT", PAD, -LINE1_TOP)
  box.line1:SetPoint("RIGHT", mini, "LEFT", -GLYPH_TEXT_GAP, 0)
  box.line1:SetHeight(LINE1_H)
  box.line2 = Text(box, NARROW, SIZE.line2, TONE.idle)
  box.line2:SetPoint("TOPLEFT", box.line1, "BOTTOMLEFT", 0, -LINE_GAP)
  box.line2:SetPoint("RIGHT", box, "RIGHT", -PAD, 0)
  box.line2:SetHeight(LINE2_H)

  local help = Button(box, HOST_W, ROW)
  help:SetPoint("BOTTOMLEFT", PAD, PAD)
  help:SetScript("OnClick", LA.ToggleHelp)

  local swap = Button(box, ANCHORED_W, ROW)
  swap:SetPoint("TOPLEFT", help, "TOPRIGHT", GAP, 0)
  swap:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -PAD, PAD)
  swap:SetScript("OnClick", function() LA.SwapClick() end)

  box.help, box.swap, box.mini = help, swap, mini
  BuildNote()
  for _, f in ipairs({ box, mini, cog, bars, help, swap, note.button }) do WatchHover(f) end
  ApplyHover()
end

local function NoticeHeight(hasText, hasButton)
  local h = NOTE_TEXT_TOP
  if hasText then h = h + NOTE_TEXT_H end
  if hasButton and hasText then h = h + NOTE_GAP end
  return h
end

local function ShapeNotice(hasText, hasButton)
  local h = NoticeHeight(hasText, hasButton)
  note.text:SetShown(hasText)
  note.button:SetShown(hasButton)
  if hasButton then
    note.button:ClearAllPoints()
    note.button:SetPoint("TOPLEFT", 0, -h)
    note.button:SetPoint("TOPRIGHT", 0, -h)
    h = h + ROW
  end
  local shown = hasText or hasButton
  note:SetHeight(h)
  note:SetShown(shown)
  box:SetHeight(BASE_H + (shown and h + NOTE_TOP or 0))
  if open then PlaceDrawer(open) end
end

local function DrawNotice(n)
  note.cur = n
  local text = n and n.text
  if text == "" then text = nil end
  local btn = n and n.button
  local shape = (text and 1 or 0) + (btn and 2 or 0)
  if shape ~= note.shape then
    note.shape = shape
    ShapeNotice(text ~= nil, btn ~= nil)
  end
  if text then
    Set(note.text, text)
    Tint(note.text, TONE[n.tone] or C.note)
  end
  if btn then
    Set(note.button.label, btn.text or "")
    Edge(note.button, NOTE_EDGE[n.tone] or C.btnEdge)
  end
end

local function DrawBox(v)
  Set(box.line1, v.label)
  Set(box.line2, v.status or "")
  Tint(box.line2, TONE[v.tone] or TONE.idle)
  Edge(box, BORDER[v.border] or BORDER.neutral)
  Set(box.help.label, v.help and "Host: On" or "Host: Off")
  Tint(box.help.label, v.help and C.bright or C.text)
  local swap = box.swap
  Set(swap.label, v.swapText or "Swap")
  local on = v.swapEnabled ~= false
  if swap.on ~= on then
    swap.on = on
    swap:SetEnabled(on)
    Tint(swap.label, on and C.text or C.dim)
  end
  DrawNotice(v.notice)
end

local function BuildHud()
  hud = Selectable(CreateFrame("Button", nil, root), pad.Badge)
  hud:SetSize(HUD_MIN_W, HUD_H)
  Draggable(hud)
  hud:SetScript("OnMouseDown", function(self) self.moved = nil end)
  hud:SetScript("OnClick", function(self)
    if not self.moved then LA.SetSetting("minimized", false) end
  end)
  box.back, hud.back = hud, box.mini
  Skin(hud, C.hudBg, BORDER.neutral)
  hud.glyph = Glyph(hud, HUD_GLYPH, ICON.layers, GLYPH.neutral)
  hud.glyph:SetPoint("LEFT", HUD_GLYPH_X, 0)
  hud.t1 = Text(hud, FONT, SIZE.hud, C.white)
  hud.t1:SetPoint("TOPLEFT", HUD_TEXT_X, -HUD_TEXT_TOP)
  hud.t2 = Text(hud, NARROW, SIZE.hud, TONE.idle)
  hud.t2:SetPoint("TOPLEFT", hud.t1, "BOTTOMLEFT", 0, -HUD_LINE_GAP)
end

local function FitHud()
  local w = math.max(hud.t1:GetUnboundedStringWidth(), hud.t2:GetUnboundedStringWidth())
  hud:SetWidth(math.max(HUD_MIN_W, math.ceil((HUD_TEXT_X + w + HUD_PAD_R) / HUD_WIDTH_STEP) * HUD_WIDTH_STEP))
end

local function DrawHud(v)
  local a = Set(hud.t1, v.label or "")
  local b = Set(hud.t2, v.status or "")
  if a or b then FitHud() end
  Tint(hud.t2, TONE[v.tone] or TONE.idle)
  local key = BORDER[v.border] and v.border or "neutral"
  Edge(hud, BORDER[key])
  Paint(hud.glyph, GLYPH[key])
end

function pad.Atlas() return InputIconTextureSetUtility.GetNormalActiveInputIconButtonTexture(GAMEPAD_FACE_BOTTOM) end

function pad.Icon() return CreateAtlasMarkup(pad.Atlas(), PAD_ICON, PAD_ICON) end

function pad.Label(b, on)
  local fs = b.label
  fs.prefix = on and pad.Icon() .. " "
  Set(fs, fs.text or "")
end

function pad.Badge(b, on)
  if not b.badge then
    if not on then return end
    b.badge = (b.glyph or b):CreateTexture(nil, "OVERLAY")
    b.badge:SetSize(PAD_BADGE, PAD_BADGE)
    b.badge:SetPoint("CENTER", b, "BOTTOMRIGHT")
  end
  if on then b.badge:SetAtlas(pad.Atlas()) end
  b.badge:SetShown(on)
end

function pad.Tint(b, on) b.tint:SetShown(on) end

function pad.Mark(b, on)
  if on then pad.picked = b elseif pad.picked == b then pad.picked = nil end
  b.mark(b, on)
end

function pad.Pick(b) LA.Try("pad", pad.Mark, b, true) end

function pad.Unpick(b) LA.Try("pad", pad.Mark, b, false) end

function pad.Restricted()
  return InCombatLockdown() or C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Combat)
end

function pad.Select(b)
  pad.target = b
  Later()
end

function pad.Leave()
  pad.release = nil
  if not pad.listed then return end
  pad.listed = false
  if InputUtil.IsGamepadUIEnabled() then
    GamepadMode.FrameControlsManager:FrameHidden(root)
    SmartNavigation:RemovePanelInfo(root)
  end
  pad.focused = false
  if pad.picked then pad.Unpick(pad.picked) end
  ApplyHover()
end

function pad.Prepare()
  if pad.prepared then return end
  pad.prepared = true
  local function Stay(sl, dir)
    return function()
      LA.Try("pad", Step, sl, dir)
      return true
    end
  end
  for _, sl in ipairs(sliders) do
    SmartNavigation_MarkFrameFocusable(sl.row)
    SmartNavigation_MarkFrameIgnored(sl)
    SmartNavigation_AddJumpNavigationOverride(sl.row, SMART_NAV_INPUT_DIRECTION.LEFT, Stay(sl, -1))
    SmartNavigation_AddJumpNavigationOverride(sl.row, SMART_NAV_INPUT_DIRECTION.RIGHT, Stay(sl, 1))
  end
end

function pad.Fallback(f)
  while f and not f.back do f = f:GetParent() end
  return f and f.back
end

function pad.Sync()
  local target = pad.target
  pad.target = nil
  if not pad.listed then return end
  if pad.release or not (current and GamepadMode.FrameControlsManager.isUIFocused and InputUtil.IsGamepadUIEnabled()) then
    return pad.Leave()
  end
  local picked = pad.picked
  if picked and not picked:IsVisible() then target = target or pad.Fallback(picked) end
  if target and target:IsVisible() then SmartNavigation:SetTargetButtonForFrame(root, target) end
end

function pad.Cursor()
  if not ConsolePort then return end
  local want = open ~= nil or note.button:IsVisible()
  if want == pad.cursor then return end
  -- starts unknown: ConsolePort saves its cursor frames, so the first pass clears one left by a reload
  pad.cursor = want
  if want then ConsolePort:AddInterfaceCursorFrame(box) else ConsolePort:RemoveInterfaceCursorFrame(box) end
end

function pad.Focused(on)
  pad.focused = on
  ApplyHover()
  Later()
end

function pad.Close()
  if open then return CloseDrawer() end
  pad.release = true
  Later()
end

function pad.OnRestriction(_, kind, state)
  if kind == Enum.AddOnRestrictionType.Combat and state == Enum.AddOnRestrictionState.Activating then pad.Leave() end
end

function pad.Print()
  local manager = GamepadMode.FrameControlsManager
  LA.Print(string.format("pad: gamepad UI %s · listed %s · focused %s · UI focus %s · windows %d · combat %s · ConsolePort %s",
    tostring(InputUtil.IsGamepadUIEnabled()), tostring(pad.listed), tostring(pad.focused), tostring(manager.isUIFocused),
    manager:GetShownFrameCount(), tostring(pad.Restricted()), tostring(pad.cursor)))
end

local function BuildRoot()
  root = CreateFrame("Frame", nil, UIParent)
  root:SetAllPoints()
  root.FocusGamepad = function() LA.Try("pad", pad.Focused, true) end
  root.UnfocusGamepad = function() LA.Try("pad", pad.Focused, false) end
  root.SmartNavigationCloseHandler = function()
    LA.Try("pad", pad.Close)
    return true
  end
  driver = CreateFrame("Frame")
  driver:Hide()
  driver:SetScript("OnUpdate", function(self)
    self:Hide()
    LA.Try("ui", ApplyHover)
    LA.Try("pad", pad.Sync)
    LA.Try("pad", pad.Cursor)
  end)
end

function UI.Refresh()
  if not box then return end
  if LA.Setting("scale") ~= placed.s or LA.Setting("point") ~= placed.pt then Place() end
  current = not LA.Setting("hidden") and (LA.Setting("minimized") and hud or box) or nil
  if current then
    local v = LA.View()
    if current == hud then DrawHud(v) else DrawBox(v) end
  end
  box:SetShown(current == box)
  hud:SetShown(current == hud)
  if open then open.sync() end
  Later()
end

-- listed only on request: a listed window takes the controller whenever another window closes
function UI.Focus()
  if pad.listed then return pad.Leave() end
  if not current or pad.Restricted() or not InputUtil.IsGamepadUIEnabled() then return end
  pad.Prepare()
  pad.listed = true
  -- as a popup it survives the game's HUD edit mode, which hides the other listed windows
  GamepadMode.FrameControlsManager:FrameShown(root, true)
  pad.Select(current == hud and hud or box.swap)
end

function UI.SendKey() return InputUtil.IsGamepadUIEnabled() and pad.Icon() or "Enter" end

function UI.Init()
  if box then return end
  BuildRoot()
  BuildBox()
  BuildHud()
  BuildOptions()
  BuildNetwork()
  LA.On("UI_SCALE_CHANGED", Place)
  LA.On("DISPLAY_SIZE_CHANGED", Place)
  LA.On("PLAYER_REGEN_DISABLED", pad.Leave)
  LA.On("ADDON_RESTRICTION_STATE_CHANGED", pad.OnRestriction)
  LA.On("INPUT_DEVICE_INTERFACE_TRANSITION", LA.Refresh)
  EventRegistry:RegisterCallback("Gamepad.RefreshFrameFocus", Later, pad)
  LA.Command("diag pad", pad.Print)
  Place()
  UI.Refresh()
end

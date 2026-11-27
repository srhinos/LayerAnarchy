local _, LA = ...

local MapButton = {}
LA.MapButton = MapButton

local NAME = "LayerAnarchy"
local Icon = LibStub("LibDBIcon-1.0")

local LAUNCHER = {
  type = "launcher",
  label = "Layer Anarchy",
  icon = "Interface\\AddOns\\LayerAnarchy\\Media\\layers",
  OnClick = function() LayerAnarchy_Toggle() end,
  OnTooltipShow = function(tip)
    local v = LA.View()
    tip:AddLine("Layer Anarchy")
    tip:AddLine(v.status and (v.label .. " – " .. v.status) or v.label, 0.73, 0.73, 0.71)
  end,
}

local shown

function MapButton.Sync()
  local on = LA.Setting("minimap") and true or false
  if on == shown then return end
  shown = on
  local db = LA.db.minimap or {}
  LA.db.minimap, db.hide = db, not on
  if Icon:IsRegistered(NAME) then
    if on then Icon:Show(NAME) else Icon:Hide(NAME) end
  elseif on then
    -- broker displays like HidingBar list every launcher that exists, so it exists only once the button is wanted
    Icon:Register(NAME, LibStub("LibDataBroker-1.1"):NewDataObject(NAME, LAUNCHER), db)
  end
end

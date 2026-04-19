local ADDON_NAME, EH = ...

------------------------------------------------------------
-- Minimap button (3.3.5a safe; no LibDBIcon dependency)
------------------------------------------------------------
local BUTTON_NAME = "EpochHeadMinimapButton"
local ICON_TEX    = "Interface\\Icons\\INV_Misc_Map_01"

local function minimapDB()
  _G.epochheadDB = _G.epochheadDB or {}
  _G.epochheadDB.state = _G.epochheadDB.state or {}
  _G.epochheadDB.state.minimap = _G.epochheadDB.state.minimap or { angle = 180, hide = false }
  return _G.epochheadDB.state.minimap
end

local function positionMinimapButton(btn)
  local mm = minimapDB()
  local angle = math.rad(mm.angle or 180)
  local radius = 80
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function onDragUpdate(self)
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  local angle = math.deg(math.atan2(py - my, px - mx))
  minimapDB().angle = angle
  positionMinimapButton(self)
end

local function queueSize()
  return (_G.epochheadDB and _G.epochheadDB.events and #_G.epochheadDB.events) or 0
end

local function showTooltip(btn)
  if not GameTooltip then return end
  GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
  GameTooltip:AddLine("EpochHead", 0.6, 0.8, 1)
  GameTooltip:AddLine(("v%s"):format(tostring(EH.VERSION or "?")), 0.8, 0.8, 0.8)
  local st = (_G.epochheadDB and _G.epochheadDB.state) or {}
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Queued events", tostring(queueSize()), 1,1,1, 1,1,1)
  GameTooltip:AddDoubleLine("Collection", st.optedOut and "|cffff6666OFF|r" or "|cff66ff66ON|r", 1,1,1, 1,1,1)
  if st.droppedByRealm and st.droppedByRealm > 0 then
    GameTooltip:AddDoubleLine("Dropped (realm)", tostring(st.droppedByRealm), 1,1,1, 1,1,1)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Left-click: toggle options", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Right-click: toggle collection", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Shift-drag: move", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local optionsFrame

local function buildOptions()
  if optionsFrame then return optionsFrame end
  local f = CreateFrame("Frame", "EpochHeadOptionsFrame", UIParent)
  f:SetFrameStrata("DIALOG")
  f:SetWidth(340); f:SetHeight(220)
  f:SetPoint("CENTER")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop",  f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
    tile=true, tileSize=32, edgeSize=32,
    insets={ left=11, right=11, top=11, bottom=11 },
  })

  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -16)
  title:SetText("EpochHead Options")

  local ver = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ver:SetPoint("TOP", title, "BOTTOM", 0, -4)
  ver:SetText(("v%s  |  schema %d"):format(tostring(EH.VERSION or "?"), tonumber(EH.SCHEMA_VERSION or 0)))

  local optin = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  optin:SetPoint("TOPLEFT", 20, -60)
  _G[optin:GetName() and optin:GetName().."Text" or ""] = _G[optin:GetName() and optin:GetName().."Text" or ""]
  optin.text = optin:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  optin.text:SetPoint("LEFT", optin, "RIGHT", 4, 0)
  optin.text:SetText("Enable data collection")
  optin:SetScript("OnShow", function(self)
    local st = _G.epochheadDB and _G.epochheadDB.state or {}
    self:SetChecked(not st.optedOut)
  end)
  optin:SetScript("OnClick", function(self)
    _G.epochheadDB.state = _G.epochheadDB.state or {}
    _G.epochheadDB.state.optedOut = not self:GetChecked()
  end)

  local debug = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  debug:SetPoint("TOPLEFT", 20, -90)
  debug.text = debug:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  debug.text:SetPoint("LEFT", debug, "RIGHT", 4, 0)
  debug.text:SetText("Debug chat logging")
  debug:SetScript("OnShow", function(self) self:SetChecked(EH._debug and true or false) end)
  debug:SetScript("OnClick", function(self) EH._debug = self:GetChecked() and true or false end)

  local hideBtn = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  hideBtn:SetPoint("TOPLEFT", 20, -120)
  hideBtn.text = hideBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  hideBtn.text:SetPoint("LEFT", hideBtn, "RIGHT", 4, 0)
  hideBtn.text:SetText("Hide minimap button")
  hideBtn:SetScript("OnShow", function(self) self:SetChecked(minimapDB().hide and true or false) end)
  hideBtn:SetScript("OnClick", function(self)
    minimapDB().hide = self:GetChecked() and true or false
    if EH._minimapButton then
      if minimapDB().hide then EH._minimapButton:Hide() else EH._minimapButton:Show() end
    end
  end)

  local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  close:SetWidth(80); close:SetHeight(22)
  close:SetPoint("BOTTOM", 0, 16)
  close:SetText("Close")
  close:SetScript("OnClick", function() f:Hide() end)

  f:Hide()
  optionsFrame = f
  return f
end

function EH.ShowOptions()
  local f = buildOptions()
  if f:IsShown() then f:Hide() else f:Show() end
end

local function toggleCollection()
  _G.epochheadDB.state = _G.epochheadDB.state or {}
  _G.epochheadDB.state.optedOut = not _G.epochheadDB.state.optedOut
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[EpochHead]|r collection "
      .. (_G.epochheadDB.state.optedOut and "|cffff6666OFF|r" or "|cff66ff66ON|r"))
  end
end

local function buildMinimapButton()
  if EH._minimapButton then return EH._minimapButton end
  if not Minimap then return nil end

  local btn = CreateFrame("Button", BUTTON_NAME, Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetWidth(32); btn:SetHeight(32)
  btn:SetFrameLevel(8)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetMovable(true)

  local overlay = btn:CreateTexture(nil, "OVERLAY")
  overlay:SetWidth(54); overlay:SetHeight(54)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")

  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetTexture(ICON_TEX)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  btn:SetScript("OnEnter", showTooltip)
  btn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  btn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      toggleCollection()
    else
      EH.ShowOptions()
    end
  end)
  btn:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then
      self:SetScript("OnUpdate", onDragUpdate)
    end
  end)
  btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  positionMinimapButton(btn)
  if minimapDB().hide then btn:Hide() end
  EH._minimapButton = btn
  return btn
end

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("PLAYER_LOGIN")
  f:SetScript("OnEvent", function() buildMinimapButton() end)
end

local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Talent collector (mouseover driven).
--
-- Captures talent tooltip text when the player hovers talents and emits
-- one `talent_info` event per unique talent/rank per session.
------------------------------------------------------------

local sent = {}

local function now() return (EH.now and EH.now()) or time() end

local scanner
local function getScanner()
  if scanner then return scanner end
  if not CreateFrame then return nil end
  scanner = CreateFrame("GameTooltip", "EpochHeadTalentScanner", UIParent, "GameTooltipTemplate")
  scanner:SetOwner(UIParent, "ANCHOR_NONE")
  return scanner
end

local function scrapeTalentTooltip(tabIndex, talentIndex)
  local tt = getScanner()
  if not tt or not tt.SetTalent then return nil end
  tt:ClearLines()
  local ok = pcall(function() tt:SetTalent(tabIndex, talentIndex) end)
  if not ok then return nil end

  local lines = {}
  local n = tt:NumLines() or 0
  for i = 1, n do
    local fs = _G["EpochHeadTalentScannerTextLeft" .. i]
    local txt = fs and fs.GetText and fs:GetText() or nil
    if txt and txt ~= "" then
      lines[#lines + 1] = txt
    end
  end
  if #lines == 0 then return nil end
  return lines
end

local function parseTalentIdFromLink(tabIndex, talentIndex)
  if not GetTalentLink then return nil end
  local ok, link = pcall(GetTalentLink, tabIndex, talentIndex)
  if not ok or type(link) ~= "string" then return nil end
  local tid = link:match("talent:(%d+)")
  return tid and tonumber(tid) or nil
end

local function noteTalent(tabIndex, talentIndex, sourceHint)
  if not GetTalentInfo then return end
  if not tabIndex or not talentIndex then return end

  local name, icon, tier, column, currentRank, maxRank = GetTalentInfo(tabIndex, talentIndex)
  if not name then return end

  local key = table.concat({ tostring(tabIndex), tostring(talentIndex), tostring(currentRank or 0) }, ":")
  if sent[key] then return end
  sent[key] = true

  local tabName = GetTalentTabInfo and select(1, GetTalentTabInfo(tabIndex)) or nil
  local talentId = parseTalentIdFromLink(tabIndex, talentIndex)
  local tooltip = scrapeTalentTooltip(tabIndex, talentIndex)

  if EH.push then
    EH.push({
      type = "talent_info",
      t = now(),
      talent = {
        id = talentId,
        name = name,
        tab = tabName,
        tabIndex = tabIndex,
        talentIndex = talentIndex,
        icon = icon,
        tier = tier,
        column = column,
        currentRank = currentRank,
        maxRank = maxRank,
        tooltip = tooltip,
      },
      observer = {
        class = UnitClass and select(2, UnitClass("player")) or nil,
        level = UnitLevel and UnitLevel("player") or nil,
      },
      sourceHint = sourceHint,
    })
  end
end

local function resolveTalentByName(name)
  if not name or name == "" then return nil, nil end
  if not GetNumTalentTabs or not GetNumTalents or not GetTalentInfo then return nil, nil end

  for tab = 1, (GetNumTalentTabs() or 0) do
    for idx = 1, (GetNumTalents(tab) or 0) do
      local tName = GetTalentInfo(tab, idx)
      if tName == name then
        return tab, idx
      end
    end
  end
  return nil, nil
end

local function onTooltipSetTalent(tip, tabIndex, talentIndex)
  -- Some clients pass tab/talent indexes directly to SetTalent hooks.
  if tabIndex and talentIndex then
    noteTalent(tabIndex, talentIndex, "mouseover")
    return
  end

  -- Fallback path: infer from the title line if indices are unavailable.
  local t1 = _G["GameTooltipTextLeft1"]
  local talentName = t1 and t1.GetText and t1:GetText() or nil
  local resolvedTab, resolvedTalent = resolveTalentByName(talentName)
  if resolvedTab and resolvedTalent then
    noteTalent(resolvedTab, resolvedTalent, "mouseover")
  end
end

if GameTooltip then
  local canHookScript = GameTooltip.HookScript and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetTalent")
  if canHookScript then
    GameTooltip:HookScript("OnTooltipSetTalent", onTooltipSetTalent)
  elseif hooksecurefunc and GameTooltip.SetTalent then
    hooksecurefunc(GameTooltip, "SetTalent", onTooltipSetTalent)
  end
end

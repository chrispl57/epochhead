local ADDON_NAME, EH = ...

local scanTip = CreateFrame and CreateFrame("GameTooltip","EpochHeadScanTip",nil,"GameTooltipTemplate") or nil
if scanTip then scanTip:SetOwner(UIParent, "ANCHOR_NONE") end

-- === GUID anti-dupe (5 min) ===
local ANTI_DUPE_WINDOW = 300  -- 5 minutes
Epoch_DropsData = Epoch_DropsData or {}
Epoch_DropsData.recentGuidHits = Epoch_DropsData.recentGuidHits or {}
local __recentGuidHits = Epoch_DropsData.recentGuidHits

local function shouldSkipGuid(guid)
    if not guid or guid == "" then return false end
    local now = time()
    local last = __recentGuidHits[guid]
    if last and (now - last) < ANTI_DUPE_WINDOW then
        return true
    end
    __recentGuidHits[guid] = now
    return false
end

local function collectLootGuids()
    local seen = {}
    local n = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, n do
        -- GetLootSourceInfo returns a vararg list: guid1, qty1, guid2, qty2, ...
        local src = {GetLootSourceInfo(slot)}
        for i = 1, #src, 2 do
            local g = src[i]
            if g then seen[g] = true end
        end
    end
    -- Return as an array
    local arr, i = {}, 1
    for g,_ in pairs(seen) do
        arr[i] = g
        i = i + 1
    end
    return arr
end
-- === /GUID anti-dupe ===


function EH.ParseTooltipExtras(link)
  if not scanTip or not link or not scanTip.SetHyperlink then return nil end
  scanTip:ClearLines()
  scanTip:SetHyperlink(link)
  local extras = { bindType=nil, requires={}, effects={}, setBonuses={} }
  local function gtxt(i) local fs=_G["EpochHeadScanTipTextLeft"..i]; return fs and fs:GetText() or nil end
  for i=2, 20 do
    local t = gtxt(i); if not t then break end
    t = t:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")
    local tl = t:lower()
    if tl:find("binds when equipped") then extras.bindType="BoE"
    elseif tl:find("binds when picked up") then extras.bindType="BoP"
    elseif tl:find("binds when use") or tl:find("binds when used") then extras.bindType="BoU" end
    local lvl = tl:match("requires level (%d+)"); if lvl then extras.requires.level=tonumber(lvl) end
    local sk, sklv = t:match("Requires ([%a%s]+) %((%d+)%)"); if sk then extras.requires.skill=sk; extras.requires.skillLevel=tonumber(sklv) end
    if t:find("^Use:") then table.insert(extras.effects, {type="use", text=t:gsub("^Use:%s*","")}) end
    if t:find("^Equip:") then table.insert(extras.effects, {type="equip", text=t:gsub("^Equip:%s*","")}) end
    if t:find("^Set:") or t:find("^Set %d+:") then table.insert(extras.setBonuses, t) end
  end
  return extras
end

function EH.EnrichItemInfo(link, qualityFallback)
  if not link or not GetItemInfo then return nil end
  local name, ilink, quality, iLevel, reqLevel, class, subclass, maxStack, equipLoc, icon, sellPrice, classID, subclassID = GetItemInfo(link)
  quality = quality or qualityFallback
  local extras = EH.ParseTooltipExtras(ilink or link)
  return {
    name = name, quality = quality, itemLevel = iLevel, reqLevel = reqLevel,
    class = class, subclass = subclass, equipLoc = equipLoc, maxStack = maxStack,
    sellPrice = sellPrice, classID = classID, subclassID = subclassID, icon = icon,
    extras = extras
  }
end

EH.lastTooltipTitle = nil
local function tooltipRecord()
  local t1 = _G["GameTooltipTextLeft1"]
  if t1 then
    local txt = t1:GetText()
    if txt and txt ~= "" then EH.lastTooltipTitle = txt end
  end
end
-- Deduplicate tooltip logs per item ID for the current session
local seenTooltipItems = {}

local function logItemTooltip(tip)
  local name, link = tip:GetItem()
  if not link or not EH or not EH.push then return end
  local entry = EH.BuildItemEntry and EH.BuildItemEntry(link, name, 1, nil) or { name = name }
  local iid = entry and entry.id
  if iid and seenTooltipItems[iid] then return end
  if iid then seenTooltipItems[iid] = true end
  EH.push({
    type = "item_info",
    t = EH.now and EH.now() or time(),
    item = entry,
  })
end

if GameTooltip and GameTooltip.HookScript then
  GameTooltip:HookScript("OnShow", tooltipRecord)
  GameTooltip:HookScript("OnTooltipSetItem", tooltipRecord)
  GameTooltip:HookScript("OnUpdate", tooltipRecord)
  GameTooltip:HookScript("OnTooltipSetItem", logItemTooltip)
end

if ItemRefTooltip and ItemRefTooltip.HookScript then
  ItemRefTooltip:HookScript("OnTooltipSetItem", logItemTooltip)
end

local ADDON_NAME, EH = ...

local scanTip = CreateFrame and CreateFrame("GameTooltip","EpochHeadScanTip",nil,"GameTooltipTemplate") or nil
if scanTip then scanTip:SetOwner(UIParent, "ANCHOR_NONE") end

function EH.ParseTooltipExtras(link)
  if not scanTip or not link then return nil end
  scanTip:ClearLines()
  local ok = EH.SetTooltipFromLink and EH.SetTooltipFromLink(scanTip, link)
  if not ok then return nil end
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
-- Deduplicate tooltip logs per item ID across sessions, 7-day TTL.
local TOOLTIP_TTL = 7 * 24 * 3600

local function tooltipDB()
  _G.epochheadDB = _G.epochheadDB or {}
  _G.epochheadDB.seenTooltips = _G.epochheadDB.seenTooltips or {}
  return _G.epochheadDB.seenTooltips
end

local function tooltipSeenRecently(iid)
  if not iid then return false end
  local db = tooltipDB()
  local t  = db[iid]
  if not t then return false end
  local nowT = time()
  if (nowT - t) > TOOLTIP_TTL then
    db[iid] = nil
    return false
  end
  return true
end

local function markTooltipSeen(iid)
  if not iid then return end
  tooltipDB()[iid] = time()
end

local function logItemTooltip(tip)
  local name, link = tip:GetItem()
  if not link or not EH or not EH.push then return end
  local entry = EH.BuildItemEntry and EH.BuildItemEntry(link, name, 1, nil) or { name = name }
  local iid = entry and entry.id
  if tooltipSeenRecently(iid) then return end
  markTooltipSeen(iid)
  EH.push({
    type = "item_info",
    t = EH.now and EH.now() or time(),
    item = entry,
  })
end

-- Prune expired tooltip dedupe entries on login.
local function pruneTooltipDB()
  local db = tooltipDB()
  local nowT = time()
  local cutoff = nowT - TOOLTIP_TTL
  for iid, t in pairs(db) do
    if type(t) ~= "number" or t < cutoff then db[iid] = nil end
  end
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

local ttf = CreateFrame and CreateFrame("Frame") or nil
if ttf then
  ttf:RegisterEvent("PLAYER_LOGIN")
  ttf:SetScript("OnEvent", function() pruneTooltipDB() end)
end

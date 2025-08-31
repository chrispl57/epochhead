-- EpochHead events.lua — 3.3.5a-safe (UNIFIED, no QUEST_DETAIL)
-- - Robust kill counting (CLEU + loot fallback), 5m anti-dupe
-- - Rich mob source (level snapshot, classification, types, HP/Mana)
-- - Fishing detection (spell + CLEU + fallback), fishing loot events
-- - Mining/Herbalism node detection via loot window title (non-nil sourceKey)
-- - Fallback Mining inference from loot items if title is missing
-- - Loot attribution order: corpse GUID (mob) > gather > dead mouseover > recent kill > unknown
-- - Quest logging (accept/complete/turn-in) WITHOUT QUEST_DETAIL
--   * NOW logs objectives + reward preview (items/xp/gold) on ACCEPT
-- - No per-event player blob (player only in meta)

local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

----------------------------------------------------------------
-- Safe fishing detector (namespaced) to avoid nil global calls
----------------------------------------------------------------
if not EH.IsFishingLootSafe then
  function EH.IsFishingLootSafe()
    if type(IsFishingLoot) == "function" then
      local ok, res = pcall(IsFishingLoot)
      if ok then return res and true or false end
    end
    return false
  end
end

------------------------------------------------------------
-- Logger
------------------------------------------------------------
local function log(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffEpochHead|r: " .. tostring(msg))
  end
end

------------------------------------------------------------
-- SavedVariables root (fallback queue)
------------------------------------------------------------
_G.epochheadDB = _G.epochheadDB or { events = {}, meta = {} }
if type(_G.epochheadDB.events) ~= "table" then _G.epochheadDB.events = {} end

------------------------------------------------------------
-- One-time meta stamping (player stored in meta only)
------------------------------------------------------------
local function CurrentPlayer()
  local name = UnitName("player") or "Unknown"
  local realm = GetRealmName() or ""
  local classLoc, class = UnitClass("player")
  local raceLoc,  race  = UnitRace("player")
  local faction          = UnitFactionGroup("player")
  local level            = UnitLevel("player") or 0
  return {
    name = name, realm = realm,
    class = class, className = classLoc,
    race = race,  raceName = raceLoc,
    faction = faction, level = level,
  }
end

local function StampMeta()
  _G.epochheadDB = _G.epochheadDB or { events = {}, meta = {} }
  _G.epochheadDB.events = _G.epochheadDB.events or {}
  _G.epochheadDB.meta   = _G.epochheadDB.meta   or {}
  local meta = _G.epochheadDB.meta

  local v, build, _date, iface = GetBuildInfo()
  meta.created       = meta.created or time()
  meta.addon         = "epochhead"
  meta.version       = (EpochHead and EpochHead.VERSION) or "0.8.3"
  meta.clientVersion = v
  meta.clientBuild   = tostring(build)
  meta.interface     = iface
  meta.allowedRealms = meta.allowedRealms or (EpochHead and EpochHead.ALLOWED_REALMS) or {}
  meta.player        = CurrentPlayer()
end

------------------------------------------------------------
-- Queue (no per-event player field)
------------------------------------------------------------
local function detect_push()
  return function(ev)
    _G.epochheadDB = _G.epochheadDB or { events = {}, meta = {} }
    _G.epochheadDB.events = _G.epochheadDB.events or {}
    table.insert(_G.epochheadDB.events, ev)
    if EH and EH._debug then log("queued "..(ev.type or "?")) end
  end
end
local PUSH = detect_push()

------------------------------------------------------------
-- Session + debug
------------------------------------------------------------
local function now() return time() end
local function make_session()
  local p = UnitName("player") or "Player"
  local r = GetRealmName() or "Realm"
  return (p .. "-" .. r .. "-" .. tostring(now())):gsub("%s+", "")
end
EH.session = EH.session or make_session()
EH._debug  = EH._debug or false

-- Provide safe fallbacks if core didn’t define these helpers
if not EH.now then function EH.now() return now() end end
local function GetPlayerXY()
  if GetPlayerMapPosition then
    local x, y = GetPlayerMapPosition("player")
    if x and y then return x, y end
  end
  return 0, 0
end
local function ZoneAndSubzone() return GetRealZoneText(), GetSubZoneText() end
if not EH.Pos then
  function EH.Pos()
    local z, s = ZoneAndSubzone()
    local x, y = GetPlayerXY()
    return z, s, x, y
  end
end

------------------------------------------------------------
-- Mob snapshot cache (for robust level capture)
------------------------------------------------------------
EH.mobSnap = EH.mobSnap or {}

local function UnitLevelSafe(unit)
  local lvl = UnitLevel and UnitLevel(unit) or nil
  if type(lvl) == "number" and lvl > 0 then return lvl end
  return nil
end

------------------------------------------------------------
-- Instance
------------------------------------------------------------
local function GetInstanceInfoLite()
  if GetInstanceInfo then
    local name, _, difficultyIndex = GetInstanceInfo()
    return { name = name, difficultyIndex = difficultyIndex }
  end
  return nil
end

------------------------------------------------------------
-- GUID → mob id (heuristics for 3.3.5)
------------------------------------------------------------
local function GetMobIdFromGUID(guid)
  if not guid then return nil end
  local up = tostring(guid):gsub("^0x",""):upper()
  if #up < 12 then return nil end
  local midA = up:sub(9,14)
  local midB = up:sub(5,10)
  local nA = tonumber(midA, 16)
  local nB = tonumber(midB, 16)
  if nA and nA > 0 and nA < 200000 then return nA end
  if nB and nB > 0 and nB < 200000 then return nB end
  return nA or nB
end

------------------------------------------------------------
-- Tooltip scanner for items
------------------------------------------------------------
local ScanTip = CreateFrame("GameTooltip", "EpochHeadScanTip", UIParent, "GameTooltipTemplate")
ScanTip:SetOwner(UIParent, "ANCHOR_NONE")

local function TooltipLinesFromLink(link)
  local lines = {}
  if not link then return lines end
  ScanTip:ClearLines()
  local ok = pcall(ScanTip.SetHyperlink, ScanTip, link)
  if not ok then return lines end
  for i = 1, 30 do
    local fs = _G["EpochHeadScanTipTextLeft"..i]
    if fs then
      local t = fs:GetText()
      if t and t ~= "" then table.insert(lines, t) end
    end
  end
  return lines
end

local function ParseExtrasFromTooltip(lines)
  local extras = {
    bindType=nil, requires={}, effects={}, setBonuses={}, raw=lines,
    slotName=nil, armorType=nil, armor=nil,
    attrs={ str=nil, agi=nil, sta=nil, int=nil, spi=nil,
            crit=nil, hit=nil, haste=nil, ap=nil, sp=nil, mp5=nil, def=nil, block=nil },
    weapon={ min=nil, max=nil, speed=nil, dps=nil },
    shieldBlock=nil,
  }
  local function num(s) s = tostring(s or ""):gsub(",", ""); return tonumber(s) end
  for _, ln in ipairs(lines) do
    local l = tostring(ln or ""); local low = l:lower()
    if low:find("binds when picked up",1,true) then extras.bindType = extras.bindType or "BOP" end
    if low:find("binds when equipped",1,true) then extras.bindType = extras.bindType or "BOE" end
    if low:find("binds when used",1,true)     then extras.bindType = extras.bindType or "BOU" end
    if low:find("quest item",1,true)          then extras.bindType = extras.bindType or "QUEST" end
    if low:find("unique",1,true) and not low:find("equip:",1,true) then extras.bindType = extras.bindType or "UNIQUE" end

    if (l == "Head" or l == "Neck" or l == "Shoulder" or l == "Back" or l == "Chest" or
        l == "Wrist" or l == "Hands" or l == "Waist" or l == "Legs" or l == "Feet" or
        l == "Finger" or l == "Trinket" or l == "One-Hand" or l == "Two-Hand" or
        l == "Off Hand" or l == "Main Hand" or l == "Held In Off-hand" or
        l == "Shield" or l == "Ranged" or l == "Gun" or l == "Bow" or l == "Crossbow" or
        l == "Relic" or l == "Libram" or l == "Totem" or l == "Idol" or l == "Thrown") then
      extras.slotName = extras.slotName or l
    end
    if (l == "Cloth" or l == "Leather" or l == "Mail" or l == "Plate") then
      extras.armorType = extras.armorType or l
    end

    local a = l:match("(%d+)%s+[Aa]rmor")
    if a then extras.armor = extras.armor or num(a) end
    local sb = l:match("([%+%-]%d+)%s+[Bb]lock$")
    if sb then extras.shieldBlock = extras.shieldBlock or num(sb) end

    local v, stat = l:match("^([%+%-]%d+)%s+(%a+)")
    if v and stat then
      stat = stat:lower(); local val = num(v)
      if stat == "strength" or stat == "str" then extras.attrs.str = (extras.attrs.str or 0) + val end
      if stat == "agility"  or stat == "agi" then extras.attrs.agi = (extras.attrs.agi or 0) + val end
      if stat == "stamina"  or stat == "sta" then extras.attrs.sta = (extras.attrs.sta or 0) + val end
      if stat == "intellect"or stat == "int" then extras.attrs.int = (extras.attrs.int or 0) + val end
      if stat == "spirit"   or stat == "spi" then extras.attrs.spi = (extras.attrs.spi or 0) + val end
    end

    local crit = l:match("^([%+%-]%d+).-[Cc]ritical [Ss]trike")
    if crit then extras.attrs.crit = (extras.attrs.crit or 0) + num(crit) end
    local hitv = l:match("^([%+%-]%d+).-[Hh]it [Rr]ating")
    if hitv then extras.attrs.hit = (extras.attrs.hit or 0) + num(hitv) end
    local haste = l:match("^([%+%-]%d+).-[Hh]aste")
    if haste then extras.attrs.haste = (extras.attrs.haste or 0) + num(haste) end
    local ap = l:match("^([%+%-]%d+).-[Aa]ttack [Pp]ower")
    if ap then extras.attrs.ap = (extras.attrs.ap or 0) + num(ap) end
    local sp = l:match("^([%+%-]%d+).-[Ss]pell [Pp]ower")
    if sp then extras.attrs.sp = (extras.attrs.sp or 0) + num(sp) end
    local mp5 = l:match("^([%+%-]%d+).-[Mm][Pp]5")
    if mp5 then extras.attrs.mp5 = (extras.attrs.mp5 or 0) + num(mp5) end
    local def = l:match("^([%+%-]%d+).-[Dd]efense")
    if def then extras.attrs.def = (extras.attrs.def or 0) + num(def) end
    local blk = l:match("^([%+%-]%d+).-[Bb]lock [Rr]ating")
    if blk then extras.attrs.block = (extras.attrs.block or 0) + num(blk) end

    local dmin, dmax = l:match("(%d+)%s*%-%s*(%d+)%s+[Dd]amage")
    if dmin and dmax then extras.weapon.min = extras.weapon.min or num(dmin); extras.weapon.max = extras.weapon.max or num(dmax) end
    local dps = l:match("([%d%.]+)%s+[Dd]amage per second")
    if dps then extras.weapon.dps = extras.weapon.dps or tonumber(dps) end
    local spd = l:match("[Ss]peed%s*([%d%.]+)")
    if spd then extras.weapon.speed = extras.weapon.speed or tonumber(spd) end

    if low:find("^requires") then table.insert(extras.requires, l) end
    if low:find("^use:") or low:find("^equip:") or low:find("^chance on hit:") then table.insert(extras.effects, l) end
    if low:find("^set:") or low:find("^%(") then table.insert(extras.setBonuses, l) end
  end
  return extras
end

local function BuildItemEntry(link, nameFromLoot, qtyFromLoot, qualityFromLoot)
  local name, _, quality, itemLevel, reqLevel, className, subClassName,
        maxStack, equipLoc, icon, sellPrice = GetItemInfo(link or "")
  local lines  = TooltipLinesFromLink(link)
  local extras = ParseExtrasFromTooltip(lines)
  local iid = nil
  if link then iid = tonumber(tostring(link):match("item:(%d+)")) end
  return {
    id   = iid,
    name = name or nameFromLoot,
    qty  = qtyFromLoot or 1,
    rarity = quality or qualityFromLoot,
    info = {
      name      = name or nameFromLoot,
      quality   = quality or qualityFromLoot,
      itemLevel = itemLevel,
      reqLevel  = reqLevel,
      class     = className,
      subclass  = subClassName,
      equipLoc  = equipLoc,
      maxStack  = maxStack,
      sellPrice = sellPrice,
      icon      = icon,
      extras    = extras,
    }
  }
end

------------------------------------------------------------
-- Helpers so we don’t misread mob name as an item
------------------------------------------------------------
local function IsProbablyMobName(name)
  if not name or name == "" then return false end
  if UnitExists("target")    and name == UnitName("target")    then return true end
  if UnitExists("mouseover") and name == UnitName("mouseover") then return true end
  return false
end

------------------------------------------------------------
-- Snapshot + source builder for mobs
------------------------------------------------------------
function EH.snapshotUnit(unit)
  if not UnitExists(unit) then return end
  local guid = UnitGUID(unit); if not guid then return end
  local x, y = GetPlayerXY()
  EH.mobSnap[guid] = {
    guid = guid,
    id   = GetMobIdFromGUID(guid),
    name = UnitName(unit),
    level = UnitLevelSafe(unit), -- sanitized (nil for -1/0/unknown)
    classification = UnitClassification and UnitClassification(unit) or nil,
    creatureType   = UnitCreatureType and UnitCreatureType(unit) or nil,
    creatureFamily = UnitCreatureFamily and UnitCreatureFamily(unit) or nil,
    reaction       = UnitReaction and UnitReaction("player", unit) or nil,
    maxHp          = UnitHealthMax and UnitHealthMax(unit) or nil,
    maxMana        = UnitManaMax and UnitManaMax(unit) or nil,
    zone = GetRealZoneText(),
    subzone = GetSubZoneText(),
    x = x, y = y,
    t = now(),
  }
end

local function MobSourceFromUnit(unit)
  if not UnitExists(unit) then return nil end
  local g = UnitGUID(unit); if not g then return nil end
  local mid = GetMobIdFromGUID(g); if not mid then return nil end
  local x, y = GetPlayerXY()
  local lvl = UnitLevelSafe(unit) or (EH.mobSnap[g] and EH.mobSnap[g].level) or nil
  local src = {
    kind = "mob",
    id   = mid,
    guid = g,
    name = UnitName(unit),
    zone = GetRealZoneText(),
    subzone = GetSubZoneText(),
    x = x, y = y,
    level = lvl,
    classification = UnitClassification and UnitClassification(unit) or nil,
    creatureType   = UnitCreatureType and UnitCreatureType(unit) or nil,
    creatureFamily = UnitCreatureFamily and UnitCreatureFamily(unit) or nil,
    reaction       = UnitReaction and UnitReaction("player", unit) or nil,
    maxHp          = UnitHealthMax and UnitHealthMax(unit) or nil,
    maxMana        = UnitManaMax and UnitManaMax(unit) or nil,
  }
  return src, tostring(mid), g
end

------------------------------------------------------------
-- Kill + loot event builders (with dedupe)
------------------------------------------------------------
local lastMob = nil            -- { id, guid, name, zone, subzone, t, ... }
local lastDeadMouseover = nil  -- { id, guid, name, zone, subzone, t }
local lastLootTs = 0
local LOOT_DEDUPE_WINDOW = 3
local ATTRIB_WINDOW = 12 -- seconds to allow kill→loot attribution

-- 5 minute anti-dupe for kill credit by GUID
local KILL_DEDUPE = 300
local seenKillByGUID = {} -- guid -> ts
local function killSeenRecently(g) local t = seenKillByGUID[g]; return t and ((now() - t) < KILL_DEDUPE) end
local function markKill(g) if g then seenKillByGUID[g] = now() end end

-- 5 minute anti-dupe for LOOT by corpse GUID
local LOOT_CORPSE_DEDUPE = 300
local seenLootByGUID = {} -- guid -> ts
local function lootSeenRecently(g) local t = seenLootByGUID[g]; return t and ((now() - t) < LOOT_CORPSE_DEDUPE) end
local function markLoot(g) if g then seenLootByGUID[g] = now() end end

-- Mining/Herbalism (gather) scratch
EH._currentGather = nil  -- { gatherKind="Mining"/"Herbalism", nodeName, zone, subzone, x, y, sourceKey }

-- Classifier for gather node based on loot title
local function ClassifyGatherFromTitle(title)
  if not title or title == "" then return nil end
  local t = string.lower(title)
  if t:find("vein") or t:find("deposit") or t:find("ore") or t:find("lode") then
    return "Mining"
  end
  if t:find("herb") or t:find("bloom") or t:find("weed") or t:find("lotus")
     or t:find("gromsblood") or t:find("mageroyal") or t:find("peacebloom")
     or t:find("kingsblood") or t:find("dreamfoil") or t:find("goldthorn")
  then
    return "Herbalism"
  end
  return nil
end

-- Build gather sourceKey (colon-style similar to fishing)
local function BuildGatherKey(kind, zone, subzone, nodeName)
  local z = tostring(zone or "")
  local s = (subzone and subzone ~= "" and (":"..subzone)) or ""
  local n = tostring(nodeName or "Unknown Node")
  -- e.g., gather:mining:Elwynn Forest:Northshire:Copper Vein
  return string.format("gather:%s:%s%s:%s", string.lower(kind or "gather"), z, s, n)
end

local function PushKillEventFromSource(src)
  if not src or not src.id then return end
  local ev = {
    type = "kill",
    t = now(),
    session = EH.session,
    sourceKey = tostring(src.id),
    source = src,
    instance = GetInstanceInfoLite(),
  }
  PUSH(ev); if EH._debug then log("kill "..tostring(src.id)) end
end

-- Detect if the current loot window is tied to a corpse GUID.
local function DetectLootSourceGUID()
  if not GetLootSourceInfo then return nil end
  local num = GetNumLootItems() or 0
  for slot = 1, num do
    local guid = select(1, GetLootSourceInfo(slot))
    if guid then
      return guid
    end
  end
  return nil
end

-- Fishing loot emitter (namespaced, used by OnLootOpened)
if not EH.PushFishingLootEvent then
  function EH.PushFishingLootEvent(items, moneyCopper, zone, subzone, x, y)
    local src = {
      kind = "fishing", type = "fishing", name = "Fishing",
      zone = zone, subzone = subzone, x = x, y = y,
    }
    local skey = (EH.sourceKeyForFishing and EH.sourceKeyForFishing(zone, subzone))
                 or ("fishing:"..tostring(zone or "")..((subzone and subzone ~= "") and (":"..subzone) or ""))

    if (not skey or skey == "") then
      local looksFishing = false
      if EH and EH.IsFishingLootSafe and EH.IsFishingLootSafe() then looksFishing = true end
      if not looksFishing and EH and EH._fishingHitTS and (now() - EH._fishingHitTS) <= 15 then looksFishing = true end
      if looksFishing then
        local z = (EH._fishingLast and EH._fishingLast.z) or GetRealZoneText()
        local s = (EH._fishingLast and EH._fishingLast.s) or GetSubZoneText()
        skey = (EH.sourceKeyForFishing and EH.sourceKeyForFishing(z, s))
               or ("fishing:"..tostring(z or "")..((s and s ~= "") and (":"..s) or ""))
        if EH and EH._debug then log("fallback fishing srcKey="..tostring(skey)) end
      end
    end

    local ev = {
      type = "loot",
      t = now(),
      session = EH.session,
      source = src,
      sourceKey = skey,
      items = items,
      money = (moneyCopper and moneyCopper > 0) and { copper = moneyCopper } or nil,
      instance = GetInstanceInfoLite(),
    }
    PUSH(ev)
    if EH._debug then log(("fishing loot items=%d srcKey=%s"):format(#items, tostring(skey))) end
  end
end

-- Push a loot event with correct attribution precedence:
-- corpse GUID (mob) > gather > lastDeadMouseover > lastMob window > unknown
-- ctx = { isFishing=bool, isGather=bool }
local function PushLootEvent(items, moneyCopper, lootGUID, ctx)
  local src, sKey, g = nil, nil, lootGUID
  local hasCorpse = (g ~= nil)
  local isFish   = ctx and ctx.isFishing or false
  local isGather = ctx and ctx.isGather  or false

  -- If this loot is from a corpse (GUID present), we attribute to a MOB.
  if hasCorpse then
    local targetGUID  = (UnitExists("target")    and UnitGUID("target")) or nil
    local mouseGUID   = (UnitExists("mouseover") and UnitGUID("mouseover")) or nil
    local chosenUnit  = nil
    if targetGUID  == g then chosenUnit = "target"
    elseif mouseGUID == g then chosenUnit = "mouseover"
    end

    if chosenUnit then
      src, sKey = MobSourceFromUnit(chosenUnit)
    else
      local mid = GetMobIdFromGUID(g)
      local x, y = GetPlayerXY()
      src = {
        kind="mob", id=mid, guid=g, name=nil,
        zone=GetRealZoneText(), subzone=GetSubZoneText(), x=x, y=y,
      }
      sKey = mid and tostring(mid) or nil
    end
  end

  -- If no corpse GUID, prefer gather node (Mining/Herbalism) when detected.
  if (not hasCorpse) and (not src) and EH._currentGather then
    local x, y = GetPlayerXY()
    src = {
      kind       = "gather",
      gatherKind = EH._currentGather.gatherKind,
      nodeName   = EH._currentGather.nodeName,
      zone       = EH._currentGather.zone,
      subzone    = EH._currentGather.subzone,
      x = x, y = y,
    }
    sKey = EH._currentGather.sourceKey
  end

  -- Recently observed dead mouseover (only if still unknown and no corpse GUID)
  if (not hasCorpse) and (not src) and lastDeadMouseover and (now() - (lastDeadMouseover.t or 0) <= 3) then
    local x, y = GetPlayerXY()
    src = {
      kind="mob", id=lastDeadMouseover.id, guid=lastDeadMouseover.guid,
      name=lastDeadMouseover.name, zone=lastDeadMouseover.zone, subzone=lastDeadMouseover.subzone,
      x=x, y=y,
      level        = lastDeadMouseover.level,
      classification = lastDeadMouseover.classification,
      creatureType   = lastDeadMouseover.creatureType,
      creatureFamily = lastDeadMouseover.creatureFamily,
      reaction       = lastDeadMouseover.reaction,
      maxHp          = lastDeadMouseover.maxHp,
      maxMana        = lastDeadMouseover.maxMana,
    }
    sKey = tostring(lastDeadMouseover.id)
    g = lastDeadMouseover.guid
  end

  -- Recent kill fallback attribution (only if still unknown and no corpse GUID)
  if (not hasCorpse) and (not src) and lastMob and (now() - lastMob.t) <= ATTRIB_WINDOW then
    local x, y = GetPlayerXY()
    src = {
      kind="mob",
      id   = lastMob.id,
      guid = lastMob.guid,
      name = lastMob.name,
      zone = lastMob.zone or GetRealZoneText(),
      subzone = lastMob.subzone or GetSubZoneText(),
      x = x, y = y,
      level        = lastMob.level,
      classification = lastMob.classification,
      creatureType   = lastMob.creatureType,
      creatureFamily = lastMob.creatureFamily,
      reaction       = lastMob.reaction,
      maxHp          = lastMob.maxHp,
      maxMana        = lastMob.maxMana,
    }
    sKey = tostring(lastMob.id)
    g = lastMob.guid
  end

  -- 🎯 Kill credit:
  -- 1) Always when corpse GUID is present (mob corpse),
  -- 2) OR, when NO corpse GUID but it's clearly not fishing/gather AND we have a mob src+guid.
  local shouldCreditKill =
      (hasCorpse and src and src.kind == "mob" and g)
      or ((not hasCorpse) and (not isFish) and (not isGather) and src and src.kind == "mob" and g)

  if EH._debug then
    if shouldCreditKill then
      log(("kill credit via %s (corpse=%s gather=%s fish=%s) guid=%s")
        :format(hasCorpse and "corpse" or "loot-fallback",
                tostring(hasCorpse), tostring(isGather), tostring(isFish), tostring(g)))
    else
      log(("no kill credit (corpse=%s gather=%s fish=%s src=%s)")
        :format(tostring(hasCorpse), tostring(isGather), tostring(isFish), tostring(src and src.kind or "nil")))
    end
  end

  if shouldCreditKill and not killSeenRecently(g) then
    markKill(g)
    PushKillEventFromSource(src)
  end

  -- 5-minute LOOT de-dupe only for corpse GUIDs.
  if hasCorpse and lootSeenRecently(g) then
    if EH._debug then log("loot skipped (corpse GUID cooldown) guid="..tostring(g)) end
    return
  end

  -- Ensure a non-nil sourceKey (esp. for gather/unknown).
  if (not sKey) and EH._currentGather then
    sKey = EH._currentGather.sourceKey
  end
  if not sKey then
    local z, s = ZoneAndSubzone()
    sKey = "unknown:"..tostring(z or "")..((s and s ~= "") and (":"..s) or "")
  end

  local ev = {
    type = "loot",
    t = now(),
    session = EH.session,
    source = src or {},
    sourceKey = sKey,
    items = items,
    money = moneyCopper and { copper = moneyCopper } or nil,
    instance = GetInstanceInfoLite(),
  }

  if hasCorpse then markLoot(g) end

  PUSH(ev); if EH._debug then log("loot items="..tostring(#items).." srcKey="..tostring(sKey)) end
end

------------------------------------------------------------
-- CLEU reader and handler
------------------------------------------------------------
local function ReadCLEU(...)
  if CombatLogGetCurrentEventInfo then
    local _, subevent, _, srcGUID, srcName, _, _, dstGUID, dstName, _, _ = CombatLogGetCurrentEventInfo()
    return subevent, srcGUID, srcName, dstGUID, dstName
  else
    local _, subevent, _, srcGUID, srcName, _, _, dstGUID, dstName = ...
    return subevent, srcGUID, srcName, dstGUID, dstName
  end
end

local function OnCombatLogEvent(self, event, ...)
  local subevent, _srcGUID, _srcName, dstGUID, dstName = ReadCLEU(...)

  -- Fishing fallback via CLEU
  if subevent == "SPELL_CAST_SUCCESS" and CombatLogGetCurrentEventInfo then
    local _, se, _, srcGUID, srcName, _, _, _, _, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
    if srcGUID and UnitGUID and srcGUID == UnitGUID("player") then
      local fishName = (GetSpellInfo and GetSpellInfo(7732)) or "Fishing"
      if (spellId and (spellId == 7732 or spellId == 7620)) or (spellName == fishName) then
        local z,s,x,y = EH.Pos()
        EH._fishingHitTS = EH.now()
        EH._fishingLast  = { z=z, s=s, x=x, y=y }
        if EH._debug then log(("fishing CLEU OK (id=%s) @ %s:%s"):format(tostring(spellId or "?"), z or "?", s or "")) end
      end
    end
  end

  if subevent == "PARTY_KILL" or subevent == "UNIT_DIED" then
    local mid = GetMobIdFromGUID(dstGUID)
    if mid then
      local x, y = GetPlayerXY()
      lastMob = {
        id = mid, guid = dstGUID,
        name = dstName or ("Mob "..mid),
        zone = GetRealZoneText(),
        subzone = GetSubZoneText(),
        t = now(),
        level = (EH.mobSnap[dstGUID] and EH.mobSnap[dstGUID].level) or UnitLevelSafe("target"),
        classification = UnitClassification and UnitClassification("target") or nil,
        creatureType   = UnitCreatureType and UnitCreatureType("target") or nil,
        creatureFamily = UnitCreatureFamily and UnitCreatureFamily("target") or nil,
        reaction       = UnitReaction and UnitReaction("player","target") or nil,
        maxHp          = UnitHealthMax and UnitHealthMax("target") or nil,
        maxMana        = UnitManaMax and UnitManaMax("target") or nil,
        x = x, y = y,
      }

      if subevent == "PARTY_KILL" then
        if not killSeenRecently(dstGUID) then
          markKill(dstGUID)
          local src = nil
          if UnitExists("target") and UnitGUID("target") == dstGUID then
            src = select(1, MobSourceFromUnit("target"))
          end
          src = src or {
            kind="mob",
            id=mid, guid=dstGUID, name=lastMob.name,
            zone=lastMob.zone, subzone=lastMob.subzone, x=x, y=y,
            level        = lastMob.level,
            classification = lastMob.classification,
            creatureType   = lastMob.creatureType,
            creatureFamily = lastMob.creatureFamily,
            reaction       = lastMob.reaction,
            maxHp          = lastMob.maxHp,
            maxMana        = lastMob.maxMana,
          }
          PushKillEventFromSource(src)
        end
      end
    end
  end
end

-- Track dead mouseover (helps auto-loot attribution)
local function OnUpdateMouseover()
  if UnitExists("mouseover") and UnitIsDead("mouseover") then
    local g = UnitGUID("mouseover")
    if g then
      local mid = GetMobIdFromGUID(g)
      if mid then
        lastDeadMouseover = {
          id = mid, guid = g, name = UnitName("mouseover"),
          zone = GetRealZoneText(), subzone = GetSubZoneText(), t = now(),
          level        = (EH.mobSnap[g] and EH.mobSnap[g].level) or UnitLevelSafe("mouseover"),
          classification = UnitClassification and UnitClassification("mouseover") or nil,
          creatureType   = UnitCreatureType and UnitCreatureType("mouseover") or nil,
          creatureFamily = UnitCreatureFamily and UnitCreatureFamily("mouseover") or nil,
          reaction       = UnitReaction and UnitReaction("player","mouseover") or nil,
          maxHp          = UnitHealthMax and UnitHealthMax("mouseover") or nil,
          maxMana        = UnitManaMax and UnitManaMax("mouseover") or nil,
        }
      end
    end
  end
end

------------------------------------------------------------
-- Loot opened
------------------------------------------------------------
local function CoinFromName(name)
  if not name or name == "" then return 0 end
  local g = tonumber((name:match("(%d+)%s*Gold")   or "0")) or 0
  local s = tonumber((name:match("(%d+)%s*Silver") or "0")) or 0
  local c = tonumber((name:match("(%d+)%s*Copper") or "0")) or 0
  return g*10000 + s*100 + c
end

-- Fishing detection via spell: 7732 (Wrath) with 7620 fallback for some cores
local FISHING_SPELL_IDS = { [7732]=true, [7620]=true }
if not EH.OnSpellcastSucceeded then
  function EH.OnSpellcastSucceeded(unit, spell, rank, lineId, spellID)
    if unit ~= "player" then return end
    local isFishing = false
    if type(spellID) == "number" and FISHING_SPELL_IDS[spellID] then
      isFishing = true
    elseif spell then
      local fishName = (GetSpellInfo and GetSpellInfo(7732)) or "Fishing"
      if spell == fishName then isFishing = true end
    end
    if not isFishing then return end
    local z,s,x,y = EH.Pos()
    EH._fishingHitTS = EH.now()
    EH._fishingLast  = { z=z, s=s, x=x, y=y }
    if EH._debug then log(("fishing spell OK (id=%s) @ %s:%s"):format(tostring(spellID or "?"), z or "?", s or "")) end
  end
end

local function OnLootOpened()
  local ts = now()
  if (ts - lastLootTs) < LOOT_DEDUPE_WINDOW then return end
  lastLootTs = ts

  -- Early fishing attribution gate
  if EH._debug then
    local api = EH.IsFishingLootSafe()
    local recent = (EH._fishingHitTS and (now() - EH._fishingHitTS) <= 12) or false
    local delta = EH._fishingHitTS and (now() - EH._fishingHitTS) or -1
    log(("Fishing gate: api=%s recent=%s delta=%.1f"):format(tostring(api), tostring(recent), delta or -1))
  end

  local _isFishing = EH.IsFishingLootSafe()
  if not _isFishing then
    if EH._fishingHitTS and (now() - EH._fishingHitTS) <= 12 then _isFishing = true end
    if not _isFishing then
      local tgt = UnitName and UnitName("target") or nil
      if tgt and tostring(tgt):lower():find("fishing bobber", 1, true) then _isFishing = true end
      if not _isFishing and EH.lastTooltipTitle and tostring(EH.lastTooltipTitle):lower():find("fishing bobber", 1, true) then _isFishing = true end
    end
  end
  if _isFishing then
    local function _HasItem(slot)
      if type(LootSlotHasItem) == "function" then
        local ok, has = pcall(LootSlotHasItem, slot)
        if ok and has then return true end
      end
      if type(GetLootSlotLink) == "function" then
        local link = GetLootSlotLink(slot)
        if link and tostring(link):find("item:") then return true end
      end
      return false
    end

    local itemsF = {}
    local moneyCopperF = 0
    local numF = GetNumLootItems() or 0
    for slot = 1, numF do
      if _HasItem(slot) then
        local link = GetLootSlotLink(slot)
        local icon, name, qty, quality = GetLootSlotInfo(slot)
        local entry = BuildItemEntry(link, name, qty, quality)
        if entry and entry.id then itemsF[#itemsF+1] = entry end
      else
        local _, name = GetLootSlotInfo(slot)
        moneyCopperF = moneyCopperF + (CoinFromName(name) or 0)
      end
    end
    local z = (EH._fishingLast and EH._fishingLast.z) or GetRealZoneText()
    local s = (EH._fishingLast and EH._fishingLast.s) or GetSubZoneText()
    local px = (EH._fishingLast and EH._fishingLast.x) or select(3, EH.Pos())
    local py = (EH._fishingLast and EH._fishingLast.y) or select(4, EH.Pos())
    if EH.PushFishingLootEvent then
      EH.PushFishingLootEvent(itemsF, (moneyCopperF > 0) and moneyCopperF or nil, z, s, px, py)
      return
    end
  end

  -- Detect gather node from loot window title (before we build items)
  EH._currentGather = nil
  local nodeTitle = _G.LootFrameTitleText and _G.LootFrameTitleText.GetText and _G.LootFrameTitleText:GetText() or nil
  if nodeTitle and nodeTitle ~= "" then
    local kind = ClassifyGatherFromTitle(nodeTitle)
    if kind then
      local z, s = ZoneAndSubzone()
      local x, y = GetPlayerXY()
      EH._currentGather = {
        gatherKind = kind,          -- "Mining" / "Herbalism"
        nodeName   = nodeTitle,     -- e.g., "Copper Vein"
        zone       = z,
        subzone    = s,
        x = x, y = y,
        sourceKey  = BuildGatherKey(kind, z, s, nodeTitle),
      }
      if EH._debug then log(("gather detect: %s @ %s%s node='%s' -> %s")
        :format(kind, tostring(z or ""), (s and s ~= "" and (":"..s) or ""), nodeTitle, EH._currentGather.sourceKey)) end
    end
  end

  -- Build items/money from loot window
  local items = {}
  local moneyCopper = 0
  local num = GetNumLootItems() or 0

  for slot = 1, num do
    local link = (GetLootSlotLink and GetLootSlotLink(slot)) or nil
    if link and tostring(link):find("item:") then
      local _, name, qty, quality = GetLootSlotInfo(slot)
      if not IsProbablyMobName(name) then
        local entry = BuildItemEntry(link, name, qty, quality)
        if entry.id then table.insert(items, entry) end
      end
    else
      local _, nm = GetLootSlotInfo(slot)
      local copper = CoinFromName(nm)
      if copper and copper > 0 then moneyCopper = moneyCopper + copper end
    end
  end

  -- Fallback: infer Mining from loot items if title didn't yield a gather node
  if not EH._currentGather then
    local oreLike, total = 0, 0
    local firstOreName = nil

    local function looksLikeMiningItem(entry)
      if not entry or not entry.info then return false end
      local cls = tostring(entry.info.class or ""):lower()
      local sub = tostring(entry.info.subclass or ""):lower()
      local nm  = tostring(entry.name or ""):lower()
      if cls:find("trade") and (sub:find("metal") or sub:find("stone")) then return true end
      if nm:find(" ore") or nm:find(" bar") or nm:find(" stone") or nm:find(" dark iron") then return true end
      return false
    end

    for _, it in ipairs(items) do
      total = total + 1
      if looksLikeMiningItem(it) then
        oreLike = oreLike + 1
        if not firstOreName then firstOreName = it.name end
      end
    end

    if total > 0 and oreLike >= math.max(1, math.floor(total * 0.6)) then
      local z, s = ZoneAndSubzone()
      local x, y = GetPlayerXY()
      local inferredNode = firstOreName and (firstOreName .. " Node") or "Mining Node"
      EH._currentGather = {
        gatherKind = "Mining",
        nodeName   = inferredNode,
        zone       = z,
        subzone    = s,
        x = x, y = y,
        sourceKey  = BuildGatherKey("Mining", z, s, inferredNode),
      }
      if EH._debug then
        log(("gather infer: Mining by loot composition (%d/%d ore-like) -> %s")
          :format(oreLike, total, EH._currentGather.sourceKey))
      end
    end
  end

  -- Detect whether this loot window is tied to a corpse GUID.
  local corpseGUID = DetectLootSourceGUID()

  if #items > 0 or moneyCopper > 0 then
    PushLootEvent(
      items,
      (moneyCopper > 0) and moneyCopper or nil,
      corpseGUID,
      { isFishing = _isFishing, isGather = (EH._currentGather ~= nil) }
    )
  elseif EH._debug then
    log("loot opened but no items/coins found")
  end
end

------------------------------------------------------------
-- QUESTS (pickup: ID+text+objectives+rewards; turn-in: rewards/xp/money/receiver)
------------------------------------------------------------
local function QuestIDFromLink(link)
  -- e.g. |cffffff00|Hquest:12345:80|h[Title]|h|r
  local id = tostring(link or ""):match("Hquest:(%d+)")
  return id and tonumber(id) or nil
end

local function GetQuestIdFromLogIndex(idx)
  if not idx or not GetQuestLink then return nil end
  local lnk = GetQuestLink(idx)
  return QuestIDFromLink(lnk)
end

local function FindQuestIDByTitle(title)
  if not title or title == "" or not GetNumQuestLogEntries then return nil end
  local target = string.lower(title)
  for i = 1, GetNumQuestLogEntries() do
    local qTitle, _, _, _, isHeader = GetQuestLogTitle(i)
    if not isHeader and qTitle and string.lower(qTitle) == target then
      local id = GetQuestIdFromLogIndex(i)
      if id then return id end
    end
  end
end

local function BuildNPCFromUnit(unit)
  if not UnitExists or not UnitExists(unit) then return nil end
  local g = UnitGUID(unit)
  local id = g and GetMobIdFromGUID(g) or nil
  return { id = id, guid = g, name = UnitName(unit) }
end

-- simple safe call helper
local function safecall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c, d = pcall(fn, ...)
  if ok then return a, b, c, d end
  return nil
end

-- Try to fetch quest-log reward items/xp/gold at accept time
local function CaptureQuestLogRewards(questIndex)
  local items, choices = {}, {}

  local function qlItemLink(kind, i)
    if type(GetQuestLogItemLink) ~= "function" then return nil end
    local link = safecall(GetQuestLogItemLink, kind, i)
    if link then return link end
    if questIndex then
      link = safecall(GetQuestLogItemLink, questIndex, kind, i)
      if link then return link end
    end
    return nil
  end

  local nRewards = safecall(GetNumQuestLogRewards) or 0
  local nChoices = safecall(GetNumQuestLogChoices) or 0

  for i = 1, nRewards do
    local name, tex, numItems, quality = (safecall(GetQuestLogRewardInfo, i))
    if name then
      local link = qlItemLink("reward", i)
      local entry = BuildItemEntry(link, name, numItems, quality)
      table.insert(items, entry)
    end
  end
  for i = 1, nChoices do
    local name, tex, numItems, quality = (safecall(GetQuestLogChoiceInfo, i))
    if name then
      local link = qlItemLink("choice", i)
      local entry = BuildItemEntry(link, name, numItems, quality)
      table.insert(choices, entry)
    end
  end

  local xp    = safecall(GetQuestLogRewardXP)
  local money = safecall(GetQuestLogRewardMoney)

  return {
    items = (#items > 0) and items or nil,
    choiceItems = (#choices > 0) and choices or nil,
    xp = xp,
    money = (money and money > 0) and { copper = money } or nil,
  }
end

-- Pending quest state (no detail subtype)
EH._pendingQuestAccept = nil           -- { idx, ev, ts }
EH._pendingQuestRewards = nil          -- { items = {...}, choiceItems = {...}, ts }

-- Robust arg handling + id resolution
local function OnQuestAccepted(a1, a2)
  -- Common 3.3.5 shapes: (questIndex), (player, questIndex), (questIndex, questId)
  local questIndex, questId = nil, nil
  if type(a1) == "number" and type(a2) == "number" then
    questIndex, questId = a1, a2
  elseif type(a1) == "number" and a2 == nil then
    questIndex = a1
  elseif type(a1) == "string" and type(a2) == "number" then
    questIndex = a2
  end

  local title, description, objectives
  if questIndex and SelectQuestLogEntry then pcall(SelectQuestLogEntry, questIndex) end

  -- Title
  if GetQuestLogTitle then
    local ok, t = pcall(function()
      local r = { GetQuestLogTitle(questIndex) }
      return r[1]
    end)
    if ok then title = t end
  end

  -- Description + Objectives text
  if GetQuestLogQuestText then
    local ok, d, o = pcall(GetQuestLogQuestText)
    if ok then description = d; objectives = o end
  end

  local qid = questId or (questIndex and GetQuestIdFromLogIndex(questIndex)) or FindQuestIDByTitle(title)

  -- Rewards preview at accept time
  local preview = CaptureQuestLogRewards(questIndex)

  local x, y = GetPlayerXY()
  local ev = {
    type = "quest", subtype = "accept",
    t = now(), session = EH.session,
    id = qid, title = title, text = description, objectives = objectives,
    giver = BuildNPCFromUnit("target"),
    zone = GetRealZoneText(), subzone = GetSubZoneText(), x = x, y = y,
    rewardsPreview = preview, -- { items?, choiceItems?, xp?, money? }
  }

  if qid then
    PUSH(ev)
    EH._pendingQuestAccept = nil
  else
    EH._pendingQuestAccept = { idx = questIndex, ev = ev, ts = now() }
  end
end

local function OnQuestLogUpdate()
  local p = EH._pendingQuestAccept
  if not p then return end
  local qid = GetQuestIdFromLogIndex(p.idx)
  if qid then
    p.ev.id = qid
    PUSH(p.ev)
    EH._pendingQuestAccept = nil
  elseif (now() - (p.ts or 0)) > 12 then
    -- Optional: push without ID after timeout (disabled)
  end
end

-- Snapshot rewards when the turn-in frame is shown (before pressing Complete)
local function OnQuestComplete()
  local items, choices = {}, {}
  local function captureList(kind, count)
    for i = 1, (count or 0) do
      local link = GetQuestItemLink and GetQuestItemLink(kind, i) or nil
      local name, tex, numItems, quality = GetQuestItemInfo(kind, i)
      local entry = BuildItemEntry(link, name, numItems, quality)
      if entry and entry.id then
        if kind == "choice" then table.insert(choices, entry) else table.insert(items, entry) end
      end
    end
  end

  local nRewards = (GetNumQuestRewards and GetNumQuestRewards()) or 0
  local nChoices = (GetNumQuestChoices and GetNumQuestChoices()) or 0
  captureList("reward", nRewards)
  captureList("choice", nChoices)

  EH._pendingQuestRewards = { items = items, choiceItems = choices, ts = now() }
  if EH._debug then
    log(("quest complete: rewards=%d choices=%d"):format(#items, #choices))
  end
end

-- Finalize on server acknowledgement (has questID, xp, money)
local function OnQuestTurnedIn(questID, xpReward, moneyReward)
  local x, y = GetPlayerXY()
  local receiver = BuildNPCFromUnit("target")

  local rewards = EH._pendingQuestRewards or {}
  local ev = {
    type = "quest", subtype = "turnin",
    t = now(), session = EH.session,
    id = questID, title = nil,
    receiver = receiver,
    zone = GetRealZoneText(), subzone = GetSubZoneText(), x = x, y = y,
    xp = xpReward,
    money = (moneyReward and moneyReward > 0) and { copper = moneyReward } or nil,
    rewards = (next(rewards) and { items = rewards.items, choiceItems = rewards.choiceItems }) or nil,
  }

  PUSH(ev)
  EH._pendingQuestRewards = nil
end

------------------------------------------------------------
-- Frame & slash
------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("UNIT_LEVEL")
f:RegisterEvent("LOOT_OPENED")
f:RegisterEvent("LOOT_CLOSED")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

-- Quest events (no QUEST_DETAIL)
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("QUEST_COMPLETE")
f:RegisterEvent("QUEST_TURNED_IN")

f:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local addonName = ...
    if addonName and tostring(addonName):lower():find("epochhead") then
      StampMeta()
      log("loaded (session="..tostring(EH.session)..")")
    end

  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    OnCombatLogEvent(self, event, ...)

  elseif event == "UPDATE_MOUSEOVER_UNIT" then
    OnUpdateMouseover()
    if UnitExists("mouseover") then EH.snapshotUnit("mouseover") end

  elseif event == "PLAYER_TARGET_CHANGED" then
    if UnitExists("target") then EH.snapshotUnit("target") end

  elseif event == "UNIT_LEVEL" then
    local unit = ...
    if unit and UnitExists(unit) then EH.snapshotUnit(unit) end

  elseif event == "LOOT_OPENED" then
    OnLootOpened()

  elseif event == "LOOT_CLOSED" then
    EH._currentGather = nil

  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    EH.OnSpellcastSucceeded(...)

  -- Quests
  elseif event == "QUEST_ACCEPTED" then
    OnQuestAccepted(...)

  elseif event == "QUEST_LOG_UPDATE" then
    OnQuestLogUpdate()

  elseif event == "QUEST_COMPLETE" then
    OnQuestComplete()

  elseif event == "QUEST_TURNED_IN" then
    OnQuestTurnedIn(...)
  end
end)

SLASH_EPOCHHEAD1 = "/eh"
SlashCmdList["EPOCHHEAD"] = function(msg)
  msg = tostring(msg or ""):lower()
  if msg == "ping" or msg == "" then
    log("pong")
  elseif msg == "debug on" or msg == "debug 1" then
    EH._debug = true; log("debug ON")
  elseif msg == "debug off" or msg == "debug 0" then
    EH._debug = false; log("debug OFF")
  else
    log("commands: ping | debug on | debug off")
  end
end

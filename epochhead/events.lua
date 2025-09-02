-- EpochHead events.lua — 3.3.5a-safe (UNIFIED, no QUEST_DETAIL)
-- Version: 0.8.5
-- - Robust kill counting (CLEU + loot fallback), 5m anti-dupe
-- - Rich mob source (level snapshot, classification, types, HP/Mana)
-- - Fishing detection (spell + CLEU + fallback), fishing loot events
-- - Mining/Herbalism node detection via loot window title (non-nil sourceKey)
-- - Fallback Mining inference from loot items if title is missing (ONLY when no corpse GUID)
-- - Loot attribution order: corpse GUID (mob) > gather > dead mouseover > recent kill > unknown
-- - Quest logging (accept/complete/turn-in) WITHOUT QUEST_DETAIL, captures objectives/reward preview on ACCEPT
-- - Hardened: lazy tooltip init, slash aliases, pcall event dispatch, status/test commands
-- - Bugfixes:
--   * Locale-safe money parsing (uses GOLD_AMOUNT/SILVER_AMOUNT/COPPER_AMOUNT)
--   * Removed fragile "fishing bobber" string heuristic (keeps API + spell recency)
--   * Mob-ID heuristic ceiling removed (accept large IDs)
--   * Quest reward preview gates items without numeric ID
--   * LootSource GUID reader tolerates multi-source return formats
--   * Soft cap on event queue to prevent runaway growth

local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH
EH.VERSION   = "0.8.5"

------------------------------------------------------------
-- Logging helpers (never silent)
------------------------------------------------------------
local function chat(msg)
  msg = "|cff99ccffEpochHead|r: " .. tostring(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(msg) else print(msg) end
end
local function log(msg)
  if EH._debug then chat(msg) end
end
EH._lastError = nil
local function oops(where, err)
  EH._lastError = (where or "?") .. ": " .. tostring(err)
  chat("|cffff6666ERROR|r " .. EH._lastError)
end

------------------------------------------------------------
-- SavedVariables root (fallback queue)
------------------------------------------------------------
_G.epochheadDB = _G.epochheadDB or { events = {}, meta = {} }
if type(_G.epochheadDB.events) ~= "table" then _G.epochheadDB.events = {} end
local MAX_QUEUE = 50000

------------------------------------------------------------
-- Time + pos helpers
------------------------------------------------------------
local function now() return time() end
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
-- Player meta
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
  meta.version       = (EpochHead and EpochHead.VERSION) or EH.VERSION
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
    -- soft cap
    if #_G.epochheadDB.events >= MAX_QUEUE then
      table.remove(_G.epochheadDB.events, 1)
      chat(("queue full (%d); dropping oldest"):format(MAX_QUEUE))
    end
    table.insert(_G.epochheadDB.events, ev)
    log("queued " .. (ev.type or "?"))
  end
end
local PUSH = detect_push()

------------------------------------------------------------
-- Session + debug
------------------------------------------------------------
local function make_session()
  local p = UnitName("player") or "Player"
  local r = GetRealmName() or "Realm"
  return (p .. "-" .. r .. "-" .. tostring(now())):gsub("%s+", "")
end
EH.session = EH.session or make_session()
EH._debug  = EH._debug or false
EH._loadedPrinted = EH._loadedPrinted or false

------------------------------------------------------------
-- Snapshot / GUID utils
------------------------------------------------------------
EH.mobSnap = EH.mobSnap or {}

local function UnitLevelSafe(unit)
  local lvl = UnitLevel and UnitLevel(unit) or nil
  if type(lvl) == "number" and lvl > 0 then return lvl end
  return nil
end

local function GetInstanceInfoLite()
  if GetInstanceInfo then
    local name, _, difficultyIndex = GetInstanceInfo()
    return { name = name, difficultyIndex = difficultyIndex }
  end
  return nil
end

-- GUID → entry (NPC) id
local function GetMobIdFromGUID(guid)
  if not guid then return nil end
  local s = tostring(guid)

  -- Retail/modern hyphenated GUIDs: "Creature-0-*-*-*-<ID>-*"
  if s:find("-", 1, true) then
    local parts = { strsplit("-", s) }
    -- Most cores put the entry at index 6; fall back to 5 just in case.
    local id = tonumber(parts[6] or parts[5])
    if id and id > 0 then return id end
    return nil
  end

  -- 3.3.5 hex GUIDs, e.g. "0xF13000XXXXYYYYZZ"
  -- For Creature/Vehicle/Pet/GameObject high GUIDs (F1xx), the entry ID
  -- is the 6 hex digits at positions 5..10.
  local up = s:gsub("^0x", ""):upper()
  if #up < 10 then return nil end

  local high = up:sub(1,4)      -- e.g. F130 (Creature), F150 (Vehicle), F140 (Pet), F110 (GameObject)
  local idHex = up:sub(5,10)    -- 6 hex digits = entry id
  -- Only trust this path for the classic F1xx families
  if high:sub(1,2) == "F1" then
    local id = tonumber(idHex, 16)
    if id and id > 0 then return id end
  end

  -- Last-resort fallbacks (should rarely be hit)
  local nB = tonumber(up:sub(5,10), 16)
  if nB and nB > 0 then return nB end
  local nA = tonumber(up:sub(9,14), 16)
  if nA and nA > 0 then return nA end

  return nil
end

function EH.snapshotUnit(unit)
  if not UnitExists(unit) then return end
  local guid = UnitGUID(unit); if not guid then return end
  local x, y = GetPlayerXY()
  EH.mobSnap[guid] = {
    guid = guid,
    id   = GetMobIdFromGUID(guid),
    name = UnitName(unit),
    level = UnitLevelSafe(unit),
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
  local mid = GetMobIdFromGUID(g)
  local x, y = GetPlayerXY()
  local lvl = UnitLevelSafe(unit) or (EH.mobSnap[g] and EH.mobSnap[g].level) or nil
  local src = {
    kind = "mob",
    id   = mid,                -- may be nil; GUID still present
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
  return src, (mid and tostring(mid) or nil), g
end

------------------------------------------------------------
-- Tooltip (LAZY init so load never fails)
------------------------------------------------------------
local ScanTip = nil
local function EnsureScanTip()
  if ScanTip then return end
  local owner = UIParent or WorldFrame or nil
  local ok, tip = pcall(CreateFrame, "GameTooltip", "EpochHeadScanTip", owner, "GameTooltipTemplate")
  if ok and tip then
    ScanTip = tip
    if owner then ScanTip:SetOwner(owner, "ANCHOR_NONE") end
  else
    ScanTip = CreateFrame("GameTooltip", "EpochHeadScanTip", nil, "GameTooltipTemplate")
    ScanTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
  end
end

local function TooltipLinesFromLink(link)
  local lines = {}
  if not link then return lines end
  EnsureScanTip()
  if not ScanTip:GetOwner() then
    ScanTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
  end
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

    local a = l:match("(%d+)%s+[Aa]rmor") or l:match("[Aa]rmor%s*:?%s*(%d+)") or l:match("[Aa]rmor%s*(%d+)")
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
-- Don’t misread mob name as an item
------------------------------------------------------------
local function IsProbablyMobName(name)
  if not name or name == "" then return false end
  if UnitExists("target")    and name == UnitName("target")    then return true end
  if UnitExists("mouseover") and name == UnitName("mouseover") then return true end
  return false
end

------------------------------------------------------------
-- Kill + loot (dedupe + attribution)
------------------------------------------------------------
local lastMob = nil
local lastDeadMouseover = nil
local lastLootTs = 0
local LOOT_DEDUPE_WINDOW = 3
local ATTRIB_WINDOW = 12

local KILL_DEDUPE = 300
local seenKillByGUID = {}
local function killSeenRecently(g) local t = seenKillByGUID[g]; return t and ((now() - t) < KILL_DEDUPE) end
local function markKill(g) if g then seenKillByGUID[g] = now() end end

local LOOT_CORPSE_DEDUPE = 300
local seenLootByGUID = {}
local function lootSeenRecently(g) local t = seenLootByGUID[g]; return t and ((now() - t) < LOOT_CORPSE_DEDUPE) end
local function markLoot(g) if g then seenLootByGUID[g] = now() end end

EH._currentGather = nil

local function ClassifyGatherFromTitle(title)
  if not title or title == "" then return nil end
  local t = string.lower(title)
  if t:find("vein") or t:find("deposit") or t:find("ore") or t:find("lode") then return "Mining" end
  if t:find("herb") or t:find("bloom") or t:find("weed") or t:find("lotus")
     or t:find("gromsblood") or t:find("mageroyal") or t:find("peacebloom")
     or t:find("kingsblood") or t:find("dreamfoil") or t:find("goldthorn") then return "Herbalism" end
  return nil
end

local function BuildGatherKey(kind, zone, subzone, nodeName)
  local z = tostring(zone or "")
  local s = (subzone and subzone ~= "" and (":"..subzone)) or ""
  local n = tostring(nodeName or "Unknown Node")
  return string.format("gather:%s:%s%s:%s", string.lower(kind or "gather"), z, s, n)
end

local function PushKillEventFromSource(src)
  if not src then return end
  local key = src.id and tostring(src.id) or (src.guid and tostring(src.guid)) or nil
  if not key then return end
  PUSH({
    type = "kill", t = now(), session = EH.session,
    sourceKey = key, source = src, instance = GetInstanceInfoLite(),
  })
  log("kill " .. key)
end

-- Detect if the current loot window is tied to a corpse GUID.
local function DetectLootSourceGUID()
  if not GetLootSourceInfo then return nil end -- not on some 3.3.5 cores
  local num = GetNumLootItems() or 0
  for slot = 1, num do
    -- Retail-like format can return multiple GUID,count pairs
    local t = { GetLootSourceInfo(slot) }
    if #t >= 1 then
      for i = 1, #t, 2 do
        local guid = t[i]
        if guid then return guid end
      end
    end
  end
  return nil
end

-- Fishing detection (safe wrapper)
if not EH.IsFishingLootSafe then
  function EH.IsFishingLootSafe()
    if type(IsFishingLoot) == "function" then
      local ok, res = pcall(IsFishingLoot)
      if ok then return res and true or false end
    end
    return false
  end
end

-- Fishing loot emitter
if not EH.PushFishingLootEvent then
  function EH.PushFishingLootEvent(items, moneyCopper, zone, subzone, x, y)
    local src = { kind = "fishing", type = "fishing", name = "Fishing", zone = zone, subzone = subzone, x = x, y = y }
    local skey = (EH.sourceKeyForFishing and EH.sourceKeyForFishing(zone, subzone))
                 or ("fishing:"..tostring(zone or "")..((subzone and subzone ~= "") and (":"..subzone) or ""))
    PUSH({
      type="loot", t=now(), session=EH.session, source = src, sourceKey = skey,
      items = items, money = (moneyCopper and moneyCopper > 0) and { copper = moneyCopper } or nil,
      instance = GetInstanceInfoLite(),
    })
    log(("fishing loot items=%d srcKey=%s"):format(#items, tostring(skey)))
  end
end

local function PushLootEvent(items, moneyCopper, lootGUID, ctx)
  local src, sKey, g = nil, nil, lootGUID
  local hasCorpse = (g ~= nil)
  local isFish   = ctx and ctx.isFishing or false
  local isGather = ctx and ctx.isGather  or false

  if hasCorpse then
    local targetGUID  = (UnitExists("target")    and UnitGUID("target")) or nil
    local mouseGUID   = (UnitExists("mouseover") and UnitGUID("mouseover")) or nil
    local chosenUnit  = (targetGUID == g and "target") or (mouseGUID == g and "mouseover") or nil

    if chosenUnit then
      src, sKey = MobSourceFromUnit(chosenUnit)
    else
      local mid = GetMobIdFromGUID(g)
      local x, y = GetPlayerXY()
      src = { kind="mob", id=mid, guid=g, name=nil, zone=GetRealZoneText(), subzone=GetSubZoneText(), x=x, y=y }
      sKey = (mid and tostring(mid)) or nil
    end
  end

  if (not hasCorpse) and (not src) and EH._currentGather then
    local x, y = GetPlayerXY()
    src = {
      kind="gather", gatherKind = EH._currentGather.gatherKind, nodeName = EH._currentGather.nodeName,
      zone = EH._currentGather.zone, subzone = EH._currentGather.subzone, x=x, y=y,
    }
    sKey = EH._currentGather.sourceKey
  end

  if (not hasCorpse) and (not src) and lastDeadMouseover and (now() - (lastDeadMouseover.t or 0) <= 3) then
    local x, y = GetPlayerXY()
    src = {
      kind="mob", id=lastDeadMouseover.id, guid=lastDeadMouseover.guid, name=lastDeadMouseover.name,
      zone=lastDeadMouseover.zone, subzone=lastDeadMouseover.subzone, x=x, y=y,
      level=lastDeadMouseover.level, classification=lastDeadMouseover.classification,
      creatureType=lastDeadMouseover.creatureType, creatureFamily=lastDeadMouseover.creatureFamily,
      reaction=lastDeadMouseover.reaction, maxHp=lastDeadMouseover.maxHp, maxMana=lastDeadMouseover.maxMana,
    }
    sKey = tostring(lastDeadMouseover.id)
    g = lastDeadMouseover.guid
  end

  if (not hasCorpse) and (not src) and lastMob and (now() - lastMob.t) <= ATTRIB_WINDOW then
    local x, y = GetPlayerXY()
    src = {
      kind="mob", id=lastMob.id, guid=lastMob.guid, name=lastMob.name,
      zone=lastMob.zone or GetRealZoneText(), subzone=lastMob.subzone or GetSubZoneText(), x=x, y=y,
      level=lastMob.level, classification=lastMob.classification, creatureType=lastMob.creatureType,
      creatureFamily=lastMob.creatureFamily, reaction=lastMob.reaction,
      maxHp=lastMob.maxHp, maxMana=lastMob.maxMana,
    }
    sKey = tostring(lastMob.id)
    g = lastMob.guid
  end

  local shouldCreditKill =
      (hasCorpse and src and src.kind == "mob" and g)
      or ((not hasCorpse) and (not isFish) and (not isGather) and src and src.kind == "mob" and g)

  if shouldCreditKill and not killSeenRecently(g) then
    markKill(g)
    PushKillEventFromSource(src)
  end

  if hasCorpse and lootSeenRecently(g) then
    log("loot skipped (corpse GUID cooldown) guid="..tostring(g))
    return
  end

  if hasCorpse and (not sKey) and g then
    local mid = GetMobIdFromGUID(g)
    sKey = tostring(mid or g)
  end
  if (not sKey) and EH._currentGather then sKey = EH._currentGather.sourceKey end
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

  PUSH(ev)
  log("loot items="..tostring(#items).." srcKey="..tostring(sKey))
end

------------------------------------------------------------
-- CLEU + mouseover
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
        log(("fishing CLEU OK (id=%s) @ %s:%s"):format(tostring(spellId or "?"), z or "?", s or ""))
      end
    end
  end

  if subevent == "PARTY_KILL" or subevent == "UNIT_DIED" then
    local mid = GetMobIdFromGUID(dstGUID)
    if mid then
      local x, y = GetPlayerXY()
      lastMob = {
        id = mid, guid = dstGUID, name = dstName or ("Mob "..mid),
        zone = GetRealZoneText(), subzone = GetSubZoneText(), t = now(),
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
            level=lastMob.level, classification=lastMob.classification,
            creatureType=lastMob.creatureType, creatureFamily=lastMob.creatureFamily,
            reaction=lastMob.reaction, maxHp=lastMob.maxHp, maxMana=lastMob.maxMana,
          }
          PushKillEventFromSource(src)
        end
      end
    end
  end
end

local function OnUpdateMouseover()
  if UnitExists("mouseover") and UnitIsDead("mouseover") then
    local g = UnitGUID("mouseover")
    if g then
      local mid = GetMobIdFromGUID(g)
      if mid then
        lastDeadMouseover = {
          id = mid, guid = g, name = UnitName("mouseover"),
          zone = GetRealZoneText(), subzone = GetSubZoneText(), t = now(),
          level = (EH.mobSnap[g] and EH.mobSnap[g].level) or UnitLevelSafe("mouseover"),
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
    log(("fishing spell OK (id=%s) @ %s:%s"):format(tostring(spellID or "?"), z or "?", s or ""))
  end
end

-- Locale-safe coin parsing
local GOLD_RE   = (GOLD_AMOUNT or "%d Gold"):gsub("%%d", "(%%d+)")
local SILVER_RE = (SILVER_AMOUNT or "%d Silver"):gsub("%%d", "(%%d+)")
local COPPER_RE = (COPPER_AMOUNT or "%d Copper"):gsub("%%d", "(%%d+)")
local function CoinFromName(name)
  if not name or name == "" then return 0 end
  local g = tonumber((name:match(GOLD_RE)))   or 0
  local s = tonumber((name:match(SILVER_RE))) or 0
  local c = tonumber((name:match(COPPER_RE))) or 0
  return g*10000 + s*100 + c
end

local function OnLootOpened()
  local ts = now()
  if (ts - lastLootTs) < LOOT_DEDUPE_WINDOW then return end
  lastLootTs = ts

  -- Fishing determination: API + recent cast only (no fragile string checks)
  local _isFishing = EH.IsFishingLootSafe()
  if not _isFishing and EH._fishingHitTS and (now() - EH._fishingHitTS) <= 12 then
    _isFishing = true
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
    local itemsF, moneyCopperF, numF = {}, 0, GetNumLootItems() or 0
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
    EH.PushFishingLootEvent(itemsF, (moneyCopperF > 0) and moneyCopperF or nil, z, s, px, py)
    return
  end

  -- Detect gather node from loot window title
  EH._currentGather = nil
  local nodeTitle = _G.LootFrameTitleText and _G.LootFrameTitleText.GetText and _G.LootFrameTitleText:GetText() or nil
  if nodeTitle and nodeTitle ~= "" then
    local kind = ClassifyGatherFromTitle(nodeTitle)
    if kind then
      local z, s = ZoneAndSubzone()
      local x, y = GetPlayerXY()
      EH._currentGather = { gatherKind=kind, nodeName=nodeTitle, zone=z, subzone=s, x=x, y=y, sourceKey=BuildGatherKey(kind, z, s, nodeTitle) }
      log(("gather detect: %s @ %s%s node='%s' -> %s"):format(kind, tostring(z or ""), (s and s ~= "" and (":"..s) or ""), nodeTitle, EH._currentGather.sourceKey))
    end
  end

  -- Build items + coins
  local items, moneyCopper, num = {}, 0, GetNumLootItems() or 0
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

  local corpseGUID = DetectLootSourceGUID()

  -- Only infer Mining from loot items if NO corpse GUID and no explicit node title
  if (not EH._currentGather) and (corpseGUID == nil) then
    local oreLike, total, firstOreName = 0, 0, nil
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
      if looksLikeMiningItem(it) then oreLike = oreLike + 1; if not firstOreName then firstOreName = it.name end end
    end
    if total > 0 and oreLike >= math.max(1, math.floor(total * 0.6)) then
      local z, s = ZoneAndSubzone()
      local x, y = GetPlayerXY()
      local inferredNode = firstOreName and (firstOreName .. " Node") or "Mining Node"
      EH._currentGather = { gatherKind="Mining", nodeName=inferredNode, zone=z, subzone=s, x=x, y=y, sourceKey=BuildGatherKey("Mining", z, s, inferredNode) }
      log(("gather infer: Mining by loot composition (%d/%d) -> %s"):format(oreLike, total, EH._currentGather.sourceKey))
    end
  end

  if #items > 0 or moneyCopper > 0 then
    PushLootEvent(items, (moneyCopper > 0) and moneyCopper or nil, corpseGUID, { isFishing=_isFishing, isGather=(EH._currentGather ~= nil and corpseGUID == nil) })
  else
    log("loot opened but no items/coins found")
  end
end

------------------------------------------------------------
-- Quests (accept/log/turn-in)
------------------------------------------------------------
local function QuestIDFromLink(link) local id = tostring(link or ""):match("Hquest:(%d+)"); return id and tonumber(id) or nil end
local function GetQuestIdFromLogIndex(idx) if not idx or not GetQuestLink then return nil end; return QuestIDFromLink(GetQuestLink(idx)) end
local function FindQuestIDByTitle(title)
  if not title or title == "" or not GetNumQuestLogEntries then return nil end
  local target = string.lower(title)
  for i = 1, GetNumQuestLogEntries() do
    local qTitle, _, _, _, isHeader = GetQuestLogTitle(i)
    if not isHeader and qTitle and string.lower(qTitle) == target then
      local id = GetQuestIdFromLogIndex(i); if id then return id end
    end
  end
end
local function BuildNPCFromUnit(unit)
  if not UnitExists or not UnitExists(unit) then return nil end
  local g = UnitGUID(unit); local id = g and GetMobIdFromGUID(g) or nil
  return { id = id, guid = g, name = UnitName(unit) }
end
local function safecall(fn, ...) if type(fn) ~= "function" then return nil end; local ok, a,b,c,d = pcall(fn, ...); if ok then return a,b,c,d end end
local function CaptureQuestLogRewards(questIndex)
  local items, choices = {}, {}
  local function qlItemLink(kind, i)
    if type(GetQuestLogItemLink) ~= "function" then return nil end
    local link = safecall(GetQuestLogItemLink, kind, i); if link then return link end
    if questIndex then link = safecall(GetQuestLogItemLink, questIndex, kind, i); if link then return link end end
  end
  local nRewards = safecall(GetNumQuestLogRewards) or 0
  local nChoices = safecall(GetNumQuestLogChoices) or 0
  for i = 1, nRewards do
    local name, tex, numItems, quality = (safecall(GetQuestLogRewardInfo, i))
    if name then
      local entry = BuildItemEntry(qlItemLink("reward", i), name, numItems, quality)
      if entry and entry.id then table.insert(items, entry) end
    end
  end
  for i = 1, nChoices do
    local name, tex, numItems, quality = (safecall(GetQuestLogChoiceInfo, i))
    if name then
      local entry = BuildItemEntry(qlItemLink("choice", i), name, numItems, quality)
      if entry and entry.id then table.insert(choices, entry) end
    end
  end
  local xp    = safecall(GetQuestLogRewardXP)
  local money = safecall(GetQuestLogRewardMoney)
  return { items = (#items > 0) and items or nil, choiceItems = (#choices > 0) and choices or nil, xp = xp, money = (money and money > 0) and { copper = money } or nil }
end

EH._pendingQuestAccept, EH._pendingQuestRewards = nil, nil
local function OnQuestAccepted(a1, a2)
  local questIndex, questId = nil, nil
  if type(a1) == "number" and type(a2) == "number" then questIndex, questId = a1, a2
  elseif type(a1) == "number" and a2 == nil then questIndex = a1
  elseif type(a1) == "string" and type(a2) == "number" then questIndex = a2 end
  if questIndex and SelectQuestLogEntry then pcall(SelectQuestLogEntry, questIndex) end
  local title; if GetQuestLogTitle then local ok, t = pcall(function() local r = { GetQuestLogTitle(questIndex) } return r[1] end); if ok then title = t end end
  local description, objectives; if GetQuestLogQuestText then local ok, d,o = pcall(GetQuestLogQuestText); if ok then description, objectives = d,o end end
  local qid = questId or (questIndex and GetQuestIdFromLogIndex(questIndex)) or FindQuestIDByTitle(title)
  local x, y = GetPlayerXY()
  local ev = {
    type = "quest", subtype = "accept", t = now(), session = EH.session,
    id = qid, title = title, text = description, objectives = objectives,
    giver = BuildNPCFromUnit("target"), zone = GetRealZoneText(), subzone = GetSubZoneText(), x = x, y = y,
    rewardsPreview = CaptureQuestLogRewards(questIndex),
  }
  if qid then PUSH(ev); EH._pendingQuestAccept = nil else EH._pendingQuestAccept = { idx = questIndex, ev = ev, ts = now() } end
end
local function OnQuestLogUpdate()
  local p = EH._pendingQuestAccept; if not p then return end
  local qid = GetQuestIdFromLogIndex(p.idx)
  if qid then p.ev.id = qid; PUSH(p.ev); EH._pendingQuestAccept = nil
  elseif (now() - (p.ts or 0)) > 12 then end
end
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
  captureList("reward", nRewards); captureList("choice", nChoices)
  EH._pendingQuestRewards = { items = items, choiceItems = choices, ts = now() }
  log(("quest complete: rewards=%d choices=%d"):format(#items, #choices))
end
local function OnQuestTurnedIn(questID, xpReward, moneyReward)
  local x, y = GetPlayerXY()
  local receiver = BuildNPCFromUnit("target")
  local rewards = EH._pendingQuestRewards or {}
  PUSH({
    type = "quest", subtype = "turnin", t = now(), session = EH.session, id = questID, title = nil,
    receiver = receiver, zone = GetRealZoneText(), subzone = GetSubZoneText(), x = x, y = y,
    xp = xpReward, money = (moneyReward and moneyReward > 0) and { copper = moneyReward } or nil,
    rewards = (next(rewards) and { items = rewards.items, choiceItems = rewards.choiceItems }) or nil,
  })
  EH._pendingQuestRewards = nil
end

------------------------------------------------------------
-- Frame & safe event dispatch (no vararg misuse)
------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN") -- safety banner
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("UNIT_LEVEL")
f:RegisterEvent("LOOT_OPENED")
f:RegisterEvent("LOOT_CLOSED")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("QUEST_COMPLETE")
f:RegisterEvent("QUEST_TURNED_IN")

f:SetScript("OnEvent", function(self, event, ...)
  -- capture varargs up-front; DO NOT use "..." inside nested function
  local a1,a2,a3,a4,a5,a6,a7,a8,a9,a10 = ...

  local ok, err = pcall(function()
    if event == "ADDON_LOADED" then
      local addonName = a1
      if addonName and tostring(addonName):lower():find("epochhead") then
        StampMeta()
        if not EH._loadedPrinted then
          chat(("loaded v%s (session=%s)"):format(tostring(EH.VERSION), tostring(EH.session)))
          EH._loadedPrinted = true
        end
      end

    elseif event == "PLAYER_LOGIN" then
      if not EH._loadedPrinted then
        StampMeta()
        chat(("loaded v%s (session=%s)"):format(tostring(EH.VERSION), tostring(EH.session)))
        EH._loadedPrinted = true
      end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
      OnCombatLogEvent(self, event, a1,a2,a3,a4,a5,a6,a7,a8,a9,a10)

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
      OnUpdateMouseover()
      if UnitExists("mouseover") then EH.snapshotUnit("mouseover") end

    elseif event == "PLAYER_TARGET_CHANGED" then
      if UnitExists("target") then EH.snapshotUnit("target") end

    elseif event == "UNIT_LEVEL" then
      local unit = a1
      if unit and UnitExists(unit) then EH.snapshotUnit(unit) end

    elseif event == "LOOT_OPENED" then
      OnLootOpened()

    elseif event == "LOOT_CLOSED" then
      EH._currentGather = nil

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      EH.OnSpellcastSucceeded(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10)

    elseif event == "QUEST_ACCEPTED" then
      OnQuestAccepted(a1,a2)

    elseif event == "QUEST_LOG_UPDATE" then
      OnQuestLogUpdate()

    elseif event == "QUEST_COMPLETE" then
      OnQuestComplete()

    elseif event == "QUEST_TURNED_IN" then
      OnQuestTurnedIn(a1,a2,a3)
    end
  end)

  if not ok and err then
    oops(event, err)
  end
end)

------------------------------------------------------------
-- Slash commands: /eh, /epochhead
------------------------------------------------------------
SLASH_EPOCHHEAD1 = "/eh"
SLASH_EPOCHHEAD2 = "/epochhead"
SlashCmdList["EPOCHHEAD"] = function(msg)
  msg = tostring(msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "" or msg == "ping" then
    chat("pong")
  elseif msg == "debug on" or msg == "debug 1" or msg == "debug true" then
    EH._debug = true; chat("debug ON")
  elseif msg == "debug off" or msg == "debug 0" or msg == "debug false" then
    EH._debug = false; chat("debug OFF")
  elseif msg == "debug" or msg == "toggle" then
    EH._debug = not EH._debug; chat("debug " .. (EH._debug and "ON" or "OFF"))
  elseif msg == "status" then
    local q = _G.epochheadDB and _G.epochheadDB.events and #_G.epochheadDB.events or 0
    chat(("status v%s | queued=%d | lastError=%s"):format(EH.VERSION, q, EH._lastError or "none"))
  else
    chat("commands: ping | debug on/off | debug | status | test")
  end
end

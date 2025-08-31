-- EpochHead events.lua — 3.3.5a-safe (UNIFIED, no QUEST_DETAIL)
-- - Robust kill counting (CLEU + loot fallback), 5m anti-dupe
-- - Rich mob source (level snapshot, classification, types, HP/Mana)
-- - Fishing detection (spell + CLEU + fallback), fishing loot events
-- - Item tooltip "extras" parsing preserved for items.json
-- - Quest logging (reliably includes quest ID on 3.3.5a) — WITHOUT QUEST_DETAIL:
--     * QUEST_ACCEPTED  -> quest pickup (**with ID**, tolerant of arg shapes; retries via QUEST_LOG_UPDATE)
--     * QUEST_COMPLETE  -> capture reward lists (guaranteed & choices)
--     * QUEST_TURNED_IN -> quest turn-in (receiver + xp + money + rewards)
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
  meta.version       = (EpochHead and EpochHead.VERSION) or "0.8.2"
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
-- Coords
------------------------------------------------------------
local function GetPlayerXY()
  if GetPlayerMapPosition then
    local x, y = GetPlayerMapPosition("player")
    if x and y then return x, y end
  end
  return 0, 0
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

local function PushLootEvent(items, moneyCopper)
  local src, sKey, g = nil, nil, nil

  -- Prefer current corpse target/mouseover
  src, sKey, g = MobSourceFromUnit("target")
  if not src then src, sKey, g = MobSourceFromUnit("mouseover") end

  -- Recently observed dead mouseover
  if not src and lastDeadMouseover and (now() - (lastDeadMouseover.t or 0) <= 3) then
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

  -- Recent kill fallback attribution
  if not src and lastMob and (now() - lastMob.t) <= ATTRIB_WINDOW then
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

  -- Fallback kill credit via loot (once per GUID/5m)
  if src and g and not killSeenRecently(g) then
    markKill(g)
    PushKillEventFromSource(src)
  end

  local ev = {
    type = "loot",
    t = now(),
    session = EH.session,
    source = src or {},         -- {} if unknown
    sourceKey = sKey,           -- nil if unknown
    items = items,
    money = moneyCopper and { copper = moneyCopper } or nil,
    instance = GetInstanceInfoLite(),
  }
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

  if #items > 0 or moneyCopper > 0 then
    PushLootEvent(items, moneyCopper > 0 and moneyCopper or nil)
  elseif EH._debug then
    log("loot opened but no items/coins found")
  end
end

------------------------------------------------------------
-- QUESTS (pickup: ID+text; turn-in: rewards/xp/money/receiver)
------------------------------------------------------------
-- Helpers
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
  return {
    id   = id,
    guid = g,
    name = UnitName(unit),
  }
end

-- Pending quest state (no detail subtype)
EH._pendingQuestAccept = nil           -- { idx, ev, ts }
EH._pendingQuestRewards = nil          -- { items = {...}, choiceItems = {...}, ts }

-- Robust arg handling + id resolution
local function OnQuestAccepted(a1, a2)
  -- Handle common 3.3.5 shapes:
  --  (questIndex), (player, questIndex), (questIndex, questId)
  local questIndex, questId = nil, nil
  if type(a1) == "number" and type(a2) == "number" then
    questIndex, questId = a1, a2
  elseif type(a1) == "number" and a2 == nil then
    questIndex = a1
  elseif type(a1) == "string" and type(a2) == "number" then
    questIndex = a2
  end

  -- Title/text from log (safely)
  local title, text
  if questIndex and SelectQuestLogEntry then pcall(SelectQuestLogEntry, questIndex) end
  if GetQuestLogTitle then
    local ok, t = pcall(function()
      local r = { GetQuestLogTitle(questIndex) }
      return r[1]
    end)
    if ok then title = t end
  end
  if GetQuestLogQuestText then
    local ok, d = pcall(function() return select(1, GetQuestLogQuestText()) end)
    if ok then text = d end
  end

  -- Resolve numeric questId if not provided
  local qid = questId or (questIndex and GetQuestIdFromLogIndex(questIndex)) or FindQuestIDByTitle(title)

  local x, y = GetPlayerXY()
  local ev = {
    type = "quest", subtype = "accept",
    t = now(), session = EH.session,
    id = qid, title = title, text = text,
    giver = BuildNPCFromUnit("target"),
    zone = GetRealZoneText(), subzone = GetSubZoneText(), x = x, y = y,
  }

  if qid then
    PUSH(ev)
    EH._pendingQuestAccept = nil
  else
    -- Defer until the quest log link is ready; retry on QUEST_LOG_UPDATE
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
    -- Optional: push without ID after timeout (disabled by default)
  end
end

-- Snapshot rewards when the turn-in frame is shown (before pressing Complete)
local function OnQuestComplete()
  local items, choices = {}, {}
  local function captureList(kind, count)
    for i = 1, (count or 0) do
      local link = GetQuestItemLink(kind, i)
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
    id = questID, title = nil, -- title not provided here; server will merge by id if seen before
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
f:RegisterEvent("PLAYER_TARGET_CHANGED")      -- keep mob snapshots fresh
f:RegisterEvent("UNIT_LEVEL")                 -- refresh snapshot on level changes
f:RegisterEvent("LOOT_OPENED")
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

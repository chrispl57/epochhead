-- EpochHead events.lua — 3.3.5a-safe (UNIFIED)
-- Version: 0.9.30

local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH
EH.VERSION   = "0.9.30"

------------------------------------------------------------
-- Logging helpers
------------------------------------------------------------
local function chat(msg)
  msg = "|cff99ccffEpochHead|r: " .. tostring(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(msg) else print(msg) end
end
local function log(msg) if EH._debug then chat(msg) end end
EH._lastError = nil
local function oops(where, err)
  EH._lastError = (where or "?") .. ": " .. tostring(err)
  chat("|cffff6666ERROR|r " .. EH._lastError)
end
------------------------------------------------------------
-- SavedVariables root (event queue only; you aggregate offline)
------------------------------------------------------------
_G.epochheadDB = _G.epochheadDB or { events = {}, meta = {} }
if type(_G.epochheadDB.events) ~= "table" then _G.epochheadDB.events = {} end
local MAX_QUEUE = 50000

------------------------------------------------------------
-- Time + misc
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
-- Queue
------------------------------------------------------------
local function detect_push()
  return function(ev)
    _G.epochheadDB = _G.epochheadDB or { events = {}, meta = {} }
    _G.epochheadDB.events = _G.epochheadDB.events or {}
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
-- GUID utils
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

-- GUID → entry id
local function GetEntryIdFromGUID(guid)
  if not guid then return nil end
  local s = tostring(guid)
  if s:find("-", 1, true) then
    local parts = { strsplit("-", s) }
    local id = tonumber(parts[6] or parts[5])
    if id and id > 0 then return id end
    return nil
  end
  local up = s:gsub("^0x", ""):upper()
  if #up < 10 then return nil end
  local high = up:sub(1,4)
  local idHex = up:sub(5,10)
  if high:sub(1,2) == "F1" then
    local id = tonumber(idHex, 16)
    if id and id > 0 then return id end
  end
  local nB = tonumber(up:sub(5,10), 16)
  if nB and nB > 0 then return nB end
  local nA = tonumber(up:sub(9,14), 16)
  if nA and nA > 0 then return nA end
  return nil
end

local function GUIDKind(guid)
  if not guid then return nil end
  local s = tostring(guid)
  if s:find("-", 1, true) then
    local typ = (strsplit("-", s))
    return typ -- "Creature" / "GameObject" / etc
  end
  local up = s:gsub("^0x", ""):upper()
  local high = up:sub(1,4)
  if     high == "F130" then return "Creature"
  elseif high == "F110" then return "GameObject"
  elseif high == "F150" then return "Vehicle"
  elseif high == "F140" then return "Pet"
  else return "Unknown" end
end

function EH.snapshotUnit(unit)
  if not UnitExists(unit) then return end
  local guid = UnitGUID(unit); if not guid then return end
  EH.mobSnap[guid] = {
    guid = guid,
    id   = GetEntryIdFromGUID(guid),
    name = UnitName(unit),
    level = UnitLevelSafe(unit),
    classification = UnitClassification and UnitClassification(unit) or nil,
    creatureType   = UnitCreatureType and UnitCreatureType(unit) or nil,
    creatureFamily = UnitCreatureFamily and UnitCreatureFamily(unit) or nil,
    reaction       = UnitReaction and UnitReaction("player", unit) or nil,
    maxHp          = UnitHealthMax and UnitHealthMax(unit) or nil,
    maxMana        = UnitManaMax and UnitManaMax(unit) or nil,
    t = now(),
  }
end

local function MobSourceFromUnit(unit)
  if not UnitExists(unit) then return nil end
  local g = UnitGUID(unit); if not g then return nil end
  local mid = GetEntryIdFromGUID(g)
  local lvl = UnitLevelSafe(unit) or (EH.mobSnap[g] and EH.mobSnap[g].level) or nil

  -- NEW: capture location
  local z, s, x, y = EH.Pos()

  local src = {
    kind = "mob",
    id   = mid,
    guid = g,
    name = UnitName(unit),
    level = lvl,
    classification = UnitClassification and UnitClassification(unit) or nil,
    creatureType   = UnitCreatureType and UnitCreatureType(unit) or nil,
    creatureFamily = UnitCreatureFamily and UnitCreatureFamily(unit) or nil,
    reaction       = UnitReaction and UnitReaction("player", unit) or nil,
    maxHp          = UnitHealthMax and UnitHealthMax(unit) or nil,
    maxMana        = UnitManaMax and UnitManaMax(unit) or nil,
    -- NEW
    zone = z, subzone = s, x = x, y = y,
  }
  return src, (mid and tostring(mid) or nil), g
end


------------------------------------------------------------
-- Classifier (title → kind; container wins; word-bounded)
------------------------------------------------------------
local function hasWord(s, w)  return s:find("%f[%a]"..w.."%f[%A]") end
local function ClassifyFromTitle(title)
  if not title or title == "" then return nil end
  local t = title:lower()
  if hasWord(t, "clam") or t:find("barnacled") or hasWord(t, "chest")
     or hasWord(t, "footlocker") or hasWord(t, "cache") or hasWord(t, "coffer")
     or hasWord(t, "barrel") or hasWord(t, "crate") or t:find("crates")
     or hasWord(t, "basket") or hasWord(t, "box") or hasWord(t, "trunk")
     or hasWord(t, "sack") or hasWord(t, "satchel") or hasWord(t, "strongbox")
     or hasWord(t, "oyster") or hasWord(t, "shell") or hasWord(t, "purse") then
    return "Container"
  end
  if hasWord(t, "vein") or hasWord(t, "deposit") or hasWord(t, "lode") or hasWord(t, "ore") then
    return "Mining"
  end
  if hasWord(t, "herb") or hasWord(t, "bloom") or hasWord(t, "flower") or hasWord(t, "weed")
     or t:find("lotus") or t:find("gromsblood") or t:find("mageroyal")
     or t:find("peacebloom") or t:find("kingsblood") or t:find("dreamfoil")
     or t:find("goldthorn") then
    return "Herbalism"
  end
  return nil
end

------------------------------------------------------------
-- Tooltip parsing (for item extras)
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
  if not ScanTip:GetOwner() then ScanTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE") end
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

------------------------------------------------------------
-- EH.BuildItemEntry (EXPORTED)
------------------------------------------------------------
function EH.BuildItemEntry(link, nameFromLoot, qtyFromLoot, qualityFromLoot)
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
-- Helpers: source keys / slugs
------------------------------------------------------------
local function slug(s) return tostring(s or "unknown"):lower():gsub("%s+", "_") end

local function NodeSourceKey(nodeId, nodeName)
  if nodeId and tonumber(nodeId) then
    return "node:" .. tostring(nodeId)
  end
  local n = slug(nodeName or "Unknown Node")
  return "node-name:" .. n
end

local function ContainerSourceKey(itemId, itemName)
  if itemId and tonumber(itemId) then
    return "container-item:" .. tostring(itemId)
  end
  return "container-name:" .. slug(itemName or "Unknown Container")
end

------------------------------------------------------------
-- De-dupe (GUID + token)
------------------------------------------------------------
local lastMob = nil
local lastDeadMouseover = nil
local lastLootTs = 0

local KILL_DEDUPE = 300
local seenKillByGUID = {}
local function killSeenRecently(g) local t = seenKillByGUID[g]; return t and ((now() - t) < KILL_DEDUPE) end
local function markKill(g) if g then seenKillByGUID[g] = now() end end

local LOOT_CORPSE_DEDUPE = 300
local seenLootByGUID = {}
local function lootSeenRecently(g) local t = seenLootByGUID[g]; return t and ((now() - t) < LOOT_CORPSE_DEDUPE) end
local function markLoot(g) if g then seenLootByGUID[g] = now() end end

-- Token-based de-dupe (relaxed for gather & inventory containers)
local LOOT_TOKEN_TTL = 300
local seenLootTokenAt = {}
local function lootTokenSeenRecently(tok) local t = seenLootTokenAt[tok]; return t and ((now() - t) < LOOT_TOKEN_TTL) end
local function markLootToken(tok) if tok then seenLootTokenAt[tok] = now() end end

-- coin name → copper helper (fallback if not provided elsewhere)
if not CoinFromName then
  function CoinFromName(txt)
    if not txt or txt == "" then return 0 end
    local s = tostring(txt):lower()
    local g = tonumber(s:match("(%d+)%s*gold"))   or tonumber(s:match("(%d+)%s*g")) or 0
    local si= tonumber(s:match("(%d+)%s*silver")) or tonumber(s:match("(%d+)%s*s")) or 0
    local c = tonumber(s:match("(%d+)%s*copper")) or tonumber(s:match("(%d+)%s*c")) or 0
    return (g*10000 + si*100 + c)
  end
end

local function ItemsSignature(items, moneyCopper)
  local parts = {}
  if type(items) == "table" then
    for _, it in ipairs(items) do
      local id  = tonumber((it and it.id) or 0) or 0
      local qty = tonumber((it and (it.qty or it.count)) or 1) or 1
      parts[#parts+1] = (tostring(id) .. "x" .. tostring(qty))
    end
  end
  table.sort(parts)
  if moneyCopper and moneyCopper > 0 then parts[#parts+1] = ("c"..tostring(moneyCopper)) end
  return table.concat(parts, "|")
end

local function BuildLootToken(src, sKey, g, lootKind, items, moneyCopper)
  local sig = ItemsSignature(items, moneyCopper)
  local typ = src and src.kind or "unknown"
  if typ == "container" and src and src.containerKind == "item" then
    local idOrName = (src.itemId and tostring(src.itemId)) or (src.itemName and tostring(src.itemName)) or (sKey and tostring(sKey)) or "?"
    return "icont:"..idOrName.."|"..sig
  elseif lootKind == "GameObject" and g then
    return "go:"..tostring(g).."|"..sig
  elseif lootKind == "Creature" and g then
    return "corpse:"..tostring(g).."|"..sig
  elseif typ == "gather" then
    local nid = (src and src.nodeId) and tostring(src.nodeId) or "?"
    local nname = (src and src.nodeName) and tostring(src.nodeName) or ""
    return "node:"..nid..":"..nname.."|"..sig
  elseif typ == "mob" and src and src.guid then
    return "corpse:"..tostring(src.guid).."|"..sig -- fallback if lootKind missing
  else
    return "misc:"..tostring(sKey or lootKind or "?").."|"..sig
  end
end

------------------------------------------------------------
-- Kill push / source detect helpers
------------------------------------------------------------
local function PushKillEventFromSource(src)
  if not src then return end

  -- NEW: backfill location if missing
  if not src.zone or not src.subzone or src.x == nil or src.y == nil then
    local z, s, x, y = EH.Pos()
    src.zone = src.zone or z
    src.subzone = src.subzone or s
    if src.x == nil then src.x = x end
    if src.y == nil then src.y = y end
  end

  local key = src.id and tostring(src.id) or (src.guid and tostring(src.guid)) or nil
  if not key then return end
  PUSH({
    type = "kill", t = now(), session = EH.session,
    sourceKey = key, source = src, instance = GetInstanceInfoLite(),
  })
  log("kill " .. key)
end


-- Prefer GameObject GUIDs when present; otherwise fall back to Creature.
local function DetectLootSource()
  if not GetLootSourceInfo then return nil, nil, nil end
  local num = GetNumLootItems() or 0
  local goGuid, goEntry
  local mobGuid, mobEntry
  for slot = 1, num do
    local t = { GetLootSourceInfo(slot) }
    if #t >= 1 then
      for i = 1, #t, 2 do
        local guid = t[i]
        if guid then
          local kind = GUIDKind(guid)
          if kind == "GameObject" then
            if not goGuid then
              goGuid  = guid
              goEntry = GetEntryIdFromGUID(guid)
            end
          elseif kind == "Creature" then
            if not mobGuid then
              mobGuid  = guid
              mobEntry = GetEntryIdFromGUID(guid)
            end
          end
        end
      end
    end
  end
  if goGuid then return goGuid, "GameObject", goEntry end
  if mobGuid then return mobGuid, "Creature", mobEntry end
  -- Fallback: try current target if nothing else reported a source
  if UnitGUID and UnitGUID("target") then
    local tg = UnitGUID("target")
    return tg, GUIDKind(tg), GetEntryIdFromGUID(tg)
  end
  return nil, nil, nil
end

-- NEW: collect all loot source GUIDs (set), to safely detect mined corpses.
local function CollectLootSources()
  if not GetLootSourceInfo then return nil end
  local set = {}
  local num = GetNumLootItems() or 0
  for slot = 1, num do
    local t = { GetLootSourceInfo(slot) }
    for i = 1, #t, 2 do
      local guid = t[i]
      if guid then set[guid] = true end
    end
  end
  return set
end

------------------------------------------------------------
-- Fishing + Gather cast tracking
------------------------------------------------------------
if not EH.IsFishingLootSafe then
  function EH.IsFishingLootSafe()
    if type(IsFishingLoot) == "function" then
      local ok, res = pcall(IsFishingLoot)
      if ok then return res and true or false end
    end
    return false
  end
end

-- Known gather spell ids (best-effort; name fallback used too)
local FISHING_SPELL_IDS   = { [7732]=true, [7620]=true, [18248]=true}
local MINING_SPELL_IDS    = { [2575]=true }     -- "Mining"
local HERBALISM_SPELL_IDS = { [2366]=true }     -- "Herb Gathering"
local SKINNING_SPELL_IDS  = { [8613]=true }     -- "Skinning"

local function MarkGatherCast(kind)
  EH._lastGatherCast = { kind = kind, ts = now() }
end
local function RecentGatherCast(kind, window)
  window = window or 12
  local g = EH._lastGatherCast
  return g and g.kind == kind and (now() - (g.ts or 0) <= window)
end

local function isFishingName(spellName)
  if not spellName then return false end
  local fishName = (GetSpellInfo and GetSpellInfo(7732)) or "Fishing"
  return spellName == fishName
end
local function isMiningName(spellName)
  if not spellName then return false end
  local s = spellName:lower()
  return s:find("mining", 1, true) ~= nil
end
local function isHerbName(spellName)
  if not spellName then return false end
  local s = spellName:lower()
  return s:find("herb", 1, true) ~= nil or s:find("gather", 1, true) ~= nil
end
local function isSkinningName(spellName)
  if not spellName then return false end
  local s = spellName:lower()
  return s:find("skin", 1, true) ~= nil
end

if not EH.OnSpellcastSucceeded then
  function EH.OnSpellcastSucceeded(unit, spell, rank, lineId, spellID)
    if unit ~= "player" then return end

    -- Fishing (keep exact like before)
    if (type(spellID) == "number" and FISHING_SPELL_IDS[spellID]) or isFishingName(spell) then
      local z,s,x,y = EH.Pos()
      EH._fishingHitTS = EH.now()
      EH._fishingLast  = { z=z, s=s, x=x, y=y }
      log(("fishing spell OK (id=%s) @ %s:%s"):format(tostring(spellID or "?"), z or "?", s or ""))
      return
    end

    -- Mining / Herbalism tracking (best-effort)
    if (type(spellID) == "number" and MINING_SPELL_IDS[spellID]) or isMiningName(spell) then
      MarkGatherCast("Mining");  log("gather cast: Mining");  return
    end
    if (type(spellID) == "number" and HERBALISM_SPELL_IDS[spellID]) or isHerbName(spell) then
      MarkGatherCast("Herbalism"); log("gather cast: Herbalism"); return
    end
    if (type(spellID) == "number" and SKINNING_SPELL_IDS[spellID]) or isSkinningName(spell) then
      MarkGatherCast("Skinning"); log("gather cast: Skinning"); return
    end
  end
end

------------------------------------------------------------
-- NEW: mark recent container item use (bag, action bar, or macro)
-- (tightened so non-containers don't get marked/logged)
------------------------------------------------------------
EH._pendingBagOpen = EH._pendingBagOpen or nil  -- { ts, id, name, class, subClass }

local function LooksLikeContainerItem(name, className, subClassName)
  local t = tostring(name or ""):lower()
  if t == "" then return false end
  if t:find("lockbox") or hasWord(t,"strongbox") or hasWord(t,"footlocker")
     or hasWord(t,"clam") or hasWord(t,"oyster") or hasWord(t,"shell")
     or hasWord(t,"satchel") or hasWord(t,"purse")
     or hasWord(t,"bag") or hasWord(t,"chest") or hasWord(t,"cache") or hasWord(t,"coffer")
     or hasWord(t,"crate") or t:find("crates") or hasWord(t,"basket")
     or hasWord(t,"box") or hasWord(t,"trunk") then
    return true
  end
  local sc = tostring(subClassName or ""):lower()
  if sc:find("lockbox") then return true end
  return false
end

local function GetContainerItemLinkSafe(bag, slot)
  if _G.C_Container and C_Container.GetContainerItemLink then
    return C_Container.GetContainerItemLink(bag, slot)
  elseif _G.GetContainerItemLink then
    return GetContainerItemLink(bag, slot)
  end
end

local function GetContainerItemIDSafe(bag, slot)
  if _G.C_Container and C_Container.GetContainerItemID then
    return C_Container.GetContainerItemID(bag, slot)
  elseif _G.GetContainerItemID then
    return GetContainerItemID(bag, slot)
  end
end

local function ParseItemIDFromString(s)
  if type(s) ~= "string" then return nil end
  local id = s:match("item:(%d+)")
  return id and tonumber(id) or nil
end

local function MarkContainerUse_FromBag(bag, slot, ...)
  local link = GetContainerItemLinkSafe(bag, slot)
  local id   = ParseItemIDFromString(link) or GetContainerItemIDSafe(bag, slot)
  local name, _, _, _, _, className, subClassName = GetItemInfo(link or id or "")
  if LooksLikeContainerItem(name, className, subClassName) then
    EH._pendingBagOpen = { ts = now(), id = id, name = name, class = className, subClass = subClassName }
    log(("bag container candidate: %s (%s)"):format(tostring(name or "?"), tostring(id or "?")))
  else
    EH._pendingBagOpen = nil
  end
end

local function MarkContainerUse_FromNameOrLink(item, ...)
  local id   = ParseItemIDFromString(item)
  local name, className, subClassName = item, nil, nil
  if id and GetItemInfo then
    local n, _, _, _, _, cN, scN = GetItemInfo(id)
    if n then name = n end
    className, subClassName = cN, scN
  end
  if LooksLikeContainerItem(name, className, subClassName) then
    EH._pendingBagOpen = { ts = now(), id = id, name = name, class = className, subClass = subClassName }
    log(("name/link container candidate: %s (%s)"):format(tostring(name or "?"), tostring(id or "?")))
  else
    EH._pendingBagOpen = nil
  end
end

local function MarkContainerUse_FromItemLoc(itemLoc, ...)
  -- no-op on 3.3.5; rely on LOOT_OPENED/title/loot source to confirm
end

local function HookContainerUse()
  if _G.C_Container and type(C_Container.UseContainerItem) == "function" then
    hooksecurefunc(C_Container, "UseContainerItem", MarkContainerUse_FromBag)
  end
  if type(_G.UseContainerItem) == "function" then
    hooksecurefunc("UseContainerItem", MarkContainerUse_FromBag)
  end
  if _G.C_Item and type(C_Item.UseItem) == "function" then
    hooksecurefunc(C_Item, "UseItem", MarkContainerUse_FromItemLoc)
  end
  if type(_G.UseItemByName) == "function" then
    hooksecurefunc("UseItemByName", MarkContainerUse_FromNameOrLink)
  end
end

------------------------------------------------------------
-- Combat log + mouseover
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
  if subevent == "SPELL_CAST_SUCCESS" and CombatLogGetCurrentEventInfo then
    local _, se, _, srcGUID, srcName, _, _, _, _, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
    if srcGUID and UnitGUID and srcGUID == UnitGUID("player") then
      if (spellId and (FISHING_SPELL_IDS[spellId])) or isFishingName(spellName) then
        local z,s,x,y = EH.Pos()
        EH._fishingHitTS = EH.now()
        EH._fishingLast  = { z=z, s=s, x=x, y=y }
        log(("fishing CLEU OK (id=%s) @ %s:%s"):format(tostring(spellId or "?"), z or "?", s or ""))
      elseif (spellId and MINING_SPELL_IDS[spellId]) or isMiningName(spellName) then
        MarkGatherCast("Mining")
      elseif (spellId and HERBALISM_SPELL_IDS[spellId]) or isHerbName(spellName) then
        MarkGatherCast("Herbalism")
      end
    end
  end

  if subevent == "PARTY_KILL" or subevent == "UNIT_DIED" then
    local mid = GetEntryIdFromGUID(dstGUID)
    if mid then
      lastMob = {
        id = mid, guid = dstGUID, name = dstName or ("Mob "..mid),
        t = now(),
        level = (EH.mobSnap[dstGUID] and EH.mobSnap[dstGUID].level) or UnitLevelSafe("target"),
        classification = UnitClassification and UnitClassification("target") or nil,
        creatureType   = UnitCreatureType and UnitCreatureType("target") or nil,
        creatureFamily = UnitCreatureFamily and UnitCreatureFamily("target") or nil,
        reaction       = UnitReaction and UnitReaction("player","target") or nil,
        maxHp          = UnitHealthMax and UnitHealthMax("target") or nil,
        maxMana        = UnitManaMax and UnitManaMax("target") or nil,
      }

      if subevent == "PARTY_KILL" then
        if not killSeenRecently(dstGUID) then
          markKill(dstGUID)
          local src = nil
          if UnitExists("target") and UnitGUID("target") == dstGUID then
            src = select(1, MobSourceFromUnit("target"))
          end
do
  local z, s, x, y = EH.Pos()
  src = src or {
    kind="mob",
    id=mid, guid=dstGUID, name=lastMob.name,
    level=lastMob.level, classification=lastMob.classification,
    creatureType=lastMob.creatureType, creatureFamily=lastMob.creatureFamily,
    reaction=lastMob.reaction, maxHp=lastMob.maxHp, maxMana=lastMob.maxMana,
    -- NEW
    zone = z, subzone = s, x = x, y = y,
  }
end
          PushKillEventFromSource(src)
        end
      end
    end
  end
end

-- throttle spam for dead mouseover snapshots
local lastMouseoverLogGUID, lastMouseoverLogTS = nil, 0
local function OnUpdateMouseover()
  if UnitExists("mouseover") and UnitIsDead("mouseover") then
    local g = UnitGUID("mouseover")
    if g then
      local suppress = (g == lastMouseoverLogGUID) and ((now() - lastMouseoverLogTS) < 2)
      local mid = GetEntryIdFromGUID(g)
      if mid then
        lastDeadMouseover = {
          id = mid, guid = g, name = UnitName("mouseover"),
          t = now(),
          level = (EH.mobSnap[g] and EH.mobSnap[g].level) or UnitLevelSafe("mouseover"),
          classification = UnitClassification and UnitClassification("mouseover") or nil,
          creatureType   = UnitCreatureType and UnitCreatureType("mouseover") or nil,
          creatureFamily = UnitCreatureFamily and UnitCreatureFamily("mouseover") or nil,
          reaction       = UnitReaction and UnitReaction("player","mouseover") or nil,
          maxHp          = UnitHealthMax and UnitHealthMax("mouseover") or nil,
          maxMana        = UnitManaMax and UnitManaMax("mouseover") or nil,
        }
        if not suppress then
          log(("snapshot dead mouseover: %s (%s) ct=%s"):format(
            tostring(lastDeadMouseover.name or "?"),
            tostring(g),
            tostring(lastDeadMouseover.creatureType or "?")))
          lastMouseoverLogGUID, lastMouseoverLogTS = g, now()
        end
      end
    end
  end
end

------------------------------------------------------------
-- Fishing event push
------------------------------------------------------------
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

------------------------------------------------------------
-- Helpers: derive Mining node name from loot
------------------------------------------------------------
local function MiningNameFromItems(items)
  if type(items) ~= "table" then return nil end
  local ore, stone, gem
  for _, it in ipairs(items) do
    local nm = (it and it.info and it.info.name) or (it and it.name) or nil
    if nm and nm ~= "" then
      local low = nm:lower()
      if (not ore) and low:find(" ore") then ore = nm end
      if (not stone) and low:find(" stone") then stone = nm end
      if (not gem) and (low:find("sapphire") or low:find("ruby") or low:find("topaz") or low:find("emerald") or low:find("opal")) then
        gem = nm
      end
      if ore then break end
    end
  end
  if ore then   return (ore   .. " Node") end
  if stone then return (stone .. " Node") end
  if gem then   return (gem   .. " Node") end
  return nil
end
local function IsMiningLoot(items)
  if type(items) ~= "table" then return false end
  -- whitelist-y: ores/bars/common stones/gems; avoids false hits like "Smooth Stone Chip"
  local kw = {
    " ore",
    "rough stone", "coarse stone", "heavy stone", "solid stone", "dense stone",
    "malachite", "tigerseye", "shadowgem", "jade", "citrine", "aquamarine",
    "sapphire", "ruby", "emerald", "topaz", "opal"
  }
  for _, it in ipairs(items) do
    local nm = (it and it.info and it.info.name) or (it and it.name) or ""
    local l = nm:lower()
    for _, k in ipairs(kw) do
      if l:find(k, 1, true) then return true end
    end
  end
  return false
end

local function IsGenericMiningName(name)
  if not name or name == "" then return true end
  local low = name:lower()
  return (low == "mining node") or (low == "node") or (low == "deposit") or (low == "vein")
end

-- Herbalism helpers (mirror Mining logic)
local function HerbNameFromItems(items)
  if type(items) ~= "table" then return nil end
  local herb
  for _, it in ipairs(items) do
    local nm = (it and it.info and it.info.name) or (it and it.name) or nil
    if nm and nm ~= "" then
      local low = nm:lower()
      if low:find("bloom") or low:find("flower") or low:find("weed") or low:find("herb")
         or low:find("lotus") or low:find("gromsblood") or low:find("mageroyal")
         or low:find("peacebloom") or low:find("kingsblood") or low:find("dreamfoil")
         or low:find("goldthorn") then
        herb = nm
        break
      end
    end
  end
  if herb then return (herb .. " Node") end
  return nil
end

local function IsHerbLoot(items)
  if type(items) ~= "table" then return false end
  local kw = {
    "bloom", "flower", "weed", "herb", "lotus",
    "gromsblood", "mageroyal", "peacebloom", "kingsblood",
    "dreamfoil", "goldthorn",
  }
  for _, it in ipairs(items) do
    local nm = (it and it.info and it.info.name) or (it and it.name) or ""
    local l = nm:lower()
    for _, k in ipairs(kw) do
      if l:find(k, 1, true) then return true end
    end
  end
  return false
end

local function IsGenericHerbName(name)
  if not name or name == "" then return true end
  local low = name:lower()
  return (low == "herb node") or (low == "herbalism node") or (low == "herb") or (low == "node")
end

------------------------------------------------------------
-- Loot handler
------------------------------------------------------------
local function IsProbablyMobName(name)
  if not name or name == "" then return false end
  if UnitExists("target")    and name == UnitName("target")    then return true end
  if UnitExists("mouseover") and name == UnitName("mouseover") then return true end
  return false
end

local function PushLootEvent(items, moneyCopper, lootGUID, lootKind, lootEntry, corpseGUIDHint)
  local src, sKey, g = nil, nil, lootGUID
  local hasSource = (g ~= nil)
  local isSkinning = RecentGatherCast("Skinning", 12)

  -- Inventory container (bag item opened)
  if EH._currentContainer then
    src = {
      kind = "container",
      containerKind = "item",
      itemId = EH._currentContainer.itemId,
      itemName = EH._currentContainer.itemName,
    }
    sKey = ContainerSourceKey(EH._currentContainer.itemId, EH._currentContainer.itemName)
  end

  -- Mob corpse loot (Creature)
  if (not src) and (hasSource and lootKind == "Creature") then
    local targetGUID  = (UnitExists("target") and UnitGUID("target")) or nil
    local mouseGUID   = (UnitExists("mouseover") and UnitGUID("mouseover")) or nil
    local chosenUnit  = (targetGUID == g and "target") or (mouseGUID == g and "mouseover") or nil
    if chosenUnit then
      src, sKey = MobSourceFromUnit(chosenUnit)
    else
      local mid = lootEntry or GetEntryIdFromGUID(g)
      src = { kind="mob", id=mid, guid=g, name=nil }
      sKey = (mid and tostring(mid)) or tostring(g)
    end
  end

  -- World GameObject (nodes/chests) — may also be corpse-mining
  if (not src) and hasSource and lootKind == "GameObject" then
    local nodeId     = lootEntry or GetEntryIdFromGUID(g)
    local nodeName   = (EH._currentGather and EH._currentGather.nodeName) or nil
    local gatherKind = (EH._currentGather and EH._currentGather.gatherKind) or ClassifyFromTitle(nodeName) or "Container"

    -- Prefer authoritative Creature owner from hint; fallback to timed mouseover
    local corpseMining, corpseGuidLocal, corpseEntryLocal, corpseNameLocal = false, nil, nil, nil

    if corpseGUIDHint then
      corpseGuidLocal  = corpseGUIDHint
      corpseEntryLocal = GetEntryIdFromGUID(corpseGuidLocal)
      corpseNameLocal  = (EH.mobSnap[corpseGuidLocal] and EH.mobSnap[corpseGuidLocal].name) or nil
      corpseMining     = true
    elseif RecentGatherCast("Mining", 12) and lastDeadMouseover and (now() - (lastDeadMouseover.t or 0) <= 8) then
      corpseGuidLocal  = lastDeadMouseover.guid
      corpseEntryLocal = GetEntryIdFromGUID(corpseGuidLocal)
      corpseNameLocal  = lastDeadMouseover.name
      corpseMining     = true
    end

    -- Derive a generic Mining/Herbalism node name only if needed (no corpse renaming)
    if gatherKind == "Mining" and (not nodeName or IsGenericMiningName(nodeName)) then
      local derived = MiningNameFromItems(items)
      if derived then nodeName = derived end
      if not nodeName or nodeName == "" then nodeName = "Mining Node" end
    elseif gatherKind == "Herbalism" and (not nodeName or IsGenericHerbName(nodeName)) then
      local derived = HerbNameFromItems(items)
      if derived then nodeName = derived end
      if not nodeName or nodeName == "" then nodeName = "Herbalism Node" end
    end

    src  = { kind="gather", gatherKind=gatherKind, nodeId=nodeId, nodeName=nodeName, guid=g }
    sKey = NodeSourceKey(nodeId, nodeName)

    -- Attach corpse meta to the source + propagate hint; keep node id/name unchanged
    if corpseMining and corpseGuidLocal then
      src.corpse = { id = corpseEntryLocal, guid = corpseGuidLocal, name = corpseNameLocal }
      if not corpseGUIDHint then corpseGUIDHint = corpseGuidLocal end
    end
  end

  -- Fallback to gather hint if present (title-only cases)
  if (not src) and EH._currentGather then
    local gk       = EH._currentGather.gatherKind or "Container"
    local nodeName = EH._currentGather.nodeName
    if gk == "Mining" and (not nodeName or IsGenericMiningName(nodeName)) then
      local derived = MiningNameFromItems(items)
      if derived then nodeName = derived end
      if not nodeName or nodeName == "" then nodeName = "Mining Node" end
    elseif gk == "Herbalism" and (not nodeName or IsGenericHerbName(nodeName)) then
      local derived = HerbNameFromItems(items)
      if derived then nodeName = derived end
      if not nodeName or nodeName == "" then nodeName = "Herbalism Node" end
    end
    src  = { kind="gather", gatherKind=gk, nodeId=EH._currentGather.nodeId, nodeName=nodeName, guid=g }
    sKey = NodeSourceKey(EH._currentGather.nodeId, nodeName)
  end

  -- Dead mouseover fallback (as mob)
  if (not src) and lastDeadMouseover and (now() - (lastDeadMouseover.t or 0) <= 3) then
    src = {
      kind="mob", id=lastDeadMouseover.id, guid=lastDeadMouseover.guid, name=lastDeadMouseover.name,
      level=lastDeadMouseover.level, classification=lastDeadMouseover.classification,
      creatureType=lastDeadMouseover.creatureType, creatureFamily=lastDeadMouseover.creatureFamily,
      reaction=lastDeadMouseover.reaction, maxHp=lastDeadMouseover.maxHp, maxMana=lastDeadMouseover.maxMana,
    }
    sKey      = tostring(lastDeadMouseover.id or lastDeadMouseover.guid)
    g         = lastDeadMouseover.guid
    hasSource = (g ~= nil)
    lootKind  = "Creature"
  end

  -- Recent kill fallback (as mob)
  if (not src) and lastMob and (now() - lastMob.t) <= 12 then
    src = {
      kind="mob", id=lastMob.id, guid=lastMob.guid, name=lastMob.name,
      level=lastMob.level, classification=lastMob.classification,
      creatureType=lastMob.creatureType, creatureFamily=lastMob.creatureFamily,
      reaction=lastMob.reaction, maxHp=lastMob.maxHp, maxMana=lastMob.maxMana,
    }
    sKey      = tostring(lastMob.id or lastMob.guid)
    g         = lastMob.guid
    hasSource = (g ~= nil)
    lootKind  = "Creature"
  end

  -- Kill credit only for mobs
  if src and src.kind == "mob" and g and not killSeenRecently(g) then
    markKill(g)
    PushKillEventFromSource(src)
  end

  -- GUID loot de-dupe
  if hasSource and lootKind == "Creature"   and lootSeenRecently(g) and not isSkinning then log("loot skipped (corpse GUID cooldown) guid="..tostring(g)); return end
  if hasSource and lootKind == "GameObject" and lootSeenRecently(g) then log("loot skipped (gameobject GUID cooldown) guid="..tostring(g)); return end

  -- Ensure sourceKey
  if not sKey then
    if hasSource and lootKind == "Creature" then
      local mid = lootEntry or GetEntryIdFromGUID(g)
      sKey = tostring(mid or g)
    else
      sKey = "unknown"
    end
  end

  -- Token de-dupe (bypass for gather and inventory-item containers)
  local _tok = BuildLootToken(src, sKey, g, lootKind, items, moneyCopper)
  local bypassToken = (src and src.kind == "gather") or (src and src.kind == "container" and src.containerKind == "item")
  if not bypassToken and lootTokenSeenRecently(_tok) then
    log("loot skipped (token cooldown) token="..tostring(_tok))
    return
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

  -- Attach corpse info to the event (for correlation) without changing naming
  if (lootKind == "Creature" and g) or corpseGUIDHint then
    ev.corpseGUID   = g or corpseGUIDHint
    ev.corpseEntry  = GetEntryIdFromGUID(ev.corpseGUID)
    ev.mobSourceKey = tostring(ev.corpseEntry or ev.corpseGUID)

    -- NEW: for mined corpses (GameObject + corpse hint), also expose mobId explicitly
    if lootKind == "GameObject" and corpseGUIDHint and ev.corpseEntry then
      ev.mobId = ev.corpseEntry
    end
  end

  -- attempt counters
  if src and src.kind == "gather"     then ev.attempt = 1 end
  if src and src.kind == "container"  then ev.attempt = 1 end
  if isSkinning                       then ev.profession = "skinning"; ev.attempt = 1 end

  if hasSource and lootKind == "Creature"   then markLoot(g) end
  if hasSource and lootKind == "GameObject" then markLoot(g) end
  if not bypassToken then markLootToken(_tok) end

  PUSH(ev)
  log(("loot pushed kind=? src.kind=%s sKey=%s items=%d money=%s corpseGUID=%s corpseEntry=%s token=%s")
      :format(tostring(src and src.kind or "?"),
              tostring(sKey),
              tonumber(#(items or {})) or 0,
              tostring(moneyCopper or 0),
              tostring(ev.corpseGUID),
              tostring(ev.corpseEntry),
              tostring(_tok)))
end

local function OnLootOpened()
  -- simple spam guard
  local ts_ = now()
  if (ts_ - lastLootTs) < 3 then return end
  lastLootTs = ts_

  -- if we just used a container item, do NOT treat this as fishing
  local containerRecent = EH._pendingBagOpen and ((now() - (EH._pendingBagOpen.ts or 0)) <= 5)

  -- fishing?
  local _isFishing = EH.IsFishingLootSafe()
  if (not _isFishing) and EH._fishingHitTS and (now() - EH._fishingHitTS) <= 12 then
    _isFishing = true
  end
  if containerRecent then
    _isFishing = false
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
        local entry = EH.BuildItemEntry(link, name, qty, quality)
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

  -- reset gather/container hints
  EH._currentGather    = nil
  EH._currentContainer = nil

  -- title on loot frame (for chests/nodes)
  local nodeTitle = _G.LootFrameTitleText and _G.LootFrameTitleText.GetText and _G.LootFrameTitleText:GetText() or nil
  local lootGUID, lootKind, lootEntry = DetectLootSource()

  -- NEW: capture a Creature owner from loot sources when primary is a GameObject (mined corpse case)
  local corpseGUIDHint = nil
  if lootKind == "GameObject" then
    local srcs = CollectLootSources()
    if srcs then
      for guid,_ in pairs(srcs) do
        if GUIDKind(guid) == "Creature" then
          corpseGUIDHint = guid
          break
        end
      end
    end
  end

  -- quick intent guess before we consider corpse GUID fallbacks
  local gatherIntent = false
  if containerRecent then gatherIntent = true end
  if nodeTitle and nodeTitle ~= "" and ClassifyFromTitle(nodeTitle) then gatherIntent = true end
  if RecentGatherCast("Mining", 12) or RecentGatherCast("Herbalism", 12) or RecentGatherCast("Skinning", 12) then gatherIntent = true end

  -- If no GUID and this does not look like gather, try corpse GUID fallback (restores corpse dedupe)
  if (not lootGUID) and (not gatherIntent) then
    local cg = nil
    if UnitExists("target") and UnitIsDead("target") then cg = UnitGUID("target") end
    if (not cg) and UnitExists("mouseover") and UnitIsDead("mouseover") then cg = UnitGUID("mouseover") end
    if (not cg) and lastDeadMouseover and (now() - (lastDeadMouseover.t or 0) <= 12) then cg = lastDeadMouseover.guid end
    if cg then
      lootGUID = cg
      lootKind = "Creature"
      lootEntry = GetEntryIdFromGUID(cg)
    end
  end

  log(("LOOT_OPENED: lootGUID=%s lootKind=%s entry=%s title=%s")
      :format(tostring(lootGUID), tostring(lootKind), tostring(lootEntry), tostring(nodeTitle or "")))

  -- Inventory container (bag item) detection (works for lockboxes + clams)
  if EH._pendingBagOpen and (now() - (EH._pendingBagOpen.ts or 0) <= 8) then
    local po = EH._pendingBagOpen
    if (LooksLikeContainerItem(po.name, po.class, po.subClass) and (not lootGUID))
       or (nodeTitle and ClassifyFromTitle(nodeTitle) == "Container") then
      EH._currentContainer = { itemId = po.id, itemName = po.name }
      log(("inventory container: %s (id=%s)"):format(tostring(po.name or "?"), tostring(po.id or "?")))
    end
  end

  -- If we have a title and no explicit bag container, prefill gather hint
  if (not EH._currentContainer) and nodeTitle and nodeTitle ~= "" then
    local nodeId = (lootKind == "GameObject") and lootEntry or nil
    EH._currentGather = {
      gatherKind = ClassifyFromTitle(nodeTitle) or "Container",
      nodeName   = nodeTitle,
      nodeId     = nodeId,
      sourceKey  = NodeSourceKey(nodeId, nodeTitle),
    }
  end

  -- Collect items/coins
  local items, moneyCopper, num = {}, 0, GetNumLootItems() or 0
  for slot = 1, num do
    local link = (GetLootSlotLink and GetLootSlotLink(slot)) or nil
    if link and tostring(link):find("item:") then
      local _, name, qty, quality = GetLootSlotInfo(slot)
      if not IsProbablyMobName(name) then
        local entry = EH.BuildItemEntry(link, name, qty, quality)
        if entry and entry.id then table.insert(items, entry) end
      end
    else
      local _, nm = GetLootSlotInfo(slot)
      local copper = CoinFromName(nm)
      if copper and copper > 0 then moneyCopper = moneyCopper + copper end
    end
  end

  -- Infer Mining/Herbalism by recent cast ONLY when loot looks like it AND no explicit container
  if (not EH._currentContainer) and (not EH._currentGather)
     and (lootGUID == nil or lootKind == "GameObject")
     and (RecentGatherCast("Mining", 12) or RecentGatherCast("Herbalism", 12)) then

    local kind = RecentGatherCast("Mining", 12) and "Mining" or "Herbalism"

    -- Require mining/herb-like loot to claim gather; avoids mis-tagging mob loot
    if kind == "Mining" and not IsMiningLoot(items) then
      kind = nil
    elseif kind == "Herbalism" and not IsHerbLoot(items) then
      kind = nil
    end

    if kind then
      local inferredName = nil

      -- NOTE: we no longer use corpse naming here; keep the node name generic/derived
      if (not inferredName or inferredName == "") and nodeTitle and nodeTitle ~= "" then
        inferredName = nodeTitle
      end
      if (not inferredName or IsGenericMiningName(inferredName)) and kind == "Mining" then
        local derived = MiningNameFromItems(items)
        if derived then inferredName = derived end
      elseif (not inferredName or IsGenericHerbName(inferredName)) and kind == "Herbalism" then
        local derived = HerbNameFromItems(items)
        if derived then inferredName = derived end
      end
      inferredName = inferredName or (kind .. " Node")

      EH._currentGather = {
        gatherKind = kind,
        nodeName   = inferredName,
        nodeId     = nil,
        sourceKey  = NodeSourceKey(nil, inferredName),
      }
      log(("gather infer (by cast/items): %s -> node='%s' key=%s")
        :format(kind, tostring(inferredName or "?"), tostring(EH._currentGather.sourceKey)))
    end
  end

  -- Finally, push the loot (pass corpseGUIDHint if we found a Creature source alongside a GameObject)
  PushLootEvent(items, (moneyCopper > 0) and moneyCopper or nil, lootGUID, lootKind, lootEntry, corpseGUIDHint)
end

------------------------------------------------------------
-- Frame & events
------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
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

-- Basic quest tracking (unchanged behavior; lightweight)
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
local function safecall(fn, ...) if type(fn) ~= "function" then return nil end; local ok, a,b,c,d = pcall(fn, ...); if ok then return a,b,c,d end end
local function BuildNPCFromUnit(unit)
  if not UnitExists or not UnitExists(unit) then return nil end
  local g = UnitGUID(unit); local id = g and GetEntryIdFromGUID(g) or nil
  return { id = id, guid = g, name = UnitName(unit) }
end
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
      local entry = EH.BuildItemEntry(qlItemLink("reward", i), name, numItems, quality)
      if entry and entry.id then table.insert(items, entry) end
    end
  end
  for i = 1, nChoices do
    local name, tex, numItems, quality = (safecall(GetQuestLogChoiceInfo, i))
    if name then
      local entry = EH.BuildItemEntry(qlItemLink("choice", i), name, numItems, quality)
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
  local z, s, x, y = EH.Pos()
  local ev = {
    type = "quest", subtype = "accept", t = now(), session = EH.session,
    id = qid, title = title, text = description, objectives = objectives,
    giver = BuildNPCFromUnit("target"),
    rewardsPreview = CaptureQuestLogRewards(questIndex),
    zone = z, subzone = s, x = x, y = y,
  }
  if qid then PUSH(ev); EH._pendingQuestAccept = nil else EH._pendingQuestAccept = { idx = questIndex, ev = ev, ts = now() } end
end
local function OnQuestLogUpdate()
  local p = EH._pendingQuestAccept; if not p then return end
  local qid = GetQuestIdFromLogIndex(p.idx)
  if qid then p.ev.id = qid; PUSH(p.ev); EH._pendingQuestAccept = nil end
end
local function OnQuestComplete()
  local items, choices = {}, {}
  local function captureList(kind, count)
    for i = 1, (count or 0) do
      local link = GetQuestItemLink and GetQuestItemLink(kind, i) or nil
      local name, tex, numItems, quality = GetQuestItemInfo(kind, i)
      local entry = EH.BuildItemEntry(link, name, numItems, quality)
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
  local receiver = BuildNPCFromUnit("target")
  local rewards = EH._pendingQuestRewards or {}
  PUSH({
    type = "quest", subtype = "turnin", t = now(), session = EH.session, id = questID, title = nil,
    receiver = receiver,
    xp = xpReward, money = (moneyReward and moneyReward > 0) and { copper = moneyReward } or nil,
    rewards = (next(rewards) and { items = rewards.items, choiceItems = rewards.choiceItems }) or nil,
  })
  EH._pendingQuestRewards = nil
end

f:SetScript("OnEvent", function(self, event, ...)
  local a1,a2,a3,a4,a5,a6,a7,a8,a9,a10 = ...
  local ok, err = pcall(function()
    if event == "ADDON_LOADED" then
      local addonName = a1
      if addonName and tostring(addonName):lower():find("epochhead") then
        StampMeta()
        HookContainerUse()
        if not EH._loadedPrinted then
          chat(("loaded v%s (session=%s)"):format(tostring(EH.VERSION), tostring(EH.session)))
          EH._loadedPrinted = true
        end
      end
    elseif event == "PLAYER_LOGIN" then
      HookContainerUse()
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
      EH._currentContainer = nil
      EH._pendingBagOpen = nil
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
  if not ok and err then oops(event, err) end
end)

------------------------------------------------------------
-- Slash commands
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
    chat("commands: ping | debug on/off | debug | status")
  end
end

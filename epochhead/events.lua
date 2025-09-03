-- EpochHead events.lua — 3.3.5a-safe (UNIFIED, no QUEST_DETAIL)
-- Version: 0.9.0 (container-in-bag logging)
-- - Gather events simplified: no zone/subzone/coords; no "kills" on nodes
-- - Gather sourceKey = "node:<GO id>" when available; else "node-name:<name>"
-- - Each gather loot carries attempt=1 for clean drop-rate math
-- - Container-vs-Mining/Herbalism title classifier (container wins)
-- - Word-bound mining terms (no "Darkshore"→Mining false positives)
-- - Kill credit only for mobs (never nodes/containers)
-- - Fishing logic retained (unchanged)
-- - NEW: Inventory container (lockbox/clam/etc.) logging as kind="container" with sourceKey "container-item:<id>" or "container-name:<slug>"

local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH
EH.VERSION   = "0.9.0"

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
  }
  return src, (mid and tostring(mid) or nil), g
end

------------------------------------------------------------
-- Classifier (title → kind; container wins)
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
     or t:find("lotus") or t:find("gromsblood") or t:find("mageroyal") or t:find("peacebloom")
     or t:find("kingsblood") or t:find("dreamfoil") or t:find("goldthorn") then
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
-- Helpers: source keys for nodes/containers
------------------------------------------------------------
local function slug(s) return tostring(s or "unknown"):lower():gsub("%s+", "_") end

local function NodeSourceKey(nodeId, nodeName)
  if nodeId and tonumber(nodeId) then
    return "node:" .. tostring(nodeId)
  end
  local n = slug(nodeName or "Unknown Node")
  return "node-name:" .. n
end

-- NEW: item-container keys (no zone/subzone tagging)
local function ContainerSourceKey(itemId, itemName)
  if itemId and tonumber(itemId) then
    return "container-item:" .. tostring(itemId)
  end
  return "container-name:" .. slug(itemName or "Unknown Container")
end

-- NEW: detect container-ish item names/classes
local function LooksLikeContainerItem(name, className, subClassName)
  local t = tostring(name or ""):lower()
  if t == "" then return false end
  if t:find("lockbox") or hasWord(t,"strongbox") or hasWord(t,"footlocker") or hasWord(t,"clam")
     or hasWord(t,"oyster") or hasWord(t,"shell") or hasWord(t,"satchel") or hasWord(t,"purse")
     or hasWord(t,"bag") then
    return true
  end
  local sc = tostring(subClassName or ""):lower()
  if sc:find("lockbox") then return true end
  return false
end

------------------------------------------------------------
-- Kill + loot (dedupe + attribution)
------------------------------------------------------------
local lastMob = nil
local lastDeadMouseover = nil
local lastLootTs = 0
local LOOT_DEDUPE_WINDOW = 3

local KILL_DEDUPE = 300
local seenKillByGUID = {}
local function killSeenRecently(g) local t = seenKillByGUID[g]; return t and ((now() - t) < KILL_DEDUPE) end
local function markKill(g) if g then seenKillByGUID[g] = now() end end

local LOOT_CORPSE_DEDUPE = 300
local seenLootByGUID = {}
local function lootSeenRecently(g) local t = seenLootByGUID[g]; return t and ((now() - t) < LOOT_CORPSE_DEDUPE) end
local function markLoot(g) if g then seenLootByGUID[g] = now() end end

-- Token-based loot de-dupe for non-mob cases (containers, nodes, inventory containers)
local LOOT_TOKEN_TTL = 300
local seenLootTokenAt = {}
local function lootTokenSeenRecently(tok) local t = seenLootTokenAt[tok]; return t and ((now() - t) < LOOT_TOKEN_TTL) end
local function markLootToken(tok) if tok then seenLootTokenAt[tok] = now() end end

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
  local typ = src and src.kind or lootKind or "unknown"
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
  else
    return "misc:"..tostring(sKey or lootKind or "?").."|"..sig
  end
end



EH._currentGather    = nil
EH._currentContainer = nil

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

-- Detect first loot source GUID
local function DetectLootSource()
  if not GetLootSourceInfo then return nil, nil, nil end
  local num = GetNumLootItems() or 0
  for slot = 1, num do
    local t = { GetLootSourceInfo(slot) }
    if #t >= 1 then
      for i = 1, #t, 2 do
        local guid = t[i]
        if guid then
          local kind = GUIDKind(guid)
          local entry = GetEntryIdFromGUID(guid)
          return guid, kind, entry
        end
      end
    end
  end
  return nil, nil, nil
end

------------------------------------------------------------
-- Fishing helpers
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
-- Money parsing (locale-safe)
------------------------------------------------------------
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

------------------------------------------------------------
-- NEW: hook UseContainerItem to remember last bag item used
------------------------------------------------------------
EH._pendingBagOpen = nil

local function RememberBagUse(bag, slot)
  if not GetContainerItemLink then return end
  local link = GetContainerItemLink(bag, slot)
  if not link then return end
  local id = tonumber(tostring(link):match("item:(%d+)"))
  local name, _, _, _, _, className, subClassName = GetItemInfo(link or "")
  EH._pendingBagOpen = {
    bag = bag, slot = slot, link = link, id = id, name = name,
    class = className, subClass = subClassName, ts = now()
  }
end

if type(hooksecurefunc) == "function" then
  hooksecurefunc("UseContainerItem", function(bag, slot, onSelf, ...)
    pcall(RememberBagUse, bag, slot)
  end)
else
  -- super old clients fallback: hook the item button click (also secure)
  if type(hooksecurefunc) == "function" and ContainerFrameItemButton_OnModifiedClick then
    hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self, button)
      if button == "RightButton" then
        local bag = self:GetParent() and self:GetParent():GetID()
        local slot = self:GetID()
        if bag and slot then pcall(RememberBagUse, bag, slot) end
      end
    end)
  end
end

------------------------------------------------------------
-- Loot opened
------------------------------------------------------------
local function IsProbablyMobName(name)
  if not name or name == "" then return false end
  if UnitExists("target")    and name == UnitName("target")    then return true end
  if UnitExists("mouseover") and name == UnitName("mouseover") then return true end
  return false
end

local function PushLootEvent(items, moneyCopper, lootGUID, lootKind, lootEntry)
  local src, sKey, g = nil, nil, lootGUID
  local hasSource = (g ~= nil)

  -- NEW: inventory container path (has pending bag open and we marked it earlier)
  if EH._currentContainer then
    src = {
      kind = "container",
      containerKind = "item",
      itemId = EH._currentContainer.itemId,
      itemName = EH._currentContainer.itemName,
    }
    sKey = ContainerSourceKey(EH._currentContainer.itemId, EH._currentContainer.itemName)
  end

  if (not src) and hasSource and lootKind == "Creature" then
    local targetGUID  = (UnitExists("target")    and UnitGUID("target")) or nil
    local mouseGUID   = (UnitExists("mouseover") and UnitGUID("mouseover")) or nil
    local chosenUnit  = (targetGUID == g and "target") or (mouseGUID == g and "mouseover") or nil
    if chosenUnit then
      src, sKey = MobSourceFromUnit(chosenUnit)
    else
      local mid = lootEntry or GetEntryIdFromGUID(g)
      src = { kind="mob", id=mid, guid=g, name=nil }
      sKey = (mid and tostring(mid)) or nil
    end

  elseif (not src) and hasSource and lootKind == "GameObject" then
    local nodeId = lootEntry or GetEntryIdFromGUID(g)
    local nodeName = EH._currentGather and EH._currentGather.nodeName or nil
    src = {
      kind="gather",
      gatherKind = (EH._currentGather and EH._currentGather.gatherKind) or "Container",
      nodeId = nodeId,
      nodeName = nodeName,
      guid = g,
    }
    sKey = NodeSourceKey(nodeId, nodeName)
  end

  -- Fallback to title-detected gather if not bound to GUID (world node title)
  if (not src) and EH._currentGather then
    src = {
      kind="gather",
      gatherKind = EH._currentGather.gatherKind or "Container",
      nodeId = EH._currentGather.nodeId,
      nodeName = EH._currentGather.nodeName,
    }
    sKey = NodeSourceKey(EH._currentGather.nodeId, EH._currentGather.nodeName)
  end

  -- Dead mouseover fallback (mob)
  if (not src) and lastDeadMouseover and (now() - (lastDeadMouseover.t or 0) <= 3) then
    src = {
      kind="mob", id=lastDeadMouseover.id, guid=lastDeadMouseover.guid, name=lastDeadMouseover.name,
      level=lastDeadMouseover.level, classification=lastDeadMouseover.classification,
      creatureType=lastDeadMouseover.creatureType, creatureFamily=lastDeadMouseover.creatureFamily,
      reaction=lastDeadMouseover.reaction, maxHp=lastDeadMouseover.maxHp, maxMana=lastDeadMouseover.maxMana,
    }
    sKey = tostring(lastDeadMouseover.id)
    g = lastDeadMouseover.guid
  end

  -- Recent kill fallback (mob)
  if (not src) and lastMob and (now() - lastMob.t) <= 12 then
    src = {
      kind="mob", id=lastMob.id, guid=lastMob.guid, name=lastMob.name,
      level=lastMob.level, classification=lastMob.classification,
      creatureType=lastMob.creatureType, creatureFamily=lastMob.creatureFamily,
      reaction=lastMob.reaction, maxHp=lastMob.maxHp, maxMana=lastMob.maxMana,
    }
    sKey = tostring(lastMob.id)
    g = lastMob.guid
  end

  -- Kill credit only for mobs (never nodes/containers)
  if src and src.kind == "mob" and g and not killSeenRecently(g) then
    markKill(g)
    PushKillEventFromSource(src)
  end

  -- Corpse GUID loot dedupe (mobs only)
  if hasSource and lootKind == "Creature" and lootSeenRecently(g) then

  -- GameObject GUID loot dedupe (chests/nodes)
  if hasSource and lootKind == "GameObject" and lootSeenRecently(g) then
    log("loot skipped (gameobject GUID cooldown) guid="..tostring(g))
    return
  end

    log("loot skipped (corpse GUID cooldown) guid="..tostring(g))
    return
  end

  if (not sKey) and hasSource and lootKind == "Creature" then
    local mid = lootEntry or GetEntryIdFromGUID(g)
    sKey = tostring(mid or g)
  end
  if not sKey then
    sKey = "unknown"
  end

  -- Token-based de-dupe for non-GUID cases (inventory containers, title-only nodes), or as an extra safety.
  do
    local _src = src
    local _tok = BuildLootToken(_src, sKey, g, lootKind, items, moneyCopper)
    if lootTokenSeenRecently(_tok) then
      log("loot skipped (token cooldown) token="..tostring(_tok))
      return
    end
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

  -- attempt counters
  if src and src.kind == "gather" then ev.attempt = 1 end
  if src and src.kind == "container" then ev.attempt = 1 end

  if hasSource and lootKind == "Creature" then markLoot(g) end
  if hasSource and lootKind == "GameObject" then markLoot(g) end
  do
    local _src = src
    local _tok = BuildLootToken(_src, sKey, g, lootKind, items, moneyCopper)
    markLootToken(_tok)
  end

  PUSH(ev)
  log("loot items="..tostring(#items).." srcKey="..tostring(sKey).." attempt="..tostring(ev.attempt or 0))
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
          src = src or {
            kind="mob",
            id=mid, guid=dstGUID, name=lastMob.name,
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
      end
    end
  end
end

------------------------------------------------------------
-- Loot handler
------------------------------------------------------------
local function OnLootOpened()
  local ts = now()
  if (ts - lastLootTs) < LOOT_DEDUPE_WINDOW then return end
  lastLootTs = ts

  -- fishing?
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

  -- Detect source + title (for gather)
  EH._currentGather    = nil
  EH._currentContainer = nil

  local nodeTitle = _G.LootFrameTitleText and _G.LootFrameTitleText.GetText and _G.LootFrameTitleText:GetText() or nil
  local lootGUID, lootKind, lootEntry = DetectLootSource()

  -- NEW: if we just used a bag item and it looks like a container, flag as inventory container.
  if EH._pendingBagOpen and (now() - (EH._pendingBagOpen.ts or 0) <= 8) then
    local po = EH._pendingBagOpen
    local looks = LooksLikeContainerItem(po.name, po.class, po.subClass)
    -- If no GUID source (not a mob/go) OR title classifies container, treat as item-container
    if looks and (not lootGUID or (nodeTitle and ClassifyFromTitle(nodeTitle) == "Container")) then
      EH._currentContainer = { itemId = po.id, itemName = po.name }
      log(("inventory container detected: %s (id=%s)"):format(tostring(po.name or "?"), tostring(po.id or "?")))
    end
  end

  if (not EH._currentContainer) and nodeTitle and nodeTitle ~= "" then
    local kind = ClassifyFromTitle(nodeTitle) or "Container"
    local nodeId = (lootKind == "GameObject") and lootEntry or nil
    EH._currentGather = {
      gatherKind=kind, nodeName=nodeTitle, nodeId=nodeId,
      sourceKey = NodeSourceKey(nodeId, nodeTitle)
    }
    log(("gather detect: %s node='%s' id=%s -> %s")
        :format(kind, nodeTitle, tostring(nodeId or "?"), EH._currentGather.sourceKey))
  end

  -- Collect items/coins
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

  -- Mining inference only if no loot GUID and no node title/container already set
  if (not EH._currentContainer) and (not EH._currentGather) and (lootGUID == nil) then
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
      local inferredNode = firstOreName and (firstOreName .. " Node") or "Mining Node"
      EH._currentGather = {
        gatherKind="Mining", nodeName=inferredNode, nodeId=nil,
        sourceKey=NodeSourceKey(nil, inferredNode)
      }
      log(("gather infer: Mining by loot composition (%d/%d) -> %s"):format(oreLike, total, EH._currentGather.sourceKey))
    end
  end

  if #items > 0 or moneyCopper > 0 then
    PushLootEvent(items, (moneyCopper > 0) and moneyCopper or nil, lootGUID, lootKind, lootEntry)
  else
    log("loot opened but no items/coins found")
  end
end

------------------------------------------------------------
-- Quests + frame registration
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
  local g = UnitGUID(unit); local id = g and GetEntryIdFromGUID(g) or nil
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
  local ev = {
    type = "quest", subtype = "accept", t = now(), session = EH.session,
    id = qid, title = title, text = description, objectives = objectives,
    giver = BuildNPCFromUnit("target"),
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

f:SetScript("OnEvent", function(self, event, ...)
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

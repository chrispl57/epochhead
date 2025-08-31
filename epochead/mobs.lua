local ADDON_NAME, EH = ...

-- Fallback GUID -> NPC ID helper (only if util.lua hasn't defined it yet)
if not EH.GetNPCIDFromGUID then
  function EH.GetNPCIDFromGUID(guid)
    if not guid then return nil end
    local s = tostring(guid)

    -- Retail/Classic: Creature-...-<npcId>-...
    local id = s:match("Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
            or s:match("%-([0-9]+)%-[0-9A-Fa-f]+$")
            or s:match("%-([0-9]+)%-[^%-]+$")
    if id then return tonumber(id) end

    -- 3.3.5 hex GUID: 0xF130000CAC001E20 (NPC id is chars 7..12 -> '000CAC')
    if s:sub(1,2) == "0x" and #s >= 12 then
      local hexid = s:sub(7,12)
      if hexid:match("^[0-9A-Fa-f]+$") then
        local num = tonumber(hexid, 16)
        if num and num > 0 then return num end
      end
    end
    return nil
  end
end

-- Fallback position helper (only if util.lua hasn't defined it yet)
if not EH.Pos then
  function EH.Pos()
    local z = (GetZoneText and GetZoneText()) or (GetRealZoneText and GetRealZoneText()) or ""
    local s = (GetSubZoneText and GetSubZoneText()) or ""
    local x, y = 0, 0

    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
      local uiMapID = C_Map.GetBestMapForUnit("player")
      if uiMapID then
        local pos = C_Map.GetPlayerMapPosition(uiMapID, "player")
        if pos then x = pos.x or 0; y = pos.y or 0 end
      end
    elseif GetPlayerMapPosition then
      local px, py = GetPlayerMapPosition("player")
      if px and py then x, y = px or 0, py or 0 end
    end

    -- match util.lua behavior: normalized 0..1 with 4 decimals
    x = math.floor((x or 0) * 10000) / 10000
    y = math.floor((y or 0) * 10000) / 10000
    return z, s, x, y
  end
end

EH.mobSnap = {}

local function UnitIsNPC(unit) return UnitExists(unit) and not UnitIsPlayer(unit) end
EH.UnitIsNPC = UnitIsNPC

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


function EH.dprint_snap(unit, snap)
  if not (epochheadDB.state and epochheadDB.state.debug) then return end
  if unit ~= "target" then return end
  local guid = snap and snap.guid
  local nowt = EH.now()
  _G.__eh_lastSnapPrint = _G.__eh_lastSnapPrint or {}
  local last = _G.__eh_lastSnapPrint[guid] or 0
  if (nowt - last) >= 3 then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r snap max "..(snap.name or "?").." HP "..tostring(snap.maxHp or 0).." Mana "..tostring(snap.maxMana or 0))
    _G.__eh_lastSnapPrint[guid] = nowt
  end
end

function EH.snapshotUnit(unit)
  if not UnitExists(unit) then return nil end
  local guid = UnitGUID(unit)
  if not guid then return nil end
  local z,s,x,y = EH.Pos()
  EH.mobSnap[guid] = {
    guid = guid,
    id = (EH.GetNPCIDFromGUID and EH.GetNPCIDFromGUID(guid)),
    name = UnitName(unit),
    level = UnitLevel(unit),
    classification = (UnitClassification and UnitClassification(unit)) or nil,
    creatureType = (UnitCreatureType and UnitCreatureType(unit)) or nil,
    creatureFamily = (UnitCreatureFamily and UnitCreatureFamily(unit)) or nil,
    reaction = (UnitReaction and UnitReaction(unit, "player")) or nil,
    maxHp = UnitHealthMax(unit),
    maxMana = UnitManaMax(unit),
    powerType = (select(2, UnitPowerType(unit))) or "MANA",
    zone = z, subzone = s, x = x, y = y,
    t = EH.now(),
  }
  EH.dprint_snap(unit, EH.mobSnap[guid])
  return EH.mobSnap[guid]
end

EH.recentDeaths = {}
EH.recentDeathsList = {}
EH.lastDeathGUID = nil

function EH.rememberDeath(guid, name)
  local z,s,x,y = EH.Pos()
  local snap = EH.mobSnap[guid] or { guid=guid, id=(EH.GetNPCIDFromGUID and EH.GetNPCIDFromGUID(guid)), name=name }
  snap.t = EH.now(); snap.zone = z; snap.subzone = s; snap.x = x; snap.y = y
  EH.mobSnap[guid] = snap
  local rec = { guid=guid, npcId = snap.id, name = snap.name, t = EH.now(), zone=z, subzone=s, x=x, y=y }
  EH.recentDeaths[guid] = rec
  EH.recentDeathsList[#EH.recentDeathsList+1] = rec
  EH.lastDeathGUID = guid
  local cutoff = EH.now()-30
  local keep = {}
  for i=#EH.recentDeathsList,1,-1 do
    local r = EH.recentDeathsList[i]
    if (r.t or 0) >= cutoff then table.insert(keep, 1, r) end
  end
  EH.recentDeathsList = keep
  if #EH.recentDeathsList > 120 then
    for i=1,(#EH.recentDeathsList-120) do EH.recentDeathsList[i] = nil end
  end
end

function EH.matchRecentKill(zone, x, y, maxAge, maxD2)
  maxAge = maxAge or 20
  maxD2 = maxD2 or 0.0025
  local tnow = EH.now()
  local best, bestD2
  for i=#EH.recentDeathsList,1,-1 do
    local r = EH.recentDeathsList[i]
    if (tnow - (r.t or 0)) > maxAge then break end
    if (r.zone or "") == (zone or "") then
      local dx = (x or 0) - (r.x or 0)
      local dy = (y or 0) - (r.y or 0)
      local d2 = dx*dx + dy*dy
      if (not bestD2) or d2 < bestD2 then best, bestD2 = r, d2 end
    end
  end
  if best and bestD2 and bestD2 <= maxD2 then return best end
  return nil
end

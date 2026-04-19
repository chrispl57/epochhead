local ADDON_NAME, EH = ...

-- util.lua provides EH.GetEntryIdFromGUID / EH.GetNPCIDFromGUID and EH.Pos

EH.mobSnap = {}

local function UnitIsNPC(unit) return UnitExists(unit) and not UnitIsPlayer(unit) end
EH.UnitIsNPC = UnitIsNPC

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

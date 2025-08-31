local ADDON_NAME, EH = ...

local function GetSkillRanks()
  local out = {}
  if not GetNumSkillLines then return out end
  for i=1, GetNumSkillLines() do
    local name, isHeader, _, rank = GetSkillLineInfo(i)
    if name and not isHeader then out[name] = rank end
  end
  return out
end
EH.GetSkillRanks = GetSkillRanks

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


function EH.GatherSkillFor(typeName)
  local skills = GetSkillRanks()
  if typeName == "herb" then return skills["Herbalism"] or skills["Herb Gathering"] or nil end
  if typeName == "mining" then return skills["Mining"] or nil end
  if typeName == "skinning" then return skills["Skinning"] or nil end
  if typeName == "fishing" then return skills["Fishing"] or nil end
  return nil
end

EH.GATHER = {
  herb     = { id=2366, names={GetSpellInfo(2366), "Herb Gathering"} },
  mining   = { id=2575, names={GetSpellInfo(2575), "Mining"} },
  skinning = { id=8613, names={GetSpellInfo(8613), "Skinning"} },
}
function EH.matchGather(spellID, spellName)
  if spellID then
    for k,v in pairs(EH.GATHER) do if v.id == spellID then return k end end
  end
  local s = (spellName and spellName:lower() or "")
  for k,v in pairs(EH.GATHER) do
    for _,n in ipairs(v.names) do if n and s == n:lower() then return k end end
  end
  return nil
end

EH.lastGather = nil
function EH.rememberGather(gType)
  local z,s,x,y = EH.Pos()
  local attemptKey = string.format("%d-%s", EH.now(), EH.rngHex(6))
  EH.lastGather = { type=gType, nodeName=EH.lastTooltipTitle, zone=z, subzone=s, x=x, y=y, t=EH.now(), success=false, attemptKey=attemptKey }
  EH.dprint("gather start:", gType, EH.lastTooltipTitle or "?")
  local srcObj = { kind="node", type=gType, name= EH.lastTooltipTitle or (gType=="herb" and "Herb Node" or gType=="mining" and "Mining Node" or "Gather Node"),
                   zone=z, subzone=s, x=x, y=y }
  srcObj.key = EH.sourceKeyForNode(gType, EH.lastTooltipTitle, z, s)
  EH.push({
    t=EH.now(), type="gather_attempt", attemptKey=attemptKey,
    source=srcObj, sourceKey=srcObj.key,
    zone=z, subzone=s, x=x, y=y,
    gather={ type=gType, nodeName=EH.lastTooltipTitle, x=x, y=y, z=z, s=s }
  })
end

EH.TRANSFORM_SPELLS = {
  [13262] = "disenchant",
  [31252] = "prospect",
  [51005] = "mill",
  [921]   = "pickpocket",
}
EH.transformPending = nil

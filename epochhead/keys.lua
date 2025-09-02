-- Back-compat: normalize any legacy "mob:ID" keys to "ID"
local function normalizeMobKey(k)
    if type(k) == "string" then
        return (k:gsub("^mob:", ""))
    end
    return k
end

local ADDON_NAME, EH = ...

-- Mob keys: prefer numeric NPC ID; fallback to GUID
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
function EH.sourceKeyForFishing(zone, subzone)
  local z = tostring(zone or "")
  local s = tostring(subzone or "")
  if z == "" and s == "" then return "fishing" end
  return "fishing:" .. z .. (s ~= "" and (":"..s) or "")
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


function EH.sourceKeyForMob(id, guid)
  if (not id) and guid and EH.GetNPCIDFromGUID then
    local nid = EH.GetNPCIDFromGUID(guid)
    if nid then id = nid end
  end
  if id   then return tostring(id) end
  if guid then return "mob_guid:" .. tostring(guid) end
  return "mob:unknown"
end

-- Node keys: "node:<type>:<name or zone[:subzone]>"
function EH.sourceKeyForNode(gType, nodeName, zone, subzone)
  gType = gType or "gather"
  local name = nodeName or (zone or "")
  if (subzone and subzone ~= "") then
    name = (name ~= "" and (name .. ":" .. subzone)) or subzone
  end
  return "node:" .. gType .. ":" .. name
end

-- Fishing keys: "fishing:<zone>[:subzone]"
function EH.sourceKeyForFishing(zone, subzone)
  local key = "fishing:" .. (zone or "")
  if (subzone and subzone ~= "") then key = key .. ":" .. subzone end
  return key
end

-- Vendor keys: prefer numeric ID, fallback to GUID, else label
function EH.sourceKeyForVendor(id, guid, name)
  if id   then return "vendor:" .. tostring(id) end
  if guid then return "vendor_guid:" .. tostring(guid) end
  return "vendor:" .. (name or "unknown")
end

-- Container keys: "container:<label>" or "container:Container - zone[:subzone]"
function EH.sourceKeyForContainer(label, zone, subzone)
  local name = label
  if (not name) or name == "" then
    name = "Container"
    if zone and zone ~= "" then
      name = name .. " - " .. zone
      if subzone and subzone ~= "" then name = name .. ":" .. subzone end
    end
  end
  return "container:" .. name
end

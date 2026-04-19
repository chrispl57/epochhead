-- Back-compat: normalize any legacy "mob:ID" keys to "ID"
local function normalizeMobKey(k)
    if type(k) == "string" then
        return (k:gsub("^mob:", ""))
    end
    return k
end

local ADDON_NAME, EH = ...

-- Mob keys: prefer numeric NPC ID; fallback to GUID
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

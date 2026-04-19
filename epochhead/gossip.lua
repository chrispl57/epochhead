local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Gossip + flight master scans
-- GOSSIP_SHOW  -> gossip options/available/active quests per NPC
-- TAXIMAP_OPENED -> known flight nodes at current flight master
------------------------------------------------------------

local function now() return (EH.now and EH.now()) or time() end

local function chat(msg)
  if not EH._debug then return end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r " .. tostring(msg))
  end
end

local function buildNPCSource(kind)
  local unit = "npctarget"
  if not (UnitExists and UnitExists(unit)) then unit = "target" end
  if not (UnitExists and UnitExists(unit)) then return nil end
  local guid = UnitGUID and UnitGUID(unit) or nil
  local id   = guid and EH.GetEntryIdFromGUID and EH.GetEntryIdFromGUID(guid) or nil
  local name = UnitName and UnitName(unit) or nil
  local src = { kind = kind or "npc", id = id, guid = guid, name = name }
  if EH.Pos then
    local z, s, x, y = EH.Pos()
    src.zone, src.subzone, src.x, src.y = z, s, x, y
  end
  return src
end

------------------------------------------------------------
-- GOSSIP_SHOW
------------------------------------------------------------
local gossipDedupe = {}
local GOSSIP_TTL = 600

local function pairsToRows(args, stride)
  -- GetGossipOptions / GetGossipAvailableQuests / GetGossipActiveQuests
  -- return flat varargs; group them by stride.
  local rows = {}
  if not args or #args == 0 then return rows end
  for i = 1, #args, stride do
    local row = {}
    for k = 0, stride - 1 do row[k + 1] = args[i + k] end
    rows[#rows + 1] = row
  end
  return rows
end

local function packVararg(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = (select(i, ...)) end
  return t
end

local function onGossipShow()
  local src = buildNPCSource("gossip")
  if not src then return end
  local key = src.id and ("gossip:" .. tostring(src.id)) or nil
  if key and gossipDedupe[key] and (now() - gossipDedupe[key]) < GOSSIP_TTL then return end

  local options = {}
  if GetGossipOptions then
    local raw = packVararg(GetGossipOptions())
    local rows = pairsToRows(raw, 2) -- (text, type)
    for _, r in ipairs(rows) do
      options[#options + 1] = { text = r[1], gossipType = r[2] }
    end
  end

  local available = {}
  if GetGossipAvailableQuests then
    local raw = packVararg(GetGossipAvailableQuests())
    -- 3.3.5: (title, level, trivial, isDaily, isRepeatable)  stride=5
    local rows = pairsToRows(raw, 5)
    for _, r in ipairs(rows) do
      available[#available + 1] = {
        title = r[1], level = r[2], trivial = r[3],
        isDaily = r[4], isRepeatable = r[5],
      }
    end
  end

  local active = {}
  if GetGossipActiveQuests then
    local raw = packVararg(GetGossipActiveQuests())
    -- 3.3.5: (title, level, trivial, isComplete)  stride=4
    local rows = pairsToRows(raw, 4)
    for _, r in ipairs(rows) do
      active[#active + 1] = {
        title = r[1], level = r[2], trivial = r[3], isComplete = r[4],
      }
    end
  end

  if #options == 0 and #available == 0 and #active == 0 then return end
  if key then gossipDedupe[key] = now() end

  local ev = {
    type = "gossip_snapshot",
    t = now(),
    source = src,
    sourceKey = src.id and ("npc:" .. tostring(src.id)) or nil,
    options = options,
    availableQuests = available,
    activeQuests = active,
  }
  if EH.push then EH.push(ev) end
  chat(("gossip scanned: %d opts, %d avail, %d active"):format(#options, #available, #active))
end

------------------------------------------------------------
-- TAXIMAP_OPENED — flight master nodes
------------------------------------------------------------
local flightDedupe = {}
local FLIGHT_TTL = 600

local function onTaximapOpened()
  if not NumTaxiNodes or not TaxiNodeName then return end
  local src = buildNPCSource("flightmaster")
  if not src then return end
  local key = src.id and ("fm:" .. tostring(src.id)) or ("fm-name:" .. tostring((src.name or "unknown"):lower():gsub("%s+", "_")))
  if flightDedupe[key] and (now() - flightDedupe[key]) < FLIGHT_TTL then return end

  local n = NumTaxiNodes() or 0
  if n == 0 then return end

  local nodes = {}
  for i = 1, n do
    local nm   = TaxiNodeName(i)
    local x    = TaxiNodePosition and select(1, TaxiNodePosition(i)) or nil
    local y    = TaxiNodePosition and select(2, TaxiNodePosition(i)) or nil
    local typ  = TaxiNodeGetType and TaxiNodeGetType(i) or nil
    local cost = TaxiNodeCost and TaxiNodeCost(i) or nil
    nodes[#nodes + 1] = {
      index = i,
      name  = nm,
      x     = x,
      y     = y,
      type  = typ, -- "NONE"|"CURRENT"|"REACHABLE"|"UNREACHABLE"|"DISTANT"
      cost  = cost, -- copper from current to this node
    }
  end

  flightDedupe[key] = now()
  local ev = {
    type = "flightmaster_snapshot",
    t = now(),
    source = src,
    sourceKey = src.id and ("flightmaster:" .. tostring(src.id)) or key,
    nodes = nodes,
    continentId = GetCurrentMapContinent and GetCurrentMapContinent() or nil,
  }
  if EH.push then EH.push(ev) end
  chat(("taxi scanned %d nodes at %s"):format(#nodes, tostring(src.name or "?")))
end

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("GOSSIP_SHOW")
  f:RegisterEvent("TAXIMAP_OPENED")
  f:SetScript("OnEvent", function(self, event)
    if event == "GOSSIP_SHOW" then
      local ok, err = pcall(onGossipShow)
      if not ok then chat("gossip scan error: " .. tostring(err)) end
    elseif event == "TAXIMAP_OPENED" then
      local ok, err = pcall(onTaximapOpened)
      if not ok then chat("taxi scan error: " .. tostring(err)) end
    end
  end)
end

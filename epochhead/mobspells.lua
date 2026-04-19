local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Mob spell cast tracking via CLEU.
-- Captures SPELL_CAST_START / SPELL_CAST_SUCCESS / SPELL_MISSED
-- from Creature / Vehicle sources so per-mob ability lists can
-- be aggregated server-side.
--
-- Dedupes per (mobId, spellId, subevent) within a window to avoid
-- flooding the queue during long fights (bosses cast the same thing
-- dozens of times a minute).
------------------------------------------------------------

local function now() return (EH.now and EH.now()) or time() end

local function chat(msg)
  if not EH._debug then return end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r " .. tostring(msg))
  end
end

local function guidKind(g)
  if not g then return nil end
  local s = tostring(g)
  if s:find("-", 1, true) then
    local typ = (strsplit("-", s))
    return typ
  end
  local up = s:gsub("^0x", ""):upper()
  local high = up:sub(1, 4)
  if     high == "F130" then return "Creature"
  elseif high == "F150" then return "Vehicle"
  elseif high == "F140" then return "Pet"
  elseif high == "F110" then return "GameObject"
  else return "Unknown" end
end

local TRACKED = {
  SPELL_CAST_START   = true,
  SPELL_CAST_SUCCESS = true,
  SPELL_MISSED       = true,
  SPELL_AURA_APPLIED = true, -- helps flag self-buffs (e.g., enrage)
}

-- Dedupe key TTL (per mob+spell+subevent); reset on new CLEU entry.
local TTL = 30
local seen = {}
local lastPrune = 0

local function maybePrune()
  local n = now()
  if (n - lastPrune) < 120 then return end
  lastPrune = n
  for k, t in pairs(seen) do
    if (n - t) > TTL then seen[k] = nil end
  end
end

local function onCLEU(_, subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, spellId, spellName, spellSchool, auraType)
  if not TRACKED[subevent] then return end
  if not sourceGUID then return end

  local kind = guidKind(sourceGUID)
  if kind ~= "Creature" and kind ~= "Vehicle" then return end

  local mobId = EH.GetEntryIdFromGUID and EH.GetEntryIdFromGUID(sourceGUID) or nil
  if not mobId then return end
  if not spellId or spellId == 0 then return end

  -- For SPELL_AURA_APPLIED only keep self-applied (enrage-style) casts.
  if subevent == "SPELL_AURA_APPLIED" then
    if sourceGUID ~= destGUID then return end
    if auraType ~= "BUFF" then return end
  end

  local key = tostring(mobId) .. ":" .. tostring(spellId) .. ":" .. subevent
  local n = now()
  if seen[key] and (n - seen[key]) < TTL then return end
  seen[key] = n
  maybePrune()

  local src = {
    kind = "mob",
    id = mobId,
    guid = sourceGUID,
    name = sourceName,
  }
  if EH.Pos then
    local z, s, x, y = EH.Pos()
    src.zone, src.subzone, src.x, src.y = z, s, x, y
  end

  local ev = {
    type = "mob_spell_cast",
    t = now(),
    source = src,
    sourceKey = "mob:" .. tostring(mobId),
    subevent = subevent,
    spellId = spellId,
    spellName = spellName,
    spellSchool = spellSchool,
  }
  if subevent == "SPELL_MISSED" then
    -- destFlags position varies; we only want to note it happened.
    ev.target = { guid = destGUID, name = destName }
  end
  if EH.push then EH.push(ev) end
end

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  f:SetScript("OnEvent", function(self, event, ...)
    if event ~= "COMBAT_LOG_EVENT_UNFILTERED" then return end
    local ok, err = pcall(onCLEU, ...)
    if not ok then chat("mobspells cleu error: " .. tostring(err)) end
  end)
end

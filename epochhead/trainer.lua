local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Trainer scan (TRAINER_SHOW)
-- Captures GetTrainerServiceInfo rows (spell, cost, req) into a
-- trainer_snapshot event keyed by the target NPC (trainer).
------------------------------------------------------------

local function now() return (EH.now and EH.now()) or time() end

local function chat(msg)
  if not EH._debug then return end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r " .. tostring(msg))
  end
end

-- Per-trainer dedupe within session (don't spam 50 copies of same list)
local TRAINER_TTL = 600
local lastSent = {}
local function seenRecently(key)
  local t = lastSent[key]
  return t and ((now() - t) < TRAINER_TTL)
end
local function markSent(key) lastSent[key] = now() end

local function buildNPCSource()
  local unit = "npctarget"
  if not (UnitExists and UnitExists(unit)) then unit = "target" end
  if not (UnitExists and UnitExists(unit)) then return nil end
  local guid = UnitGUID and UnitGUID(unit) or nil
  local id   = guid and EH.GetEntryIdFromGUID and EH.GetEntryIdFromGUID(guid) or nil
  local name = UnitName and UnitName(unit) or nil
  local src = { kind = "trainer", id = id, guid = guid, name = name }
  if EH.Pos then
    local z, s, x, y = EH.Pos()
    src.zone, src.subzone, src.x, src.y = z, s, x, y
  end
  return src
end

local function getServiceSpell(idx)
  if not GetTrainerServiceInfo then return nil end
  local name, rank, category, expanded = GetTrainerServiceInfo(idx)
  return name, rank, category
end

local function getServiceCost(idx)
  if GetTrainerServiceCost then
    local cost, texture, numItems = GetTrainerServiceCost(idx)
    return cost or 0
  end
  return 0
end

local function getServiceSkillReq(idx)
  if not GetTrainerServiceSkillReq then return nil, nil end
  local skill, rank = GetTrainerServiceSkillReq(idx)
  return skill, rank
end

local function getServiceAbilityReq(idx)
  if not GetTrainerServiceAbilityReq then return nil end
  local name, rank, met = GetTrainerServiceAbilityReq(idx)
  if name and name ~= "" then
    return { name = name, rank = rank, met = met and true or false }
  end
end

local function getServiceLevelReq(idx)
  if GetTrainerServiceLevelReq then
    return GetTrainerServiceLevelReq(idx)
  end
end

local function getServiceSpellLink(idx)
  if GetTrainerServiceItemLink then
    return GetTrainerServiceItemLink(idx)
  end
end

local function extractSpellId(link)
  if not link then return nil end
  local id = tostring(link):match("Hspell:(%d+)") or tostring(link):match("Htrade:(%d+)")
  return id and tonumber(id) or nil
end

local function snapshotTrainer()
  if not GetNumTrainerServices then return end
  local src = buildNPCSource()
  if not src then return end
  local key = src.id and ("trainer:" .. tostring(src.id)) or ("trainer-name:" .. tostring((src.name or "unknown"):lower():gsub("%s+", "_")))
  if seenRecently(key) then return end

  local n = GetNumTrainerServices() or 0
  if n == 0 then return end

  local trainerType = nil
  if GetTrainerServiceTypeFilter then
    -- pass; type filter is per-category, not a fixed attribute
  end

  local items = {}
  for i = 1, n do
    local name, rank, category = getServiceSpell(i)
    if name then
      local cost = getServiceCost(i)
      local skill, skillRank = getServiceSkillReq(i)
      local abilityReq = getServiceAbilityReq(i)
      local levelReq   = getServiceLevelReq(i)
      local link       = getServiceSpellLink(i)
      local spellId    = extractSpellId(link)
      items[#items + 1] = {
        index     = i,
        name      = name,
        rank      = rank,
        category  = category, -- "available" | "used" | "unavailable"
        cost      = cost,
        spellId   = spellId,
        reqSkill  = skill,
        reqSkillLevel = skillRank,
        reqLevel  = levelReq,
        reqAbility = abilityReq,
      }
    end
  end

  if #items == 0 then return end
  markSent(key)

  local ev = {
    type = "trainer_snapshot",
    t = now(),
    source = src,
    sourceKey = key,
    trainerType = (IsTradeskillTrainer and IsTradeskillTrainer()) and "tradeskill" or "class",
    trainerItems = items,
  }
  if EH.push then EH.push(ev) end
  chat(("trainer scanned %d services at %s"):format(#items, tostring(src.name or "?")))
end

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("TRAINER_SHOW")
  f:RegisterEvent("TRAINER_UPDATE")
  f:RegisterEvent("TRAINER_CLOSED")
  local pending = false
  local armedAt = 0
  f:SetScript("OnEvent", function(self, event)
    if event == "TRAINER_CLOSED" then
      pending = false
      return
    end
    pending = true
    armedAt = (GetTime and GetTime() or 0) + 0.3
    self:SetScript("OnUpdate", function(self, elapsed)
      local t = GetTime and GetTime() or 0
      if t < armedAt then return end
      self:SetScript("OnUpdate", nil)
      if pending then
        pending = false
        local ok, err = pcall(snapshotTrainer)
        if not ok then chat("trainer snapshot error: " .. tostring(err)) end
      end
    end)
  end)
end

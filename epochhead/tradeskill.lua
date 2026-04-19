local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Tradeskill / Crafting recipes (TRADE_SKILL_SHOW/UPDATE)
-- Also handles Enchanting via CraftFrame hooks because 3.3.5
-- splits enchanting into a separate Craft API.
------------------------------------------------------------

local function now() return (EH.now and EH.now()) or time() end

local function chat(msg)
  if not EH._debug then return end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r " .. tostring(msg))
  end
end

-- Per-skill dedupe: only re-emit when either rank or recipe count
-- has changed since the last push.
local lastSigBySkill = {}

local function extractSpellId(link)
  if not link then return nil end
  local id = tostring(link):match("Hspell:(%d+)") or tostring(link):match("Henchant:(%d+)") or tostring(link):match("Htrade:(%d+)")
  return id and tonumber(id) or nil
end

local function extractItemId(link)
  if not link then return nil end
  local id = tostring(link):match("Hitem:(%d+)")
  return id and tonumber(id) or nil
end

------------------------------------------------------------
-- TradeSkill (professions other than Enchanting)
------------------------------------------------------------
local function scanTradeSkill()
  if not GetTradeSkillLine or not GetNumTradeSkills then return end
  local profession, rank, maxRank = GetTradeSkillLine()
  if not profession or profession == "UNKNOWN" then return end

  local n = GetNumTradeSkills() or 0
  if n == 0 then return end

  local recipes = {}
  for i = 1, n do
    local name, typ, numAvail, isExpanded = GetTradeSkillInfo(i)
    if name and typ ~= "header" then
      local link = GetTradeSkillItemLink and GetTradeSkillItemLink(i) or nil
      local recipeLink = GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(i) or nil
      local minMade, maxMade = nil, nil
      if GetTradeSkillNumMade then minMade, maxMade = GetTradeSkillNumMade(i) end
      local toolsOk, reagentsOk = nil, nil
      if GetTradeSkillTools then
        toolsOk = GetTradeSkillTools(i)
      end
      local reqSkill, yellow, green, grey = nil, nil, nil, nil
      if GetTradeSkillItemLevelFilter then
        -- stub; 3.3.5 doesn't expose this directly
      end
      -- Color of difficulty is encoded in `typ` (optimal/medium/easy/trivial/difficult)
      local difficulty = typ -- "optimal"|"trivial"|"difficult"|"easy"|"medium"

      local reagents = {}
      local nReag = GetTradeSkillNumReagents and GetTradeSkillNumReagents(i) or 0
      for r = 1, nReag do
        local rName, rTex, rNeeded, rHave = GetTradeSkillReagentInfo(i, r)
        local rLink = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i, r) or nil
        reagents[#reagents + 1] = {
          name   = rName,
          itemId = extractItemId(rLink),
          count  = rNeeded,
        }
      end

      recipes[#recipes + 1] = {
        index      = i,
        name       = name,
        difficulty = difficulty,
        resultItemId = extractItemId(link),
        resultLink = link,
        spellId    = extractSpellId(recipeLink),
        minMade    = minMade,
        maxMade    = maxMade,
        reagents   = reagents,
      }
    end
  end

  if #recipes == 0 then return end

  local sig = profession .. ":" .. tostring(rank or 0) .. ":" .. tostring(#recipes)
  if lastSigBySkill[profession] == sig then return end
  lastSigBySkill[profession] = sig

  local ev = {
    type = "tradeskill_snapshot",
    t = now(),
    skill = {
      name = profession,
      rank = rank,
      maxRank = maxRank,
    },
    recipes = recipes,
  }
  if EH.push then EH.push(ev) end
  chat(("tradeskill scanned %d recipes in %s (%s/%s)"):format(#recipes, tostring(profession), tostring(rank or 0), tostring(maxRank or 0)))
end

------------------------------------------------------------
-- Craft (Enchanting on 3.3.5)
------------------------------------------------------------
local function scanCraft()
  if not GetCraftName or not GetNumCrafts then return end
  local craftName = GetCraftName()
  if not craftName or craftName == "UNKNOWN" then return end

  local n = GetNumCrafts() or 0
  if n == 0 then return end

  local recipes = {}
  local rank, maxRank = nil, nil
  if GetCraftDisplaySkillLine then
    local _, r, m = GetCraftDisplaySkillLine()
    rank, maxRank = r, m
  end

  for i = 1, n do
    local name, subSpellName, typ, numAvail, isExpanded = GetCraftInfo(i)
    if name and typ ~= "header" then
      local link = GetCraftItemLink and GetCraftItemLink(i) or nil
      local reagents = {}
      local nReag = GetCraftNumReagents and GetCraftNumReagents(i) or 0
      for r = 1, nReag do
        local rName, rTex, rNeeded, rHave = GetCraftReagentInfo(i, r)
        local rLink = GetCraftReagentItemLink and GetCraftReagentItemLink(i, r) or nil
        reagents[#reagents + 1] = {
          name   = rName,
          itemId = extractItemId(rLink),
          count  = rNeeded,
        }
      end
      recipes[#recipes + 1] = {
        index    = i,
        name     = name,
        subRank  = subSpellName, -- e.g., "Apprentice", or rune rank
        difficulty = typ,
        spellId  = extractSpellId(link),
        resultLink = link,
        reagents = reagents,
      }
    end
  end

  if #recipes == 0 then return end

  local sig = craftName .. ":" .. tostring(rank or 0) .. ":" .. tostring(#recipes)
  if lastSigBySkill[craftName] == sig then return end
  lastSigBySkill[craftName] = sig

  local ev = {
    type = "tradeskill_snapshot",
    t = now(),
    skill = {
      name = craftName,
      rank = rank,
      maxRank = maxRank,
      isCraft = true,
    },
    recipes = recipes,
  }
  if EH.push then EH.push(ev) end
  chat(("craft scanned %d recipes in %s"):format(#recipes, tostring(craftName)))
end

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("TRADE_SKILL_SHOW")
  f:RegisterEvent("TRADE_SKILL_UPDATE")
  f:RegisterEvent("TRADE_SKILL_CLOSE")
  f:RegisterEvent("CRAFT_SHOW")
  f:RegisterEvent("CRAFT_UPDATE")
  f:RegisterEvent("CRAFT_CLOSE")

  local pending = nil
  local armedAt = 0
  f:SetScript("OnEvent", function(self, event)
    if event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
      pending = nil
      return
    end
    if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
      pending = "trade"
    elseif event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then
      pending = "craft"
    end
    armedAt = (GetTime and GetTime() or 0) + 0.4
    self:SetScript("OnUpdate", function(self, elapsed)
      local t = GetTime and GetTime() or 0
      if t < armedAt then return end
      self:SetScript("OnUpdate", nil)
      local kind = pending
      pending = nil
      if not kind then return end
      local ok, err
      if kind == "trade" then
        ok, err = pcall(scanTradeSkill)
      else
        ok, err = pcall(scanCraft)
      end
      if not ok then chat("tradeskill scan error: " .. tostring(err)) end
    end)
  end)
end

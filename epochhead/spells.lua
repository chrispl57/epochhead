local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Global spell database collector.
--
-- Observes every spellId the client touches (CLEU casts from any source,
-- trainer services, recipes, quest reward previews, item procs) and emits
-- a single `spell_info` event per unique id per session containing:
--   - base metadata from GetSpellInfo (name, rank, icon, castTime, range)
--   - scraped tooltip lines via a hidden GameTooltip on "spell:<id>"
------------------------------------------------------------

local function now() return (EH.now and EH.now()) or time() end

local function chat(msg)
  if not EH._debug then return end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r " .. tostring(msg))
  end
end

-- Hidden tooltip scanner
local scanner
local function getScanner()
  if scanner then return scanner end
  if not CreateFrame then return nil end
  scanner = CreateFrame("GameTooltip", "EpochHeadSpellScanner", UIParent, "GameTooltipTemplate")
  scanner:SetOwner(UIParent, "ANCHOR_NONE")
  return scanner
end

local function scrapeTooltip(spellId)
  local tt = getScanner()
  if not tt then return nil end
  tt:ClearLines()
  local ok = pcall(function() tt:SetHyperlink("spell:" .. tostring(spellId)) end)
  if not ok then return nil end
  local lines = {}
  local nLines = tt:NumLines() or 0
  for i = 1, nLines do
    local fs = _G["EpochHeadSpellScannerTextLeft" .. i]
    local text = fs and fs.GetText and fs:GetText() or nil
    if text and text ~= "" then lines[#lines + 1] = text end
  end
  if #lines == 0 then return nil end
  return lines
end

-- Session-scoped "already sent" set so we emit one event per spell per login.
local sent = {}

-- In WoW 3.3.5, UNIT_SPELLCAST_SUCCEEDED provides no spellId and name
-- lookup APIs are missing. Use GetSpellBookItemInfo to get spellId directly
-- per slot, then confirm via GetSpellInfo(id) for name/rank matching.
local function resolveSpellIdFromBook(spellName, rank)
  if not spellName or not GetNumSpellTabs or not GetSpellBookItemInfo then return nil end
  local numTabs = GetNumSpellTabs()
  chat(("book scan: '%s' '%s' in %d tabs"):format(spellName, tostring(rank or ""), numTabs))
  for tab = 1, numTabs do
    local _, _, offset, count = GetSpellTabInfo(tab)
    for i = offset + 1, offset + count do
      local ok, skillType, sid = pcall(GetSpellBookItemInfo, i, "spell")
      if not ok then
        chat(("book scan err slot %d: %s"):format(i, tostring(skillType)))
        break
      end
      if sid and sid ~= 0 and GetSpellInfo then
        local sName, sRank = GetSpellInfo(sid)
        if sName == spellName and (not rank or sRank == rank) then
          chat(("book scan matched: slot=%d id=%d"):format(i, sid))
          return sid
        end
      end
    end
  end
  chat("book scan: no match")
  return nil
end

function EH.NoteSpellId(spellId, sourceHint)
  if not spellId then return end
  local id = tonumber(spellId)
  if not id or id <= 0 then return end
  if sent[id] then
    chat(("spell already noted this session: %d (src=%s)"):format(id, tostring(sourceHint or "?")))
    return
  end

  local name, rank, icon, castTime, minRange, maxRange, sid
  if GetSpellInfo then
    name, rank, icon, castTime, minRange, maxRange, sid = GetSpellInfo(id)
  end
  -- GetSpellInfo returns nothing for ids the client doesn't know. Still
  -- emit a skeleton so the server learns the id existed in the wild.
  sent[id] = true

  local playerLevel = UnitLevel and UnitLevel("player") or nil
  local tooltip = scrapeTooltip(id)

  local ev = {
    type = "spell_info",
    t = now(),
    spellId = id,
    name = name,
    rank = rank,
    icon = icon,
    castTime = castTime,
    minRange = minRange,
    maxRange = maxRange,
    tooltip = tooltip,
    observer = {
      level = playerLevel,
      class = UnitClass and select(2, UnitClass("player")) or nil,
    },
    sourceHint = sourceHint,
  }
  chat(("spell noted: %d %s (src=%s)"):format(id, tostring(name or "?"), tostring(sourceHint or "?")))
  if EH.push then EH.push(ev) end
end

-- CLEU catch-all: any spell id that flows through combat log gets noted.
local CLEU_SPELL_EVENTS = {
  SPELL_CAST_START = true,
  SPELL_CAST_SUCCESS = true,
  SPELL_CAST_FAILED = true,
  SPELL_MISSED = true,
  SPELL_DAMAGE = true,
  SPELL_HEAL = true,
  SPELL_PERIODIC_DAMAGE = true,
  SPELL_PERIODIC_HEAL = true,
  SPELL_AURA_APPLIED = true,
  SPELL_AURA_REMOVED = true,
  SPELL_AURA_REFRESH = true,
  SPELL_SUMMON = true,
  SPELL_RESURRECT = true,
  SPELL_DISPEL = true,
  SPELL_INTERRUPT = true,
  SPELL_ENERGIZE = true,
}

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  f:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
      local _, subevent, _, _, _, _, _, _, _, _, _, spellId = ...
      if CLEU_SPELL_EVENTS[subevent] and spellId and spellId ~= 0 then
        local ok, err = pcall(EH.NoteSpellId, spellId, "cleu")
        if not ok then chat("spells cleu err: " .. tostring(err)) end
      end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      local unit, spellName, rank, lineId, spellId = ...
      chat(("UNIT_SPELLCAST_SUCCEEDED: unit=%s name=%s rank=%s lineId=%s spellId=%s"):format(
        tostring(unit), tostring(spellName), tostring(rank), tostring(lineId), tostring(spellId)))
      -- spellId is nil in 3.3.5; resolve from spellbook link
      if (not spellId or spellId == 0) and spellName then
        local resolved = resolveSpellIdFromBook(spellName, rank)
        if resolved then
          spellId = resolved
          chat(("resolved spellId from book: %s %s -> %d"):format(spellName, tostring(rank or ""), spellId))
        else
          chat(("could not resolve spellId for: %s %s"):format(tostring(spellName), tostring(rank or "")))
        end
      end
      if spellId and spellId ~= 0 then
        pcall(EH.NoteSpellId, spellId, "player_cast")
      end
    end
  end)
end
